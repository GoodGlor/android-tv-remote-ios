# Phase 2 dinner checklist — real TV verification

Prereqs: Mac + iPhone/simulator host and the Xiaomi TV P1e 32 on the same
Wi-Fi; TV fully on (not standby) for first pairing. Pairing now gives up
after 15 seconds — "Look at your TV…" no longer hangs for a minute. A
15-second failure means the TV never answered (deep standby, or wrong IP),
not a problem with the code.

Record every deviation from this checklist in `docs/phase2-notes.md` as you
go — don't wait until the end.

## A. Probe first (Mac, fastest loop)

Use the wrapper — it carries the macOS deployment-target flag the dependency
forces. (Do NOT put those flags in a shell variable: zsh does not word-split
unquoted variables, so `swift run $F rc-probe …` fails with "Unknown option".)

```bash
./Scripts/probe.sh discover
./Scripts/probe.sh pair <ip>
./Scripts/probe.sh key <ip> down
```

1. `./Scripts/probe.sh discover` — expect the TV listed with an IP. macOS
   may show a local-network permission prompt: accept.
2. `./Scripts/probe.sh pair <ip>` — expect the TV to display a 6-char
   code; type it; expect PAIRED.
3. `./Scripts/probe.sh key <ip> down` — expect focus to move on the TV.

   If A fails, debug HERE (add a `DefaultLogger()` to the session managers in
   LibSessions.swift for full protocol traces) before touching the app.

## B. App on the simulator (same Wi-Fi as the TV)

4. Fresh install → local-network prompt appears → accept → TV appears in list.
5. Tap TV → "Look at your TV…" → code shows ON the TV → enter → Remote screen.
    - **Acceptance criterion (critical bug fixed in this wave — check this
      exact moment):** once the code is accepted, the header must show
      "Connected" within a couple of seconds AND a D-pad press must work
      IMMEDIATELY, with no app relaunch. This is the only place that bug is
      observable — step 6's relaunch masks it, because relaunching
      reconnects fresh regardless of whether the post-pairing handoff works.
      If the remote is dead until you relaunch the app, that is the
      regression to report.
    - **Cancel sub-step:** while "Look at your TV…" is showing, tap Cancel →
      you return to the device list with no stuck spinner; re-tap the same
      TV → a fresh pairing round starts and the TV displays a new code. This
      control has never been rendered on a real screen (the simulator has no
      Bonjour TV), so also eyeball its layout — the card's padding changed
      and the button takes ~50pt of width from a line of text that already
      wrapped.
6. Relaunch app → connects silently (header dot green, "Connected").
7. D-pad up/down/left/right/OK move focus. Back, Home work.
8. Volume up/down/mute work. Power toggles standby; power again wakes it.
9. Background the app (Home), reopen → reconnects.
10. Settings shows live "Connected"; Unpair → returns to Connect; re-pair works.
11. **Pairing code field accepts letters.** The code is 6-character
    hexadecimal and may include A–F. A previous version of the app silently
    stripped letters, which would have made pairing with such a code
    impossible. If the TV displays a code containing a letter, confirm it can
    be typed and appears correctly in the boxes.
12. **Wrong-code recovery (expected protocol behaviour, not a bug).** When
    the TV rejects a code, it closes the pairing socket — that pairing round
    is over, there is no "retry the same round." Confirm the actual flow:
    - Start pairing, enter a deliberately wrong code.
    - Expect: the app returns you to the device list with the message
      "That code didn't match. Select your TV again for a new code."
    - Re-tap the TV to start a fresh pairing round — the TV displays a new
      code.
    - Enter the new (correct) code → pairing succeeds.

## C. App tiles (fix URIs as found)

13. Tap NETFLIX / YOUTUBE / PRIME / MI TV tiles. For each that fails to open
    the right app, adjust `KeyCodeMap.appLink(for:)` and retest.
    - Note: the **MI TV deep link is a guess** and quite likely wrong. If no
      working link is found for it, remove that tile's action mapping
      entirely rather than leaving it pointing at a broken/guessed URI, and
      record the finding in `docs/phase2-notes.md` for Phase 3.

## D. Keyboard decision (spec risk #2)

14. Open a search box on the TV, open the app's keyboard sheet, send "test 123".
    - **Constrain the test:** type plain lowercase only. Do NOT press
      backspace and do NOT accept an autocorrect suggestion while typing.
    - Works via ASCII keys → keep, document ASCII-only (no Cyrillic).
    - Flaky/broken → decide: implement the protocol's text message via the
      library's public `send(RequestDataProtocol)` extension point, or ship
      the sheet disabled and move text entry to Phase 3.
    - **Known app-layer limitation, do not count against the keyboard
      decision:** a backspace, or accepting an autocorrect suggestion,
      desyncs the TV from the field — every character typed after it lands
      on the stale text on the TV. This is a known limitation of the
      app-layer send logic, NOT a transport failure, and must not be used as
      evidence against the ASCII-key transport when making the decision
      above.

## E. Robustness

15. Turn the TV off at the mains for 1 min, back on, wait for boot → app
    reconnects. A connect attempt now fails in about 8 seconds instead of
    60, so recovery is: one keypress triggers the reconnect attempt, then —
    only if that first attempt failed — a SECOND keypress a few seconds
    later completes it (only a single reconnect is armed per drop).
16. If reachable: change the TV's IP (router DHCP reservation) → app recovers
    via mDNS re-resolution. Same timing as above: one keypress triggers the
    reconnect attempt, then a second keypress a few seconds later if the
    first attempt failed.

### Known behaviours (do not misdiagnose these as bugs)

- **IP reassignment while backgrounded:** if the router reassigns the TV's IP
  while the app is backgrounded, resuming the app may show "Not connected"
  until the first key press. The app then re-resolves the address (up to
  ~5 seconds) and reconnects. This is expected — give it a keypress and a
  few seconds before concluding something is broken.
- **Connection failures never un-pair the app.** If the TV is off or
  unreachable, the app stays paired and shows "Not connected"; it does not
  send you back to the Connect screen. Un-pairing only happens manually, via
  Settings.

## Wrap-up

- Record every deviation observed above in `docs/phase2-notes.md`, including
  anything in section C or D that changed the plan.
- Package tests are run with `./Scripts/test.sh` from the repo root — never
  bare `swift test` — since the flags in section A are required for macOS
  builds of this package.
