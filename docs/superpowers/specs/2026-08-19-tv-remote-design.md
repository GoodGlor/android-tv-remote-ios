# Xiaomi TV Remote (iOS) — Design

**Date:** 2026-08-19
**Status:** Approved (visual design locked on canvas)
**Target:** Xiaomi TV P1e 32 (Android TV); iPhone app, SwiftUI, iOS 17+

## Overview

An iOS remote control app for the Xiaomi TV P1e 32. Work is split in two phases:

- **Phase 1 (this spec):** the complete UI per the approved mockups, with a stubbed control layer behind a protocol seam. Fully navigable app; no real TV communication.
- **Phase 2 (separate spec later):** real connectivity — mDNS discovery, Android TV Remote protocol v2 pairing and control.

## Visual design (locked)

Approved mockups: design canvas "P1e Remote" (https://claude.ai/code/artifact/196ca854-3264-43b4-b6b3-cc8259f54c20); working files in `design/*.dc.html`.

- **Style:** dark & minimal. Background `#0C0D11`, cards/surfaces `#14151A`–`#1D1E24`, primary text `#F2F2F5`, secondary `#8E8E96`/`#6E6E78`, hairlines `white @ 6%`.
- **Accent:** default `#FF8B3D` (Mi-adjacent orange); alternatives `#0A84FF` (iOS blue), `#F5F5F7` (neutral). Single accent token used for: OK button fill, active toggle segment, switches, primary CTAs, text cursor, link-style rows.
- **Status colors:** connected green `#34C759`; power tint `#FF6B61` on `rgba(255,69,58,0.14)`.
- **Type:** SF (system font). Icons: thin-stroke style — SF Symbols in the app.
- **Touch targets:** ≥ 44 pt. Frequent controls sit in the lower two-thirds for one-handed reach.

## Screens

1. **Connect** — title + "same Wi-Fi" hint; discovered-device list (name + IP); pairing card with 6-digit code boxes; full-width accent **Pair** button. Shown on launch when no TV is paired.
2. **Main remote** — header (TV name, connection dot, gear); power / input / mic row; D-pad↔touchpad segmented toggle; large circular D-pad with accent **OK** (D-pad is the default mode); Back · Home · Menu row; VOL rocker · Mute · CH rocker; rew · play/pause · ffwd; app shortcut tiles (Netflix, YouTube, Prime, Mi TV — text labels, no brand logos) + keyboard button.
3. **Touchpad mode** — the D-pad circle is replaced by a full-width swipe surface ("Swipe to move · Tap to select"); everything else identical. App remembers last-used mode.
4. **Keyboard sheet** — sheet over the dimmed remote: grab handle, "Type to your TV", text field, accent **Done**; system keyboard below. Text is forwarded as typed.
5. **Settings** — pushed from the gear: TV group (paired device + Connected badge, "Add a TV…"), Remote group (Haptic feedback toggle), About group (Version).

## Architecture (Phase 1)

SwiftUI, MVVM-lean. Units and their seams:

- **`RemoteControlApp`** — entry point. Routing: no paired device → Connect; otherwise Main remote.
- **Views** — `ConnectView`, `RemoteView` (composed of `DPadView` / `TouchpadView`, `RockerView`, `MediaRowView`, `AppShortcutsView`), `KeyboardSheet`, `SettingsView`. Each view is dumb: renders state, forwards intents.
- **`TVController` (protocol)** — the Phase-2 seam. `sendKey(_ key: KeyCommand)`, `sendText(_:)`, `connectionState` (published), `discover()`, `pair(device:code:)`. Phase 1 ships **`MockTVController`** which logs commands and simulates discovery/pairing/connected state.
- **`KeyCommand` (enum)** — `power, up, down, left, right, ok, back, home, menu, volumeUp, volumeDown, mute, channelUp, channelDown, rewind, playPause, fastForward, input, launchApp(AppShortcut)`.
- **`DeviceStore`** — persists the paired device (name, host) in `UserDefaults`.
- **`Theme`** — one file holding the color tokens and the user-selected accent.
- **Haptics** — light impact on every key press via `UIImpactFeedbackGenerator`, gated by the Settings toggle.

**Data flow:** View → `TVController` → (mock log / later network). Connection state flows back as observable state to the header dot and Connect flow.

## Error handling (Phase 1)

`MockTVController` always succeeds. The UI still models the disconnected state: gray header dot, key presses become no-ops. Real error surfaces (pairing failure, TV unreachable) are Phase 2.

## Testing

- **Unit:** `KeyCommand` completeness, `DeviceStore` persistence round-trip, routing logic (paired vs. not), mock controller state transitions.
- **Visual:** SwiftUI previews per screen checked against the locked mockups.
- Phase 2 adds protocol-level tests.

## Out of scope (Phase 2)

mDNS discovery (`_androidtvremote2._tcp`), Android TV Remote protocol v2 (TLS pairing with the 6-digit code, protobuf messages), mic search, real app launching, iPad layout.
