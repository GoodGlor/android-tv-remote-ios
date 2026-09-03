# HANDOFF — RemoteControl (iOS TV remote)

**Last updated:** 2026-08-25 17:26 EEST
**Updated by:** Claude (Opus 5 session)

## TL;DR

The remote is **feature-complete for what has been asked of it**, and every
claim here has been checked on real hardware — most of it with an objective
oracle (ADB) rather than the app's own word. It pairs, navigates (four arrows
*or* an Apple TV-style trackpad), mirrors and writes the TV's focused text
field, searches YouTube and the web, and drives a real 2D cursor in the TV's
browser. **220 tests pass. Nothing is unpushed. The backlog is empty.**

Two things happened late in this session worth knowing before touching
anything:

1. **A real UI bug shipped and was found by the user** — volume down was
   nearly unhittable. Root cause was a missing `.contentShape`, not the
   protocol. See "The volume-down bug" — the lesson generalises.
2. **A sleep timer was built, tested on hardware, and deliberately NOT
   shipped.** It works only with the app open and the screen on. The work is
   on `sleep-timer-abandoned`. Do not merge it back without first solving the
   locked-phone case — the numbers are in `phase2-notes.md`.

**Brightness was investigated to a conclusion**: impossible over this
protocol, genuinely possible over ADB (proven at the panel-driver level). No
code was written. See "Brightness".

## Repo & branch state

| | |
|---|---|
| Branch | `main` — clean, **fully pushed**, no stashes |
| HEAD | `744e1db` (this doc's own commit sits on top of it) |
| Last code commit | `b545672` — fix: volume down hit target |
| Tests | 220 passing (`./Scripts/test.sh`) |
| Live branches | `sleep-timer-abandoned` (`9e7e915`, pushed — see below), plus the merged `phase3-*`/`phase4-*` history |

`RemoteControl.xcodeproj` and `App/Info.plist` are generated (xcodegen) and
git-ignored — run `xcodegen generate` in a fresh clone before building.

**Two phones now run the app**, both on the free Personal Team, so each has
its own 7-day clock. After expiry the icon stays but the app refuses to launch
until it is installed again. **AltStore now renews that clock automatically** —
setup, limits and the ways it silently fails are in `docs/altstore.md`. The
cable path under "How to run" still works and is still the fastest way to test
a build.

Find a connected phone's UDID with `xcrun devicectl list devices`; the
`install` commands below take it as `--device <id>`.

A new device needs three things before `install` will work, in this order:
`devicectl manage pair --device <id>`, **Developer Mode** enabled on the phone
(Settings → Privacy & Security — the entry only appears after a Mac has tried
to connect), and then **Trust** the developer certificate under Settings →
General → VPN & Device Management. First launch also needs Local Network
permission allowed, or nothing works at all.

## Protocol references

- `docs/phase2-notes.md` — Android TV Remote v2: the authority on what that
  protocol can and cannot do. **Six documented dead ends**, each with the
  evidence that closed it. Read before attempting anything protocol-shaped.
- `docs/tvbrowser-remote-protocol.md` — the TV browser's own cursor protocol
- `docs/ime-captures.md` — raw IME wire fixtures
- Specs and plans under `docs/superpowers/`

## Settled numbers

Every one of these was a guess at some point. None is now.

| Constant | Value | How it was settled |
|---|---|---|
| `SendPacer` floor | 8ms | **Measured**: 0ms drops the session every time, 1ms survives every time, 8ms survives a 60-change soak. Separation, not rate. |
| `TrackpadEngine.sensitivity` | 3.0 | **Measured, then tuned with the user**: the TV applies deltas exactly 1:1; pad is 354x244pt. 2.0 too slow, 3.6 too fast. |
| `SwipePadEngine.stepDistance` | 24pt | **Tuned with the user**: 44 felt like a long drag. Its floor is `tapDistance` (12), not comfort. |

Both engines' tests derive distances from these constants rather than
repeating literals, so retuning is a one-line change. Both were checked
non-vacuous by mutation.

## Done recently (2026-08-23, later session)

### The volume-down bug — FIXED (`b545672`)

User report: *"volume down works once in ten presses, volume up is fine."*
It looked exactly like a protocol fault. It was not.

`RockerControl` was **the only tappable surface in the app without an explicit
`.contentShape`**. A SwiftUI `Button` whose label is a bare `Image` hit-tests
against the RENDERED GLYPH, not its frame:

| Icon | Ink | Result |
|---|---|---|
| `plus` | full cross | easy to hit |
| **`minus`** | **one hairline bar** | **nearly unhittable** |
| `chevron.up`/`down` | solid shapes | both fine |

That is why exactly ONE of four rocker buttons was dead, and why it read as
volume-specific.

**What settled it, in order** — worth copying as a debugging pattern:

1. TV side, via ADB: repeated `input keyevent 25` moved volume 6→5→4→3→2. TV innocent.
2. Wire side, via `probe.sh raw <host> 25 25 25 25`: TV went 6→2. Protocol innocent.
3. Keycodes checked in the library: 24 up / 25 down. Mapping innocent.
4. User observed **no press animation and no haptic** — so the tap never
   reached the button, and `press()` never ran. That located it in the UI.

User-confirmed fixed on hardware.

### A sleep timer — BUILT, TESTED, NOT SHIPPED (branch `sleep-timer-abandoned`)

Merged to `main` briefly by mistake and reverted in `3cc8f6b`. **`main` does
not carry it.** The branch (`9e7e915`) is pushed and holds the engine, 17
tests, all guards mutation-checked, and an `rc-probe sleeptimer` command that
drives the real engine against a real TV with a scaled clock.

Measured on hardware, TV power state sampled over ADB every 5s:

| Test | Result |
|---|---|
| 1-minute timer, **app open, screen on** | TV powered off at 16:54:22 ✅ |
| 1-minute timer, **phone locked** | no power-off in 6 minutes of sampling |

The second result is by design: iOS suspends a backgrounded app within ~30s,
so the app cancels its own timer on `scenePhase == .background`. A timer left
armed would otherwise fire the instant the user reopened the app.

**The countdown cannot be moved to the TV.** The protocol has no "set a timer"
message, the TV's Settings UI is unreachable (already documented), and the
TV's own `sleep_timer_remain_time` is a READOUT — written to `2` over ADB, the
TV's service wiped it back to `0` within 30s and armed nothing.

Two untried routes if it is ever revisited (both in `phase2-notes.md`): App
Intents + a Shortcuts time automation (clean, fixed time, locked-run
unverified), or the `audio` background mode playing silence (works, but API
misuse).

### Brightness — investigated to a conclusion, no code

**Over this protocol: impossible.** `virtual-search`, the uinput device the
TV's remote service injects through, declares 76 keys and **no
`KEY_BRIGHTNESSUP`/`KEY_BRIGHTNESSDOWN`**. The kernel drops what the device
never declared — the same wall as letter keycodes.

The TV's IR receiver and its "Xiaomi RC Consumer Control" device DO declare
them, so the panel supports it; only our injection path cannot reach it.

**Over ADB: genuinely possible, proven at the driver level.** Two separate knobs:

- `settings put global picture_backlight N` — the vendor panel control. The
  MStar driver logged `[MTGVDO_SetArg] Set backlight value N by upper` for
  100, 10 and 52. That is the physical backlight, not a settings mirror.
  There are 25 `picture_*` keys (contrast, gamma, saturation, local dimming…).
- `settings put system screen_brightness N` (0–255) or `input keyevent 220/221` —
  Android's own brightness; moved 102 → 176 → 28 and propagated to
  `mBrightnessState`.

Both are ADB-only, so shipping this means the ADB-over-TCP transport that was
declined once already. Original values were restored (`picture_backlight=52`,
`screen_brightness=102`).

### A web app — answered, not possible

Asked and closed in discussion. Four independent blockers, any one fatal:
browsers cannot open raw TCP sockets (the TV speaks protobuf-over-TLS on
6466), cannot present a client certificate outside HTTPS, cannot pair on 6467,
and cannot do mDNS. The TV browser's cursor service on 8335 IS a real
WebSocket and could be driven from a page — but that is a trackpad, not a
remote. A web UI plus a LAN-side helper daemon would work and needs an
always-on machine. **If the motivation is the 7-day expiry, the answer is a
paid Apple Developer account ($99/yr → 1-year profiles), not a rewrite.**

## Next up

**Nothing is queued.** The backlog is empty; the next task comes from a new
request.

If the trackpad's two axes ever feel mismatched, splitting `sensitivity` into
separate x and y constants is a small change — the asymmetry is the pad's
shape (354 wide, 244 tall, one constant serving both), not the TV's.

## Open known issues

- **Netflix search from the phone is unsupported** — proven, not assumed. Do
  not re-attempt; see `phase2-notes.md`.
- **Submitting a TV text field is impossible** in general — the ✓ is handled
  inside the TV's own IME. Search works by *sending a query*. (Global search is
  the one exception, via the keyboard's magnifier key.)
- **The cursor depends on a third-party app.** It works only inside that
  browser, only while a page is open, and the protocol is private — a browser
  update can change it without warning. If the cursor dies suddenly that is the
  first suspect; `docs/tvbrowser-remote-protocol.md` has the wire format.
- **A re-install may lose the stored pairing.** Observed once (2026-08-23).
  Cause unknown — the likeliest is a `UserDefaults` write that had not flushed,
  but that is a THEORY, not a finding. If it recurs, making `DeviceStore.save`
  durable is the cheap fix. **Do not repeat the claim that a re-install always
  preserves the pairing — it was made confidently here and turned out wrong.**

## Working rules & gotchas

- **Every `Button` whose label is a bare `Image` needs an explicit
  `.contentShape`.** Otherwise it hit-tests the drawn glyph, and thin symbols
  (`minus`, hairline chevrons) become nearly untappable. This shipped once and
  cost a full debugging round. Every tappable surface in the app now sets one.
- **"No press animation and no haptic" localises a bug instantly**: it means
  the tap never reached the button, so nothing below the UI can be at fault.
  Ask for it before investigating transport.
- **A phone app holding the control session looks EXACTLY like a wedged remote
  service** — `rc-probe` stalls at `connectionPrepairing` with no error, ever.
  Three service force-stops were spent chasing the wrong cause. **Check first:**
  ```bash
  adb shell cat /proc/net/tcp6   # local port 1942 (=6466) with a non-zero peer = someone is connected
  ```
  Only if nobody holds it is the service actually wedged
  (`adb shell am force-stop com.google.android.tv.remote.service`, wait ~30s).
- **Do not kill `rc-probe` mid-run to "check on it"** — a piped `| tail` hides
  its output until it exits, which reads as a hang. Redirect to a file and poll
  the file instead.
- **Use ADB as the oracle, never the app's own word.** Volume
  (`dumpsys audio`, STREAM_MUSIC), power (`dumpsys power | grep mWakefulness`),
  brightness (`dumpsys display | grep mBrightnessState`). Every hardware claim
  in this doc was settled that way.
- **ADB is available** — Settings → About → click Build ×7 → enable
  "Налагодження USB", then `adb connect 192.168.0.108:5555`.
- **Netflix sets `FLAG_SECURE`**: `screencap` returns 0 bytes while it is
  foregrounded and `uiautomator dump` returns nothing. A human looking at the
  TV is the only oracle there. Screenshots work everywhere else.
- **`adb shell screencap -p /sdcard/s.png && adb pull`** — `exec-out screencap`
  fails on this TV.
- **`screencap` cannot see backlight.** It captures the framebuffer, so it is
  useless as a brightness oracle — use `dumpsys` or the kernel log.
- **Measure the cursor in the page BODY, never the toolbar** — its buttons
  highlight on hover and swamp a frame diff. And do not exclude the toolbar
  rows by `y`: that hides a corner-pinned cursor entirely.
- **`DEVELOPER_DIR` prefix is mandatory** for every `swift`/`xcodebuild`/`xcrun`
  — including `simctl`, which fails with "not a developer tool" without it.
- **Never run bare `swift test`** — use `./Scripts/test.sh`.
- **The TV allows ONE control session.** The app and `rc-probe` cannot both be
  connected.
- **Key events must be separated, not rate-limited** — 8ms, enforced centrally
  by `SendPacer`. Nothing outside it should add its own sleep.
- **A held key must always be released** — a leak leaves the TV scrolling with
  nothing on screen able to stop it. Ordering in the pacer's queue guarantees
  this; never reorder it.
- **iOS silently refuses to browse a Bonjour type absent from
  `NSBonjourServices`.** Both types are listed in `project.yml`.
- **Match TVs by Bonjour instance name, never by IP.** A stored host is a DHCP
  lease and goes stale — this silently disabled the whole cursor feature once.
- **SourceKit lies in this repo** — "No such module 'Testing'" / "Cannot find
  type X" are indexer false positives. Trust `./Scripts/test.sh`.
- **Mutation-test the guards, and test-derived constants too.** Several guards
  here passed review while being deletable with the suite green.
- **A green suite is necessary and never sufficient on UI or protocol work.**
  Every phase has produced defects invisible to the suite and obvious within
  seconds on the device — the volume bug is the latest.
- **The simulator cannot test permission flows.** Local network access is
  granted once and remembered. Test permission-gated behaviour by DELETING the
  app from a real device and installing fresh.
- **`NWBrowser.waiting` is not transient.** It is where a browse parks without
  local network permission, and it does not recover on its own. Restart it.
- **Stamp this file from `date`, not from memory.** Wrong timestamps have been
  written and corrected more than once.

## How to run

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./Scripts/test.sh                      # 220 tests

# Real TV — app must be closed first (one control session)
./Scripts/probe.sh discover
./Scripts/probe.sh dump 192.168.0.108
./Scripts/probe.sh raw <host> <keycode…>
./Scripts/probe.sh settext <host> <text>       # IME write (connect, THEN focus)
./Scripts/probe.sh pace <host> <gapMs> [pairs] # pacing tolerance / regression

# Cursor calibration — TV browser open on a plain page (needs numpy + Pillow)
python3 Scripts/cursor-calibrate.py

# The browser cursor (no app needed)
curl http://192.168.0.108:8335/info
python3 Scripts/tvbrowser-cursor.py -6 -4 200

# ADB oracles
adb connect 192.168.0.108:5555
adb shell dumpsys power | grep mWakefulness
adb shell dumpsys audio | grep -A6 -- "- STREAM_MUSIC:" | grep streamVolume
adb shell settings get global picture_backlight
adb shell screencap -p /sdcard/s.png && adb pull /sdcard/s.png

# AltStore install / update — see docs/altstore.md for the one-time setup
./Scripts/package-ipa.sh               # -> build/RemoteControl.ipa, then AirDrop it

# Device install by cable (UDIDs in "Repo & branch state" above)
xcodegen generate
xcodebuild -project RemoteControl.xcodeproj -scheme RemoteControl \
  -destination 'platform=iOS,id=<udid>' \
  -allowProvisioningUpdates -derivedDataPath /tmp/rc-device build
xcrun devicectl device install app --device <udid> \
  /tmp/rc-device/Build/Products/Debug-iphoneos/RemoteControl.app
# `devicectl` sometimes fails the first time with a developer-disk-image
# error — just run it again.

# Simulator
xcodebuild -project RemoteControl.xcodeproj -scheme RemoteControl \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/rc-build build
xcrun simctl install booted /tmp/rc-build/Build/Products/Debug-iphonesimulator/RemoteControl.app
xcrun simctl launch booted com.example.RemoteControl
```

Paired TV: **`desktop` @ 192.168.0.108** (MiTV-MOSR1, Android 11, 1280×720).
The IP moves — discovery handles it, and nothing should hardcode it.

## History

- **2026-08-25** — AltStore set up for automatic 7-day renewal: AltServer 1.7.2
  installed on this Mac, `Scripts/package-ipa.sh` added, procedure and failure
  modes in `docs/altstore.md`. The per-phone setup is a manual checklist.
- **2026-08-23 (later)** — volume-down hit-target bug found by the user and
  fixed; sleep timer built, measured on hardware and rejected (branch
  `sleep-timer-abandoned`); brightness proven impossible over the protocol and
  possible over ADB; web-app migration answered and closed.
- **2026-08-23 (earlier)** — pacing fix (`SendPacer`, measured 8ms); Netflix
  typing closed with byte-level evidence; trackpad D-pad style with
  Acceleration toggle; mic button removed; cursor sensitivity and step distance
  measured and tuned on hardware; **shipped to a real iPhone**, which exposed
  and fixed the `.waiting` cursor bug; app icon.
- **2026-08-22 (Phase 4)** — the TV browser's cursor protocol, reverse-engineered
  from the APK and verified on hardware. Merged to `main`.
- **2026-08-21 (Phase 3)** — IME text mirror, search, pointer glide. Merged.
- **2026-08-19 (Phase 2)** — real Android TV connectivity. Merged.
- **2026-08-19 (Phase 1)** — SwiftUI UI on a mocked controller.
