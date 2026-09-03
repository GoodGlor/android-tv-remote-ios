# Phase 2 notes (carried from Phase 1 reviews)

## Phase 1 carry-overs — ALL ABSORBED IN PHASE 2 (2026-08-19)

Every item below was implemented during Phase 2; kept for history.
See the "Phase 2 follow-ups" section at the bottom for what is still open.

- Add `disconnect()` to the `TVController` seam and call it from `onUnpair`
  (today unpairing leaves `connectionState == .connected`; invisible with the
  mock, wrong with a real socket).
- Settings "Connected" badge is hardcoded — drive it from the controller's
  `connectionState` once Settings can observe it.
- Accessibility pass: explicit labels for icon-only buttons (input, mic, mode
  segments, keyboard tile), the pairing code's hidden TextField, and the
  keyboard sheet's TextField.
- Consolidate stray literal colors into `Theme` (KeyboardSheet 0x111218 /
  0x7C7C86, SettingsView tv icon 0xA9A9B2).
- Make the pairing code load-bearing: filter to ASCII digits
  (`isASCII && isNumber`), disable the code field while pairing, and surface
  pairing errors (mock always succeeds today).
- MockTVController.connect(to:) ignores its device parameter — fine for the
  mock, but the real controller will use it.
- Tap-dependent flows (pair tap, touchpad swipes, keyboard sheet, settings)
  were build- and code-verified but not machine-driven; keep them in the
  manual test list.

## Phase 2 follow-ups (recorded at Phase 2 wrap-up, 2026-08-19)

Deferred during Phase 2 execution and triaged by the whole-branch review as
"fix later" — none blocks the real-TV test:

- **Re-resolved IP is never persisted.** When the router reassigns the TV's
  address, `AndroidTVController` recovers via mDNS but the new host lives only
  in memory, so the next launch repeats the slow re-resolve. Needs a public
  accessor or event on the controller so the app layer can re-save it —
  deliberately kept out of `RemoteCore` to avoid a `DeviceStore` dependency.
- **Foreground reconnect bypasses the stale-IP path.** `RootView`'s `.active`
  handler calls `connect(to:)` with the stored device directly. After an IP
  change the reconnect fails silently and self-heals only on the first key
  press. Documented in the dinner checklist as expected behaviour.
- **`DeviceDiscovery` cleanup.** `stop()`'s `task.cancel()` is effectively a
  no-op (nothing checks `Task.isCancelled`; the generation guard is what
  actually protects correctness) and the comment overstates it.
  `activeResolveTasks` is cleared only in `stop()`, so it grows by one
  finished task per browse event within a session.
- **`eventsFromAReplacedSessionAreIgnored`** passes against the pre-fix
  implementation too — it pins current behaviour rather than reproducing the
  original defect.
- **Accessibility:** `TouchpadView`'s drag surface has no accessibility label
  — a real VoiceOver gap.
- **One stray literal colour** remains at `RemoteView.swift:174` (`0xB9B9C1`).
- **`Scripts/test.sh`** hardcodes `macosx14.0` and must stay in sync with
  `RemoteCore/Package.swift`'s `.macOS(.v14)`.
- **`submitPairingCode` throws `.cancelled`** for both "double tap" and
  "round already over"; callers cannot distinguish them.
- **Keyboard sheet cannot transmit deletions** — the protocol has no delete
  key in our `KeyCommand` vocabulary, so backspace is silently ignored.
- **Connect timeouts (8s control / 15s pairing) are judgement calls,** not
  measured. Confirm 8s is enough for a TV waking from standby.

### Known library issue (upstream, not ours)

`RemoteManager` accumulates unrecognised post-handshake bytes without clearing
them (its `default:` branch clears only on a parsed `VolumeLevel`). If a long
session degrades, look there first.

## Real-TV findings (2026-08-19 evening, Xiaomi MiTV-MOSR1, Android 11)

Verified working end to end: mDNS discovery, TLS pairing with the on-screen
code, D-pad/OK/Back/Home, volume/mute, transport, and the Netflix and YouTube
app tiles.

Fixed as a result of testing:
- Discovery resolved to a link-local IPv6 address with the scope stripped
  (unroutable). Now pinned to IPv4, with the interface scope stripped from
  IPv4 and kept on link-local IPv6.
- `Scripts/probe.sh` added: the documented `swift run $F rc-probe …` pattern
  fails in zsh, which does not word-split unquoted variables.
- Text key events must be paced (80ms). Sent back-to-back the TV closes the
  control connection outright.

Open / not reachable:
- **Text entry does not work at all.** Android TV ignores per-character key
  events for text input; it needs the protocol's IME message
  (`remote_ime_batch_edit`), which the transport library does not implement.
  Doing it properly means parsing the TV's text-field status messages (the
  library exposes a `receiveData` hook) and echoing its counters back. The
  keyboard tile is disabled meanwhile. Phase 3.
- **The menu (≡) button was removed.** Its intended action — opening the TV's
  Settings — is not reachable over this protocol. Every Android keycode from
  1 to 304 was sent (minus destructive ones: power, sleep, input switching,
  pairing) and the TV acted on none; `intent:` and `android-app://` deep
  links both made it drop the connection. The physical remote's Settings
  button evidently reaches a system app over a vendor-private Bluetooth path
  that key injection cannot reproduce. ADB would have identified the code but
  this firmware exposes neither network nor wireless debugging, and port 5555
  stays closed after a reboot. `KeyCommand.menu` is retained and maps to a
  long press of OK (a working context menu) if a future UI wants it.
- **The mic button still does nothing** — a Phase 1 placeholder. Voice needs
  the protocol's voice messages, which the library lacks; `ASSIST` (219) and
  `VOICE_ASSIST` (231) are both ignored by the TV. Deferred at the user's
  request.
- **MI TV tile is still unverified**; Netflix and YouTube are confirmed. Note
  that an unsupported URI drops the control session, so a wrong tile link is
  not a silent no-op.

Protocol behaviour worth knowing:
- The TV accepts **only one control session at a time**. A force-quit client
  leaves a half-open socket and new connections are refused until the TV
  times it out (a minute or two).

## IME spike findings (2026-08-20, Xiaomi MiTV-MOSR1, Android 11)

Run with `./Scripts/probe.sh dump <host>`, which listens without sending and
annotates every message by protobuf field number. `./Scripts/probe.sh decode
< dump.log` re-annotates a saved capture offline, so improving the decoder
never costs a reconnect (the TV allows only one control session).

**The TV does report focused-text-field state, unprompted.** No capability
negotiation or show-request was needed — the messages arrive as soon as a real
text field is focused. Three top-level fields carry it:

| Field | Meaning | Payload seen |
|---|---|---|
| 20 | Focus / foreground app changed | app info (package, label) + initial text-field status, or app info alone when the new app has no field |
| 21 | IME session active flag | `{1: 1}` while a field is focused, `{1: 0}` on leaving it |
| 22 | Live text-field status, one per edit | the status submessage below |

The status submessage (field 2 inside 20 and 22):

| Sub-field | Meaning |
|---|---|
| 1 | counter — increments once per edit |
| 2 | **absolute** current contents of the field |
| 3 / 4 | selection start / end |
| 5 | (always 1 so far) |
| 6 | hint text ("Пошук") |

Typing `й`, `йц`, `йцу` in the browser's search bar produced counters 16, 17,
18 with values `"й"`, `"йц"`, `"йцу"` and selection tracking 1/1, 2/2, 3/3.

Consequences for the design:

- **Mirror by absolute value, not by delta.** Field 2 is the whole string every
  time, so the app never has to reconstruct state from edit operations, and a
  dropped message self-heals on the next one.
- **The counter is available to echo back**, which was the open risk — a
  batch-edit has to quote it.
- **UTF-8 throughout.** Cyrillic round-trips fine. This matters: the current
  ASCII-keycode fallback in `sendText` skips Cyrillic entirely, so IME is the
  only route to typing Ukrainian/Russian at all.

**Not every app participates.** Confirmed by capture on this TV:

| App | Package | IME field? |
|---|---|---|
| Browser | `com.internet.tvbrowser` | ✅ streams every keystroke |
| Play Store | `com.android.vending` | ✅ |
| MEGOGO | `com.megogo.application` | ✅ |
| **Global search** | `com.google.android.katniss` | ✅ |
| YouTube | `com.google.android.youtube.tv` | ❌ app-info only |
| Netflix | `com.netflix.ninja` | ❌ app-info only |
| Launcher | `com.google.android.tvlauncher` | ❌ app-info only |

YouTube and Netflix draw their own on-screen keyboards and consume the remote
as plain D-pad + OK, so no traffic is generated at all while typing in them.

**Two verified workarounds for those two apps**, both tested against this TV
with the control session surviving intact:

1. **`KEYCODE_SEARCH` (84) opens `com.google.android.katniss`**, the global
   search — which exposes a real IME field (hint "Шукайте фільми, серіали,
   додатки тощо"). Its results span YouTube and other apps, so typing there
   reaches YouTube content over a mechanism that works.
2. **A search app-link — works for YouTube, NOT for Netflix.**

   | Link | Result |
   |---|---|
   | `https://www.youtube.com/results?search_query=<q>` | ✅ opens YouTube **on the results page**. Verified with a Latin and a percent-encoded **Cyrillic** query. |
   | `https://www.netflix.com/search?q=<q>` | ❌ not registered by the app — falls through to the browser. |
   | `nflx://www.netflix.com/search?q=<q>` | ⚠️ launches the Netflix app directly (no browser), but **the query is dropped** — lands on the home screen. |
   | `netflix://search?q=<q>` | ❌ no reaction. |

   All were sent with the control session surviving intact; none dropped it.

**Conclusion.** YouTube search is best served by the app-link (route 2) — it
needs no IME and carries Cyrillic, which the current keycode path cannot do at
all. **Netflix search has no working deep link.** Route 1 (katniss) was tried
as its replacement and later REMOVED — see "Submitting a TV text field — NOT
POSSIBLE" below: katniss opens voice-first and never reports the field the
injection needed. Netflix search from the phone is unsupported; do not
re-attempt either route.

Two further fields seen in the same capture:

- **Field 29 — live search suggestions** pushed by the TV as you type. One
  message carried `"йога уроки и тренировки"`. Could be surfaced on the phone.
- **Field 23** — small state message (`{2: 0, 3: 0}`), purpose unclear.

**Field 1 of the status message is Android's `EditorInfo`**: `inputType`,
`imeOptions`, `privateImeOptions` (e.g. `"escapeNorth,voiceDismiss"`,
`"…latin.noDecoding,…latin.noMicrophoneKey"`), hint text, package name and the
field's resource id. That is enough to pick the right phone keyboard per field
— numeric for a PIN, URL for the browser.

**Still unverified: the write direction.** Nothing was sent to the TV during
this spike. Whether a client-authored batch-edit on field 21 is accepted — and
its exact shape — is the next thing to establish. Note that an unsupported
message historically drops the control session, so test it in a throwaway
session, not in the app.

## IME write direction — VERIFIED (2026-08-20, second spike session)

Established with `./Scripts/probe.sh settext <host> <text>` against the
browser's search field, confirmed visually. **The phone can set a TV text
field's contents, Cyrillic included.**

### The handshake this firmware requires

1. **`ime_show_request` (field 22)** carrying `{2: {1: <status counter>, 2: "",
   3: 0, 4: 0, 5: 1}}` — echo the focused field's current status counter with
   an EMPTY value (echoing the field's text makes the TV ignore the request).
2. The TV replies with a **field-21 message resetting the counters** (observed
   `{1: 0, 2: 0}`). **Wait for it** — an edit sent with stale counters is
   silently ignored. No reply comes at all unless the TV's own on-screen
   keyboard is open on the field (`ime state {1: 1}`).
3. **`ime_batch_edit` (field 21)**: `{1: ime_counter, 2: field_counter,
   3: RemoteEditInfo{1: insert=1, 2: RemoteImeObject{1: start, 2: end,
   3: value}}}` with the counters from step 2.
4. The TV **echoes every accepted edit** as a fresh field-22 status — built-in
   write confirmation. Multiple edits may follow one handshake; the counters
   did not need refreshing between two consecutive edits.

**One handshake covers MANY writes — and you MUST NOT repeat it** (real-TV,
`./Scripts/probe.sh settext <host> "тест" --twice`). Step 2's reply only comes
when the IME actually *needs showing*: once it is up, a second
`ime_show_request` is answered by **silence**, indistinguishable from the
"keyboard closed" timeout. Handshaking per write therefore makes the mirror
accept exactly one write and then declare focus lost — the Task 7 field bug.
Reuse the first reply's counters until focus genuinely moves; if an edit's echo
stops arriving, *then* re-handshake.

### This firmware's edit semantics are DEGENERATE

The proto suggests "replace range [start,end) with value". The MiTV-MOSR1
instead applies the **net length change at the cursor**:

| Sent | Expected (proto) | Actual |
|---|---|---|
| `{0, 0, "привіт"}` on "hello" | "привітhello" | "helloпривіт" (append) |
| `{0, 11, "чудово"}` on "helloпривіт" | "чудово" | "helloп" (deleted 5 = net) |
| `{0, len, ""}` | "" | "" ✅ (delete-all works) |

So only two operations are reliable: **append** (`start=end=0`, value=text) and
**delete N from the tail** (`start=0, end=N`, empty value). "Set field to X" is
therefore two edits: clear, then append. Both verified, including UTF-8.

Failure modes (all verified): bare batch edit with no show request → ignored;
stale counters → ignored; keyboard not open on the TV → the show request gets
no reply. Nothing IME-related ever dropped the session.

### Read direction (same session)

Typing `ф`, `і`, `в` then deleting one produced statuses 99→102 with absolute
values "ф", "фі", "фів", "фі" — **deletions arrive as ordinary full statuses**,
so the mirror needs no special delete handling.

### Sources

Message layout: [remotemessage.proto (tronikos/androidtvremote2)](https://github.com/tronikos/androidtvremote2/blob/main/src/androidtvremote2/remotemessage.proto),
send shape: [kud/androidtv-remote](https://github.com/kud/androidtv-remote)
(whose `sendText` alone did NOT work here — the show-request handshake and the
degenerate range semantics are Xiaomi-specific findings of this spike).

## Submitting a TV text field — NOT POSSIBLE (2026-08-20, verified)

The on-screen keyboard's ✓ key (bottom-right) is what runs a search on this TV.
It is handled entirely inside the TV's own IME. Verified by capture while the
user pressed it with the physical remote: the only thing that reaches a remote
client is the field CLOSING —

    field 21 {1: 1, 2: 1}    IME active (typing)
    field 23 {2: 35, 3: 35}
    field 21 {1: 0, 2: 1}    IME inactive   ← the ✓ press
    field 20  app info only  the text field is gone

No message identifies the action, and none can be sent to trigger it. Also
tried and rejected: `KEYCODE_ENTER` (66), `KEYCODE_NUMPAD_ENTER` (160),
`KEYCODE_SEARCH` (84) — none submit; and driving the D-pad to the ✓ key, which
the on-screen keyboard does not respond to from remote key injection.

**Consequence for the app:** the text mirror is for EDITING a field, not for
submitting it. Searching must bypass the field entirely and go out as an
app-link:

| Destination | Link | Status |
|---|---|---|
| YouTube | `https://www.youtube.com/results?search_query=<q>` | ✅ verified, incl. Cyrillic |
| Web / browser | `https://www.google.com/search?q=<q>` | ✅ verified — opens the browser on results |
| Netflix | none exists | ❌ **unsupported from the phone — do not re-attempt** |

**Netflix search from the phone is not supported, and the file is closed on
it.** Three independent routes were tried against hardware and all three are
dead ends:

1. **No IME field.** `com.netflix.ninja` reports app info only — it draws its
   own on-screen keyboard and emits zero IME traffic, so there is nothing to
   write into (see the app/IME table above).
2. **No working search deep link.** All four candidate forms were tested:
   `https://www.netflix.com/search?q=` falls through to the browser,
   `nflx://www.netflix.com/search?q=` launches the app but drops the query,
   `netflix://search?q=` does nothing, and the plain title link carries no
   query at all.
3. **Global search (katniss) was removed** (2026-08-20). `KEYCODE_SEARCH` (84)
   does open `com.google.android.katniss`, but capture shows katniss opens
   **voice-first**: it reports app info only and never exposes the text field,
   so the injection never fired and the query was silently dropped after the
   focus deadline. The `.globalSearch` route, its pending-query machinery and
   the `search`/`enter` keycodes were deleted rather than chased further.

The two surviving routes — YouTube and Web, both rows above — are what the
keyboard sheet offers.

## Cursor control in the browser — HELD keys glide, taps nudge (2026-08-21)

The TV's browser draws its own cursor after a page loads, and it is driven by
D-pad keys. Verified on hardware:

- **Discrete short presses** move the cursor only a tiny amount each — a burst
  of 10-20 presses barely travels. Unusable as a pointing method.
- **A held key glides the cursor continuously** for as long as it is held
  (`KeyPress(key, .START_LONG)` … `KeyPress(key, .END_LONG)`). Confirmed with a
  4s hold of `KEYCODE_DPAD_LEFT`.

Android auto-repeats a held D-pad key, which is what produces the glide. So
pointer-style control must HOLD a direction for the duration of the user's
drag, not emit a stream of discrete steps.

**Safety invariant:** a held key must always be released — on finger-up,
gesture cancellation, view teardown, disconnect and session drop. A leaked
START_LONG leaves the TV scrolling by itself.

## A Settings button — NOT POSSIBLE over this protocol (2026-08-21, verified)

The hardware remote's settings button works, but it cannot be reproduced from
the phone. Do not re-attempt without new information.

**What the hardware button actually is.** Captured with `adb shell getevent`:

```
/dev/input/event2: EV_MSC  MSC_SCAN         000c018f
/dev/input/event2: EV_KEY  KEY_TASKMANAGER  DOWN
```

HID consumer usage `0x0C 018F` ("AL Task/Project Manager") on the *Consumer
Control* HID interface of the Xiaomi remote — not the keyboard interface. It
opens `com.android.tv.settings/.MainSettings`.

**There is no Android keycode for it.** `key 460` (KEY_TASKMANAGER) is absent
from every keylayout on the device — `/system`, `/vendor`, `/product`, `/odm`
and `/data/system/devices` all checked. The button is handled by something
below or beside the standard keycode path, so there is nothing for our
protocol to send.

**Eleven keycodes were tried over the protocol and ALL were ignored:** 176
SETTINGS, 187 APP_SWITCH, 82 MENU, 170 TV, 172 GUIDE, 177 TV_POWER, 219
ASSIST, 284 ALL_APPS, 120 SYSRQ, 255 TV_ZOOM_MODE, 229 LAST_CHANNEL. Each was
sent from a known launcher state with `dumpsys window` read before and after;
focus never changed. All eleven exist in the library's `Key` enum, so
`sendRawKeyCode`'s `Key(rawValue:)` guard did not silently drop them — this
was checked, because that guard returns without sending for an unknown code
and would otherwise fake a negative result.

Confirmed a third time by eye: 176 sent over the control session with ADB
uninvolved, user watching the TV — nothing happened.

**ADB and the remote protocol are NOT equivalent injection paths.** `adb shell
input keyevent 176` opens Settings reliably; the same keycode over the control
session does nothing. `KEYCODE_SETTINGS` is a *global key*, consumed by the
system's window policy rather than the focused app, and only the privileged
injection path receives that treatment. Verified with a control in both
directions: BACK (4) over the protocol closed Settings, and ADB 176 opened it,
seconds apart on the same TV.

**The deep-link route cannot reach Settings either.** `pm dump
com.android.tv.settings` lists actions only — no `Scheme:` entries, so no URI
resolves to it. An `intent:#Intent;action=android.settings.SETTINGS;end` URI
dropped the control session outright (`POSIXErrorCode 96`), which is the
documented behaviour of `sendDeepLink` for a URI no installed app handles.

**Method note.** An earlier sweep of these same keycodes reported ten clean
negatives while `adb` was silently disconnected: the focus oracle returned an
empty string every time, and empty always equals empty. Any sweep using an
external oracle must prove the oracle can observe a *change* before its
negatives mean anything — `Scripts/`-adjacent sweeps now send ADB 176 first
and abort unless Settings actually appears.

## Diagonal cursor movement — NOT POSSIBLE (2026-08-21, verified)

Two ordinary direction keys held AT ONCE do not sum into a diagonal. Tested
with `rc-probe diag <host> 20 21 4000` (DOWN + LEFT, staggered 150ms to respect
the pacing floor), tracked by `screencap` before and after:

| | before | after |
|---|---|---|
| cursor | (1228, 118) | (5, 120) |

LEFT glided the full width of the screen; DOWN contributed **2px** — a single
discrete step. The later key down captures the auto-repeat and the earlier hold
degrades to one nudge, because **Android auto-repeats only the most recent
key**. That is OS behaviour, not a protocol limit, so no message we could send
changes it.

Combined with the already-recorded rejection of the diagonal keycodes
(268-271), diagonal movement over this protocol is closed. **4-way glide is
the ceiling.** A true 2D cursor requires TV-side software.

Note: the control session dropped (`POSIXErrorCode 96`) during the two-key
sequence, after the movement had already occurred. Overlapping holds may
themselves be unsafe on this firmware; the app holds exactly one direction at
a time and should keep doing so.

**Measurement note:** `adb exec-out screencap -p` fails on this TV ("open mma
dev failed"). Use `adb shell screencap -p /sdcard/s.png && adb pull` instead.
The browser's cursor DOES appear in the capture, so cursor position is
machine-checkable — no need for a human to watch the screen.

## Typing into Netflix — NOT POSSIBLE over this protocol (2026-08-23, verified)

Netflix search cannot be driven from the phone. Phase 2 already recorded this
("no IME field, no working deep link"), but the reason recorded then was vague
enough to invite a re-attempt. This session re-opened it with ADB available and
closed it with byte-level evidence. **Do not re-attempt any of the five.**

The root cause is one sentence: **the TV's remote service cannot inject letter
keycodes at all.** Netflix accepts letters fine — the protocol cannot deliver
them.

### 1. Letter keycodes over Remote v2 — the transport has no letters

`getevent -pl` on both uinput devices the remote service owns — `virtual-remote`
AND `virtual-search` — lists ~76 keys: digits, D-pad, media transport, colour
buttons, `KEY_SEARCH`, F-keys. **No `KEY_A`..`KEY_Z`.** The kernel drops what the
device never declared.

Verified, not just reasoned:
- `probe.sh raw <host> 48 29 30 31` (T, A, B, C) into Netflix search → nothing.
- Same keycodes into the TV **browser's** focused field, with a screenshot as
  the oracle → field stayed empty. So it is transport-level, not a Netflix quirk.
- Positive control on the same session: `raw 20 20` scrolled the home screen two
  rows. The session was live; the letters were rejected.

The library's `Key` enum DOES contain `KEYCODE_A` = 29 etc. Their presence in
the enum means nothing — the wall is on the TV.

### 2. The IME text channel — Netflix has no field to write into

This is the channel that works for the browser and for Google's global search.
The TV announces a focused field as protobuf field 20; the payload size is the
tell:

| App | Announcement | Contents |
|---|---|---|
| `com.google.android.katniss` (global search) | **307 bytes** | inputType, `privateImeOptions`, hint text, `fieldId=2131427969` |
| `com.internet.tvbrowser` | full | same shape |
| `com.netflix.ninja` | **21 bytes** | field 12 = package name, nothing else |

Netflix announces "I am foregrounded" and never "I have a text field". There is
no InputConnection to write into. Its search box is a self-drawn letter grid on
`com.netflix.mediaclient.android.widget.TappableSurfaceView` — not an EditText.
`dumpsys input_method` agrees: `mServedView` is the SurfaceView, `mInputShown=false`.

### 3. Search deep link — Netflix declares no search route

`dumpsys package com.netflix.ninja` activity filters:

- Paths: `/title.*`, `/watch.*`, `/browse`, `/home`, `/deeplink.*` — **no `/search`**
- Actions: MAIN, VIEW, `com.netflix.action.DIAL_START`, `NETFLIX_KEY_START`,
  `com.google.cast.action.START` — **no `ACTION_SEARCH`**
- Schemes: `http`, `https`, `netflix`, `nflx`, `cast`

`https://www.netflix.com/search?q=…` opens the TV **browser** — Netflix does not
claim that path. The `netflix://` scheme filter has no path restriction, so
`netflix://search?q=matrix` IS delivered to MainActivity — and Netflix ignores
it: cold-start test landed on the normal home screen, no results, and logcat
recorded no deeplink parsing. `netflix://title/` is the only URI template
anywhere in the APK's dex.

### 4. Google TV global search — writable, but not a route into Netflix

Worth knowing, because it is a real capability (see below), but it does not
solve Netflix: the entity page for **Wednesday**, a Netflix original, shows **no
provider button at all**. (The Matrix showed only Play rent/buy.) Netflix is not
integrated into search on this device.

### 5. ADB — the only channel that types into Netflix

`adb shell input keyevent 48 33 47 48` typed "test" into Netflix search, and
`input text` works the same way. This is not a contradiction of the above: ADB
injects via InputManager and never touches uinput.

**The only remaining path to Netflix typing** is teaching the app to speak the
ADB wire protocol to port 5555 (RSA auth handshake + framing, in Swift). It
installs nothing on the TV, so it satisfies the standing constraint, but it
depends on USB debugging staying enabled forever and is a whole new transport.
Not attempted — an explicit product decision, not an oversight.

### Side finding — global search IS writable from the phone (verified)

Not a Netflix solution; recorded because it is a genuine, cheap capability:

- `KEY_SEARCH` (84) IS in the uinput key list, so the phone can open global search
- The field then announces properly, and `probe.sh settext` wrote "matrix" into
  it — the TV echoed the text back verbatim, screenshot-confirmed
- Submitting works by driving the D-pad to the on-screen keyboard's magnifier
  key and pressing OK (plain ENTER and `KEYCODE_SEARCH` both do nothing — the
  same submit wall as "Submitting a TV text field", with a way around it here)

**Order matters:** connect FIRST, then focus the field. A field focused before
the control session connects is never announced, and the write path waits
forever. This cost a 2-minute timeout before it was understood.

### Tooling note

Netflix sets `FLAG_SECURE`: `screencap` returns a 0-byte file and exit 1 while
it is foregrounded, and `uiautomator dump` returns no text nodes (SurfaceView).
Every Netflix-screen claim here was confirmed by a human looking at the TV.
Screenshots work everywhere else.

## A sleep timer — BUILT, TESTED, NOT SHIPPED (2026-08-23, verified)

Not an impossibility. A sleep timer works — but ONLY while the app is in the
foreground with the screen on. Lock the phone and the TV will not turn off,
and that was judged not worth having.

`main` does not carry it. The work is on the `sleep-timer-abandoned` branch
(pushed), and the numbers below are why nobody should merge it back without
first solving the locked-phone case.

### Why the countdown cannot live on the TV

The protocol's whole vocabulary is: send a keycode, open an app URI, write
into a focused text field. There is no "set a timer" message, and no way to
synthesise one.

The TV DOES have its own sleep timer, and Android exposes its state:

```
sleep_timer_remain_time=0          tv_timer_sleep_timer_entry_values=5
is_sleep_time_first_set_state=1
```

**`sleep_timer_remain_time` is a readout, not a switch.** Written to `2` over
ADB, the TV's own service wiped it back to `0` within 30s and armed nothing.
Arming it properly would mean calling the vendor `mitv.internal.ITvService`.
And the TV's Settings UI, where the real control lives, is already documented
above as unreachable over this protocol.

So the countdown can only live on the phone.

### Why the phone cannot run it locked

iOS suspends a backgrounded app within ~30s. It does not run slowly — it
stops. It can neither count nor send. A TV remote is not one of the exempt
background categories (audio, navigation, VoIP, downloads).

Measured on real hardware (2026-08-23), TV power state sampled over ADB every
5s — the app's own claim was never taken on trust:

| Test | Result |
|---|---|
| 1-minute timer, **app open, screen on** | TV powered off at 16:54:22 ✅ |
| 1-minute timer, **phone locked** | no power-off in 6 minutes of sampling |

The second result is by design, not a bug: the app cancels its own timer on
`scenePhase == .background`, because `ContinuousClock` keeps running while
suspended and a timer left armed would otherwise fire the instant the user
reopened the app — powering the TV off at the worst possible moment.

### If the locked-phone case is ever wanted

Two routes, both untested:

- **App Intents + a Shortcuts time automation** ("at 23:30, turn off TV").
  Clean and Apple-sanctioned, but fires at a fixed TIME, not "in N minutes",
  and whether it runs while locked needs testing rather than assuming.
- **The `audio` background mode** playing silence. This genuinely works while
  locked. It breaks no rule binding a side-loaded personal build, but it is
  API misuse and Apple can tighten it at any release.

Until one of those is built, this feature is not worth shipping: a sleep
timer that needs the phone awake and unlocked is not a sleep timer.
