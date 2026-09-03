# android-tv-remote-ios

A SwiftUI iPhone remote for Android TV, speaking Google's **Android TV Remote
v2** protocol directly — no vendor app, no cloud, no account. It pairs over the
local network, survives the TV changing IP, and mirrors the TV's on-screen text
field so you can type with the phone keyboard.

Built and verified against a Xiaomi TV P1e 32 (Android 11). Anything running
Android TV's standard remote service should work; the browser-cursor feature
below is narrower.

## What it does

- **Pairing and control** — Bonjour discovery, certificate pairing with the
  6-character code the TV displays, then D-pad, OK/Back/Home, volume and power.
- **Trackpad** — an Apple TV–style swipe pad that turns gestures into directional
  key presses, with inertia and a repeat pacer.
- **Keyboard / IME** — the TV's focused text field is mirrored on the phone and
  edits are written back, so search boxes are typed rather than pecked out
  letter-by-letter on screen. Handles the TV's batch-edit and counter semantics.
- **YouTube and web search** — deep links straight to a query.
- **Real 2D browser cursor** — a genuine pointer inside the TV's browser app.
  Remote v2 provably cannot do this (its virtual input device declares `KEY`
  events only), so this rides a second, unrelated protocol on port 8335 that
  the TV browser speaks. See `docs/tvbrowser-remote-protocol.md`.

## Requirements

- macOS with Xcode 16+ (Swift 6)
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- An iPhone on iOS 17+, on the same Wi-Fi as the TV
- An Apple Developer account. A free "Personal Team" is enough, but the profile
  Apple issues then lasts **7 days**, after which the app must be installed
  again — see `docs/altstore.md` for automating that away.

## Setup

```bash
# 1. Generate your own client identity (see the note below — this is required).
./Scripts/generate-identity.sh

# 2. Put your Apple Team ID in project.yml, replacing YOUR_TEAM_ID.
#    Xcode > Settings > Accounts, or developer.apple.com > Membership.

# 3. Generate the Xcode project and open it.
xcodegen generate
open RemoteControl.xcodeproj
```

Then run on a device (the simulator has no Bonjour access to the TV, so
discovery finds nothing there). On first launch, allow **Local Network**
access — without it nothing is discovered at all.

### About the client identity

The pairing protocol authenticates the remote with a client certificate, and
**this repo deliberately ships without one**. A private key committed to a
public repo would let anyone who cloned it impersonate your remote to any TV
that had paired with it. `Scripts/generate-identity.sh` writes your own into
`RemoteCore/Sources/RemoteCore/Resources/`, which is git-ignored. Re-running it
rotates the identity and un-pairs every TV.

## Tests

```bash
./Scripts/test.sh     # 220 tests
```

The core is a plain Swift package (`RemoteCore`) with no UI dependency, so the
protocol, wire format, pacing and gesture engines are all tested headlessly
against captured real-hardware fixtures in `docs/ime-captures.md`.

## Poking at the protocol

`rc-probe` is a CLI for talking to a TV without the app in the way — the fastest
debugging loop by a wide margin:

```bash
./Scripts/probe.sh discover
./Scripts/probe.sh pair <ip>
./Scripts/probe.sh key  <ip> down
./Scripts/probe.sh dump <ip>     # listen; annotate what the TV sends
```

## Layout

| Path | What |
|---|---|
| `App/` | SwiftUI views — remote, trackpad, keyboard sheet, settings |
| `RemoteCore/` | Protocol, discovery, persistence, gesture engines, tests |
| `RemoteCore/Sources/rc-probe/` | The protocol CLI |
| `Scripts/` | Identity, tests, probe wrapper, .ipa packaging, cursor bridge |
| `docs/` | Protocol findings, wire captures, hardware checklists, handoff notes |
| `design/` | Design canvases for the UI |

`docs/tvbrowser-remote-protocol.md` and `docs/ime-captures.md` are the
interesting ones — both are reverse-engineering write-ups with the wire bytes
that back every claim.

## Third-party

Depends on [AndroidTVRemoteControl](https://github.com/odyshewroman/AndroidTVRemoteControl)
(pinned by revision) for the Remote v2 TLS and crypto managers.

## License

None. This is published to be read, not reused — all rights reserved.
