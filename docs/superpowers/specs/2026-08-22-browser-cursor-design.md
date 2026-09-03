# Real cursor in the TV browser — design

**Status:** approved; plan at `docs/superpowers/plans/2026-08-22-browser-cursor.md`
**Protocol reference:** `docs/tvbrowser-remote-protocol.md` (verified 2026-08-22)

## Goal

Give Pointer mode a real 2D cursor — any direction, any curve — inside the TV
browser, driven like a laptop trackpad, with tap-to-click.

## Why this is possible now

Android TV Remote v2 **cannot** move a pointer: its uinput device
(`virtual-remote`) declares `KEY` events only. That ceiling is absolute.

The TV browser (`com.internet.tvbrowser`) runs its own Ktor server advertising
`_zeusremote._tcp`, taking protobuf `CursorMove{action, dx, dy}` events with
relative **float** deltas over a WebSocket. Verified end to end from a laptop.

**Nothing is installed on the TV.** The server is inside a browser the user
already has and already uses. This is a hard constraint from the user: if the
feature ever required sideloading, it would not be built.

## Locked decisions

| Decision | Choice |
|---|---|
| Scope | **Cursor move + click only.** Not scroll, drag, pinch, keyboard, tabs. |
| Integration | **One Pointer mode that upgrades itself.** Real cursor when the browser is reachable; 4-way key glide otherwise. |
| Status | **Visible indicator** of which cursor is active — never a silent switch. |
| Gesture | **Trackpad-relative.** Drag moves by that much; lift and reposition; tap clicks. |
| Absolute mapping | **Rejected.** The protocol sends only deltas, so absolute needs corner-slam homing and desyncs invisibly whenever the physical remote moves the cursor. |

## Architecture

A **separate transport**, deliberately not folded into `AndroidTVController`.
The two protocols share nothing: different port, different discovery, different
wire format, different lifetime. Keeping them apart means the vendor protocol
breaking cannot destabilise the remote that works.

### New files (all in `RemoteCore`)

**`CursorMessages.swift`** — pure encoding, no I/O.
Hand-rolled protobuf, matching the `Wire`/`ImeMessages` house style, byte-pinned
to captures from the working spike.

```swift
enum CursorMessages {
    static func move(dx: Float, dy: Float) -> Data   // 0A 0C 08 02 15 <dx f32 LE> 1D <dy f32 LE>
    static func click() -> Data                       // 22 00  — CursorClick is an EMPTY message
}
```

Both are **hardware-verified** (2026-08-22): `22 00` sent while hovering a
search-result link navigated the browser to it, and `qb/q`'s descriptor string
is `"\u0000\u0000"` (zero fields). Deltas map **1:1 to TV pixels** with no
acceleration on this TV — 20 × (7.1, 14.05) landed the cursor exactly (+142,
+281) from where it started. `dy > 0` is DOWN, same as phone screen
coordinates, so no axis inversion.

**`BrowserCursorDiscovery.swift`** — browses `_zeusremote._tcp`.
Mirrors `DeviceDiscovery` and shares its IPv4-pinned resolve. Publishes host
**and port** — the port is not hardcoded anywhere, because the service
advertises it (this is why `8335` appears in no source file). `hostString(from:)`
drops the port, so a sibling `hostPort(from:)` is added.

**iOS blocks Bonjour browsing of any type not whitelisted** in
`NSBonjourServices`. `project.yml` lists only `_androidtvremote2._tcp`; it must
also list `_zeusremote._tcp`, then `xcodegen generate`. Without this the browse
silently finds nothing and the feature looks broken.

**`BrowserCursorClient.swift`** — `@MainActor @Observable`, the whole lifecycle.

```swift
public final class BrowserCursorClient {
    public private(set) var isAvailable: Bool     // drives the UI indicator
    public func matchAndConnect(toHost: String)   // only the TV we're paired to
    public func move(dx: Float, dy: Float)
    public func click()
    public func disconnect()
}
```

Transport is `URLSessionWebSocketTask` — Foundation, no new dependency, no
hand-rolled framing. It sits behind a small internal socket seam so the
client's host matching, open/close tracking and send gating are unit-tested
with a fake socket; only the socket itself needs the TV.

`isAvailable` flips true on the WebSocket **open** delegate callback, not on
`resume()`. The client keeps a `receive()` loop pending (without one a close
frame is never noticed) and a WebSocket-level ping every 10 s; any error drops
to unavailable and, while the service is still advertised, reopens after 2 s.

### Protocol boundary

`TVController` is **not** extended. The app owns a `BrowserCursorClient`
alongside its controller and hands it to `PointerView`. When the vendor changes
their format, one file changes and the remote is untouched.

## Behaviour

**Availability.** Browse continuously while connected. A service is only used
when its resolved host matches the paired TV's host — a second TV on the LAN
must never receive our cursor. `isAvailable` is true only while the WebSocket
is open.

**Sending.** A pure, clock-injectable `TrackpadEngine` (sibling of
`PointerEngine`) turns `DragGesture` points into deltas scaled by a named
sensitivity (default 2.0: the pad is ~330pt wide against 1280px, measured 1:1
on the TV, so one full swipe crosses about half the screen — tune on hardware).
It coalesces callbacks closer than 16 ms into one message and flushes the tail
on release so no motion is lost.
There is **no 80ms pacing floor here** — that is a Remote-v2 constraint and
does not apply. The spike sent at 20ms intervals without complaint.

**Clicking.** A tap with no meaningful movement sends `click()`. A tap that
follows a drag must not fire, or every move ends in an accidental click.

**Falling back.** If the socket drops or the browser closes, `isAvailable` goes
false and Pointer mode reverts to held-key glide with the indicator updating.
No error dialog — degrading to something that works is not an error.

**Held keys.** The two mechanisms must never run at once: entering real-cursor
mode releases any held direction first. A leaked `START_LONG` leaves the TV
scrolling by itself.

## Testing

Unit tests (deterministic, no TV): encoder byte-for-byte against captured
frames — `0a0c0802150000c0c01d000080c0` is a known-good `move(-6, -4)`;
gesture-to-delta conversion including the scale factor; tap-vs-drag
discrimination; host matching, including the reject case.

`TVController` and `MockTVController` are **untouched**. The cursor client has
its own seam — `BrowserCursorControlling` (`isAvailable`, `move`, `click`) —
with `MockBrowserCursorClient` recording an ordered event log for previews and
tests, and `BrowserCursorClient` tested through an injected fake socket.

**Hardware is the real gate.** Three bugs this project shipped were invisible to
a green suite and only appeared at the TV. Verify with `adb shell screencap` —
the cursor appears in captures, so its position is machine-checkable without
watching the screen.

## Risks

- **Private protocol, no contract.** A browser update can change the format and
  break this with no warning. Mitigated by isolation, not prevented.
- **Depends on that browser staying installed.** If it goes, the feature goes;
  the fallback is why this degrades rather than breaks.
- **No authentication on port 8335.** Anyone on the LAN can drive the cursor.
  Not ours to fix, and not made worse by us — but it should be known.
- **`cursor_acceleration` exists** in that app's settings. If enabled, the TV
  may move further than requested. Harmless for trackpad-relative; it would
  have been fatal for absolute mapping.

## Out of scope

Scroll, drag, pinch, keyboard input, tab control, and the `q1` TV→phone state
channel (tabs, playback, keyboard state) — all mapped in the protocol doc if
they are ever wanted.
