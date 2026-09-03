# Phase 2 — Real connectivity to Android TV (design spec)

**Date:** 2026-08-19
**Status:** Approved design, binding for the Phase 2 plan.
**Predecessor:** `2026-08-19-tv-remote-design.md` (Phase 1, UI on a mocked controller).

## Goal

Replace the mock behind the `TVController` seam with a real implementation that
discovers, pairs with, and controls the user's Xiaomi TV P1e 32 — and, by
construction, **any Android TV / Google TV device** — over the LAN using the
Android TV Remote protocol v2. The Phase 1 views keep working with minimal
changes (one flow change in Connect, listed below).

**Non-goals:** Samsung/LG/Roku/Fire TV (different protocols; future transports
behind the same seam), Wake-on-LAN power-on of a fully-off TV, mic search,
iPad, multi-TV UI.

## Success criteria (tonight's test, in order)

1. The real TV appears on the Connect screen via mDNS discovery.
2. Pairing: tap TV → TV displays a 6-character code → enter it → paired.
3. Certificate identity persists: relaunch app → reconnects silently, no code.
4. D-pad, OK, Back, Home, volume/mute work on the real TV.
5. After the core works: keyboard text entry and app tiles (verify-first, see
   Risks).

## Locked decisions

- **Protocol implementation is a dependency, not our code:**
  [`odyshewroman/AndroidTVRemoteControl`](https://github.com/odyshewroman/AndroidTVRemoteControl)
  (MIT, **pinned by commit revision `32393c3`** — the latest tag 2.4.16 is from
  Aug 2024 and misses the connection-timeout feature). It provides the v2 pairing handshake
  (port 6467), the pairing-secret hash, and the remote-control session
  (port 6466). We write **no wire-format code**.
- **Dependency rule amended:** "no external runtime dependencies" (Phase 1)
  becomes **"Apple platforms + this one pinned MIT package."** Rationale: the
  protocol bytes are the highest-risk code in the phase and this package has
  been validated against real TVs since 2023; re-implementing it has strictly
  more unknowns.
- **Client certificate: generated once at dev time (openssl), bundled in the
  app.** **Must be RSA-2048** — the library computes the pairing secret from
  RSA modulus/exponent and rejects non-RSA keys (`.notRSAKey`). Two bundled
  artifacts: a password-protected `.p12` (TLS identity) and the public
  certificate as a separate file (pairing-hash input). One identity for the
  whole app; each TV remembers it at pairing. No runtime certificate
  generation, no swift-certificates/crypto/protobuf.
  Accepted trade-off: all installs share one identity and the key ships in the
  bundle — fine for a personal LAN remote; an App Store release would move to
  per-install generation (isolated inside `IdentityProvider`, so swappable).
- **Brand scope:** discovery lists every `_androidtvremote2._tcp` device, no
  Xiaomi filtering. Class names are Android-TV-flavoured, never Xiaomi.
- Phase 1 visual design stays locked (accent `#FF8B3D`, D-pad default,
  text-only tiles, portrait iPhone, iOS 17+).

## Architecture

```
App/                          views (Connect flow + code-entry fix; rest as-is)
RemoteCore/
  TVController (protocol, revised — see below)
  ├─ MockTVController         stays; previews + existing tests, new shape
  └─ AndroidTVController      ~250 lines: adapter over the library —
       │                      connection state, reconnect policy, backgrounding
       ├─ DeviceDiscovery     ~80 lines: NWBrowser over _androidtvremote2._tcp
       ├─ IdentityProvider    loads bundled .p12 + public cert (Security fw)
       └─ AndroidTVRemoteControl   [SPM, revision pin] — all protocol bytes
  rc-probe                    macOS CLI executable target: drives the library
                              directly against the TV, prints every state —
                              fast debug loop, isolates library-vs-adapter
```

Everything above the package is app plumbing: adapter, discovery, state, UI.
`AndroidTVController` is the only class that imports the library; if the
library disappoints, it is replaced behind the seam without touching views.

## Revised `TVController` protocol

Changes are forced by reality, not taste:

```swift
@MainActor
public protocol TVController: AnyObject {
    var connectionState: ConnectionState { get }
    var discoveredDevices: [DiscoveredDevice] { get }   // live: mDNS trickles in

    func startDiscovery()
    func stopDiscovery()

    func beginPairing(with device: DiscoveredDevice) async throws  // TV shows code
    func submitPairingCode(_ code: String) async throws -> PairedDevice
    func cancelPairing()

    func connect(to device: PairedDevice) async throws
    func disconnect()                                   // phase2-notes gap, closed

    func sendKey(_ key: KeyCommand)                     // fire-and-forget
    func sendText(_ text: String)                       // fire-and-forget
}
```

- `discover() async -> [DiscoveredDevice]` is replaced by start/stop + an
  observable array: mDNS is a stream, not a one-shot.
- `pair(device:code:)` splits: the TV only displays a code **in response to**
  a pairing request. Sequence: tap device → `beginPairing` → TV shows code →
  user types → `submitPairingCode`.
- Pairing methods `throw` (wrong code, timeout, refused); Phase 1's cannot-fail
  signature was a mock artifact.
- `sendKey`/`sendText` stay non-async — button presses must not await; delivery
  problems surface via `connectionState`, which `RemoteView` already observes.
- `PairedDevice` gains the mDNS service name alongside the last-known IP:
  reconnect tries the IP, and on failure re-resolves the service name (router
  reassigned the TV's address). Stored in `DeviceStore` as today (UserDefaults;
  it holds no secrets — the identity is the bundled cert).

`MockTVController` adopts the new shape (instant fake discovery, any 6-char
code accepted, state transitions preserved) so previews and tests keep working.

## Pairing flow and Connect-screen changes

The one place Phase 1's "views need zero changes" bet breaks:

1. Tap a device → `beginPairing` → card shows "Look at your TV…" progress
   state (new intermediate state).
2. TV displays the code → user types it. **The code is 6-character
   hexadecimal**, not numeric: the field switches from `.numberPad` +
   `isNumber` filter to `.asciiCapable` + filter `isHexDigit`, uppercased.
3. Wrong code → inline error, field clears and stays active for retry
   (TV keeps showing its code); `cancelPairing` on leaving the card.
4. Success → `PairedDevice` saved, root flips to `RemoteView` (as today).

Also absorbed from `docs/phase2-notes.md` while we are in these files:

- `disconnect()` called from `onUnpair` (Settings).
- Settings "Connected" badge driven by `connectionState`, not hardcoded.
- Code field disabled while a submission is in flight; pairing errors surfaced.
- Accessibility labels: icon-only buttons, hidden code TextField, keyboard
  sheet TextField.
- Stray literal colors consolidated into `Theme`.

## Connection lifecycle

| Event | Behaviour |
|---|---|
| App launch with paired device | `connect(to:)`; failure → stays `disconnected`, header dot grey |
| Scene → background | `disconnect()` (iOS kills LAN sockets in background anyway) |
| Scene → foreground | reconnect if a paired device exists |
| Socket drops (TV sleeps, Wi-Fi blip) | state → `disconnected`; next keypress triggers one reconnect attempt |
| Stored IP dead | re-resolve service name via mDNS, retry once, then give up quietly |
| TV rejects our certificate (unpaired us) | clear `DeviceStore`, return to Connect screen |
| Power button | toggles standby only; a mains-off TV cannot be woken by this protocol (documented non-goal) |

The v2 control session includes TV-initiated pings; the library's
`RemoteManager` owns the session and keepalive. The adapter's job is policy:
when to connect, when to retry, what to publish as `connectionState`.

## iOS platform requirements (new in this phase)

- `project.yml` → `Info.plist` gains:
  - `NSLocalNetworkUsageDescription` (user-facing rationale string)
  - `NSBonjourServices` = `["_androidtvremote2._tcp"]`
  Without both, iOS 14+ makes discovery **silently return nothing**.
  `NSBonjourServices` is an array, which `INFOPLIST_KEY_` build settings can't
  express — the target moves from `GENERATE_INFOPLIST_FILE` to xcodegen's
  `info:` block (generated plist file with explicit properties).
- Connect screen handles the permission-denied state: explanatory text + button
  to open Settings (exact detection mechanism — NWBrowser error state vs. permanently-empty results —
  is an implementation-time decision).
- The bundled identity (PKCS#12) is loaded with `SecPKCS12Import` at first use
  and kept in memory; no Keychain write needed for a bundled cert.

## Testing strategy

| What | How | Needs TV? |
|---|---|---|
| Protocol bytes | Not our code — pinned library, validated upstream | No |
| Adapter state machine | Unit tests against a `TVControllerTransport`-style fake of the library surface: pairing success/failure/cancel, reconnect policy, background/foreground | No |
| Mock + persistence | Existing 12 tests, updated to the new protocol shape | No |
| Discovery, TLS, real pairing, keys | Manual, tonight, on the real TV, with verbose `os_log` on every library callback | **Yes** |

The macOS CLI harness is **in**: the library compiles for macOS unmodified
(verified — SPM `platforms:` sets minimums, not exclusive support; imports are
Foundation/Network/CryptoKit only). `rc-probe` is a small executable target in
`RemoteCore` that drives the library directly (not the adapter) with a verbose
logger: `discover`, `pair <host>`, `key <host> <key>`. At dinner it separates
"library+TV works" from "our adapter works" and iterates in seconds.

Swift-6 note: the library is callback-based, written pre-strict-concurrency
(tools 5.8). The adapter uses `@preconcurrency import` and hops every callback
onto the MainActor before touching published state.

## Risks — ranked, with mitigations

1. **Library quality.** Hobby-grade: open crash report (array index), pairing
   issues, thin maintainer response. Mitigations: exact-version pin; adapter
   wraps every callback defensively; MIT + small, so we can read and fork;
   swappable behind the seam.
2. **Text entry (keyboard sheet).** Source-verified: the library has **no**
   text/IME message. Options, decided at the keyboard task with the TV
   present: (a) per-character key events — **ASCII only; no Cyrillic search**;
   (b) author the single text message ourselves via the library's public
   `send(_ request: RequestDataProtocol)` extension point (small, contained
   wire code, no fork); (c) defer the sheet to Phase 3 (ships disabled with a
   note). Do not promise Cyrillic input in this phase.
3. **App tiles.** Source-verified: `DeepLink` is supported by the library.
   Remaining risk is only the per-app URIs (Netflix/YouTube/Prime), verified
   against the real TV; deferring tiles to Phase 3 remains acceptable.
4. **First-run permission UX.** The local-network prompt appears at first
   discovery; a mis-tap leaves the app looking broken. Mitigated by the
   explicit denied-state UI.

## Task shape (for the plan)

Roughly 10 tasks, same rhythm as Phase 1 (subagent per task, review gate each):
dependency + revision pinning → dev-time RSA cert script + `IdentityProvider`
→ protocol revision + `MockTVController` + test updates → `DeviceDiscovery` →
`rc-probe` CLI harness → `AndroidTVController` pairing path → control path +
lifecycle policy → Connect-screen flow + hex fix + permission UX (info: block)
→ Settings/unpair/badge + accessibility absorbs → keyboard sheet
(option-decision task) → app tiles (URI verification). Manual TV test
checklist as the closing gate.
