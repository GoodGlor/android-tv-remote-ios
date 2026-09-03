# Phase 3 — Text entry, search, and pointer mode (design spec)

**Date:** 2026-08-20
**Status:** Approved design, binding for the Phase 3 plan.
**Predecessor:** `2026-08-19-tv-remote-phase2-design.md` (real connectivity).
**Evidence base:** every protocol claim below was verified against the real
MiTV-MOSR1 in the 2026-08-20 spike — see "IME spike findings" and "IME write
direction — VERIFIED" in `docs/phase2-notes.md` (commit `d600618`).

## Goal

Three user-visible capabilities on top of the working Phase 2 remote:

1. **Text entry that actually works** — a live two-way mirror of the TV's
   focused text field: type and delete on the phone, see it on the TV, and
   vice versa. Cyrillic included (impossible today: the keycode path silently
   drops non-ASCII).
2. **Search from the phone** — compose a query on the phone and land on
   results: YouTube via its search deep link, everything else (Netflix
   included) via Android TV global search.
3. **Pointer mode** — a third input mode with a trackpad feel: continuous
   drag emits paced D-pad steps, faster drag moves faster.

**Non-goals:** voice/mic (deferred by the user), device builds / code signing
(separate task), Netflix *in-app* typing (proven impossible: while typing in
Netflix the TV emits zero IME traffic — its keyboard is private to the app),
showing the TV's live search suggestions (field 29 — a possible later nicety),
a free on-screen cursor (needs TV-side software; the user chose iPhone-only).

## Locked decisions

- **No new dependencies, no library fork.** The ~4 IME wire messages are
  hand-rolled in `RemoteCore` exactly as the library's own `DeepLink` does,
  via the public `RequestDataProtocol` + `receiveData` seams. The pinned
  revision `32393c3` stays untouched.
- **Mirror by absolute value.** The TV streams the field's complete state on
  every edit (verified: typing *and* deleting each arrive as a full status
  with a climbing counter). The phone never reconstructs edits; a lost
  message self-heals on the next one.
- **Writes use the verified Xiaomi handshake** (this is spike fact, not the
  public proto's promise):
  1. send `ime_show_request` echoing the field's status counter with an
     **empty** value (echoing the text makes the TV ignore the request);
  2. **wait** for the TV's field-21 counter reset — an edit with stale
     counters is silently ignored; no reply ever comes unless the TV's
     on-screen keyboard is open;
  3. send `ime_batch_edit` with those counters.
- **"Set text" is clear + append.** This firmware ignores the proto's range
  semantics and applies the net length change at the cursor: net-positive
  appends the value, net-negative deletes from the tail. Only two reliable
  ops exist — append (`start=end=0`) and tail-delete (`end=N`, empty value) —
  so replacing the field is two edits. Verified, incl. UTF-8.
- **The keyboard tile is live, not hardcoded**: enabled exactly while the TV
  reports an IME-active focused field. In YouTube/Netflix it greys out —
  honest, because there the protocol truly cannot type.
- **Search routing:** YouTube queries go out as
  `https://www.youtube.com/results?search_query=<url-encoded>` app-links
  (verified, Cyrillic verified). Everything else opens global search
  (`KEYCODE_SEARCH` → `com.google.android.katniss`, verified to expose an IME
  field) and injects the query through the mirror. Netflix has **no working
  search deep link** (all four candidate forms tested; `nflx://` launches the
  app but drops the query).
- **Three input modes** — D-pad / Touchpad / Pointer. Today's one-swipe-one-
  step Touchpad stays as-is (user's choice); Pointer is added, not swapped.
  `Preferences.lastModeIsTouchpad: Bool` migrates to a three-case enum.
- **Key pacing floor stays 80ms** for anything emitted in a stream (Phase 2
  fact: an unpaced burst makes the TV drop the control session).

## Architecture

```
App/
  RemoteView          mode toggle grows a third segment (Pointer)
  PointerView         NEW — drag surface driving PointerEngine
  KeyboardSheet       REWRITTEN — live mirror of the TV field + search flow
RemoteCore/
  Wire.swift          NEW — varint + protobuf wire field encode/parse
                      (productionized from the spike's ProtoDump)
  ImeMessages.swift   NEW — TextFieldStatus (decode), ImeShowRequest &
                      ImeBatchEdit (encode, RequestDataProtocol)
  ImeChannel.swift    NEW — the handshake state machine: owns counters,
                      show-request/reply ordering, clear+append sequencing,
                      echo confirmation. Pure logic; sends via a closure.
  PointerEngine.swift NEW — drag samples in, paced KeyCommands out.
                      Pure logic with an injectable clock.
  Sessions.swift      ControlSessioning gains an IME event stream
  LibSessions.swift   deframes receiveData, parses fields 20/21/22,
                      feeds ImeChannel; sendRawMessage already exists
  AndroidTVController publishes focusedTextField; setText() drives ImeChannel
  MockTVController    mirrors a fake field for previews/tests
  Preferences         Bool → ControlMode enum with one-time migration
```

`ImeChannel` and `PointerEngine` are deliberately session-free pure logic —
both are fully testable against the byte fixtures and timings captured in the
spike, no TV required.

## Revised `TVController` protocol

```swift
// New surface (additions only; nothing existing changes):
var focusedTextField: TextFieldStatus? { get }   // nil = no field / no IME
func setText(_ text: String)                     // replace via clear+append
func search(_ query: String, target: SearchTarget)  // .youtube | .globalSearch
```

`TextFieldStatus` carries `counter`, `value`, `selection`, `hint`, and the
owning `packageName` (so the UI can label where you're typing). `sendText`
(the keycode path) is **retired from the UI**: Phase 2 proved per-character
key events enter no text on this TV. The seam keeps the method only for
rc-probe; the keyboard sheet uses `setText` exclusively.

## The keyboard sheet, rewritten

- Opens enabled only when `focusedTextField != nil`; shows the hint and the
  owning app.
- Phone field is *initialized from* the TV value and pushed on change,
  debounced ≥120ms and serialized through `ImeChannel` (one in-flight
  handshake; edits coalesce — always push the latest full string).
- TV-side changes (someone typing with the physical remote) update the phone
  field when the phone isn't mid-edit; the TV echo confirms every push.
- Focus loss on the TV closes the loop visibly: the sheet disables with
  "field closed on TV" rather than pretending.
- A Search affordance in the same sheet: type once, then either **YouTube**
  (deep link) or **Search TV** (global search injection).

## Error handling

- A show-request that gets no field-21 reply within ~1.5s → one retry, then
  surface "focus a text field on the TV" (this is exactly the keyboard-closed
  case, verified). Never drop the connection over IME — nothing IME-related
  ever dropped the session in testing.
- Echo timeout after an edit → re-read the next status as truth (absolute
  values make this safe) and retry the diff once.
- Global-search flow: after `KEYCODE_SEARCH`, wait for katniss's field to
  report focus before injecting; if it never does, leave the user in the
  opened search rather than failing silently.

## Testing strategy

- **Wire fixtures from reality:** the spike's captured bytes — preserved in
  **`docs/ime-captures.md`** (statuses, ime-state flips, the accepted
  show-request and clear/append edits) — become unit-test fixtures for
  `Wire`/`ImeMessages` decode+encode round-trips.
- **ImeChannel state machine:** handshake ordering, stale-counter guard,
  keyboard-closed path, clear+append sequencing, echo confirmation, edit
  coalescing — all with a scripted fake session.
- **PointerEngine:** deterministic clock; assert step rate scales with drag
  and never breaches the 80ms floor.
- **Mock honesty rule** (Phase 2 lesson): the mock's mirrored field must not
  invent behavior the real path lacks — e.g. it must require the same
  show-request step before accepting writes.
- **Real-TV checklist** (manual, end of implementation): browser mirror
  type/delete both directions, Cyrillic, YouTube deep-link search, global
  search injection + whether its results include Netflix on this TV,
  keyboard tile enable/disable in browser vs Netflix.

## Risks — ranked

1. **Katniss result coverage is unverified.** Injection into global search is
   proven; that its results surface Netflix titles *on this TV* is not (the
   planned demo was skipped). If they don't, Netflix search degrades to
   "global search opens, results are what they are" — the mechanism still
   works. Verify early in implementation.
2. **Getting into and out of the katniss field.** Opening global search via
   `KEYCODE_SEARCH` did **not** make the field report focus in the capture —
   statuses only flowed once the user navigated into it (likely a voice-first
   UI). The flow may need a D-pad nudge after opening, and submitting may
   need `KEYCODE_ENTER`/DPAD after injection. Both are cheap to probe; do it
   first in implementation, before building UI on the flow.
3. **Other-app field quirks.** The degenerate net-length semantics were
   characterized in the browser field. Play Store / MEGOGO / Settings fields
   should behave identically (same system IME service) but were only read,
   never written. The clear+append design is the most conservative op pair.
4. **Pointer feel is subjective** — pure-logic engine + a tuning constant in
   one place; iterate on the real TV at the end.

## Task shape (for the plan)

1. `Wire.swift` + `ImeMessages.swift` with fixture tests (no TV).
2. `ImeChannel` state machine + tests (no TV).
3. Session plumbing: deframe/parse in `LibSessions`, IME events through
   `Sessions`, controller surface + mock. Tests.
4. KeyboardSheet rewrite on the new surface; live tile enablement.
5. Search flow (deep link + global search injection).
6. Preferences migration + Pointer mode (engine, view, third segment).
7. Real-TV verification pass against the checklist; fix wave.
