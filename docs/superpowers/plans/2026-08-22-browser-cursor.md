# Real cursor in the TV browser — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pointer mode moves a real 2D cursor in the TV browser — any direction, any curve — driven like a laptop trackpad, with tap-to-click, falling back to today's 4-way key glide when the browser is not there.

**Architecture:** A second transport, fully separate from `AndroidTVController`. Hand-rolled protobuf (`CursorMessages`) over a `URLSessionWebSocketTask`, reached by a Bonjour browse of `_zeusremote._tcp`, behind a `BrowserCursorControlling` seam so `TVController` is untouched. A pure `TrackpadEngine` turns drags into deltas.

**Tech Stack:** Swift 6 / SwiftUI / swift-testing (`@Test`, `#expect`), SwiftPM package `RemoteCore`. No new dependencies — `URLSessionWebSocketTask` and `NWBrowser` are Foundation/Network.

**Spec:** `docs/superpowers/specs/2026-08-22-browser-cursor-design.md` — read it first.
**Protocol truth:** `docs/tvbrowser-remote-protocol.md` — every byte below is hardware-verified fact recorded there.

## Global Constraints

- Every `swift` / `xcodebuild` / `xcrun` command needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- **Never run bare `swift test`** — always `./Scripts/test.sh`.
- Dependency rule: Apple platforms + the one pinned package. Nothing new.
- **`TVController` and `MockTVController` must not change.** The vendor protocol is private and unstable; it lives behind its own seam so that when it breaks, the working remote does not.
- **The 80ms pacing floor does NOT apply here.** That is a Remote-v2 constraint. This socket took 20ms intervals happily. Do not copy that gate into this path.
- **A held direction key and the real cursor must never be active at once.** Any path that enters real-cursor mode releases the hold first — a leaked `START_LONG` leaves the TV scrolling by itself.
- TDD: each task writes failing tests first. All **137** existing tests must stay green.
- After changing `project.yml`, run `xcodegen generate`.

---

### Task 1: `CursorMessages` — protobuf encoders pinned to verified bytes

**Files:**
- Create: `RemoteCore/Sources/RemoteCore/CursorMessages.swift`
- Test: `RemoteCore/Tests/RemoteCoreTests/CursorMessagesTests.swift`

**Interfaces:**
- Consumes: `Wire.field(_:varint:)` and `Wire.field(_:bytes:)` (already exist, internal).
- Produces: `enum CursorMessages` (internal): `static func move(dx: Float, dy: Float) -> Data`, `static func click() -> Data`.

- [ ] **Step 1: Write the failing tests**

`RemoteCore/Tests/RemoteCoreTests/CursorMessagesTests.swift`:

```swift
import Foundation
import Testing
@testable import RemoteCore

// Every fixture is a frame that moved a real TV's cursor on 2026-08-22.
// See docs/tvbrowser-remote-protocol.md.

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

@Test func moveMatchesTheVerifiedWireBytes() {
    // RemoteEvent{cursor_move=1} -> CursorMove{action=MOVE(2), dx=-6, dy=-4}
    #expect(hex(CursorMessages.move(dx: -6, dy: -4)) == "0a0c0802150000c0c01d000080c0")
}

@Test func moveEncodesPositiveDeltasLittleEndian() {
    // 15.0 = 0x41700000, 10.0 = 0x41200000 — both little-endian on the wire.
    #expect(hex(CursorMessages.move(dx: 15, dy: 10)) == "0a0c080215000070411d00002041")
}

@Test func moveIsAlwaysFourteenBytes() {
    // Fixed length: tag+varint (2) + tag+float (5) + tag+float (5) = 12 body
    // bytes, so the outer length is always the single varint byte 0x0c.
    for (dx, dy) in [(Float(0), Float(0)), (0.5, -0.5), (1000, -1000)] {
        let data = CursorMessages.move(dx: dx, dy: dy)
        #expect(data.count == 14)
        #expect(data[0] == 0x0a)
        #expect(data[1] == 0x0c)
    }
}

@Test func clickIsAnEmptyMessageOnFieldFour() {
    // CursorClick genuinely has no fields (its protobuf descriptor declares
    // zero). Verified on hardware: these two bytes, sent while the cursor
    // hovered a search result, navigated the browser to that link.
    #expect(hex(CursorMessages.click()) == "2200")
}

@Test func zeroDeltaStillEncodesBothAxes() {
    // Must NOT omit zeros the way a proto3 encoder omits scalar defaults: the
    // fixed32s are read positionally here, and this project has been bitten by
    // helpful omission before.
    #expect(hex(CursorMessages.move(dx: 0, dy: 0)) == "0a0c080215000000001d00000000")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./Scripts/test.sh --filter CursorMessages`
Expected: FAIL — "cannot find 'CursorMessages' in scope".

- [ ] **Step 3: Write the implementation**

`RemoteCore/Sources/RemoteCore/CursorMessages.swift`:

```swift
import Foundation

/// Encoders for the TV browser's OWN remote protocol — not Android TV Remote
/// v2. Different port, different wire format, different server (a Ktor
/// endpoint inside `com.internet.tvbrowser`). See
/// docs/tvbrowser-remote-protocol.md; every byte below is pinned to a frame
/// that moved a real TV's cursor.
///
/// Why this exists at all: Remote v2 physically cannot move a pointer. Its
/// uinput device declares KEY events only — no REL, no ABS — so no message
/// over that protocol can do this. This one takes relative FLOAT deltas.
enum CursorMessages {
    /// `RemoteEvent{ cursor_move = 1 }` wrapping
    /// `CursorMove{ action = MOVE, dx, dy }`.
    ///
    /// Deltas are relative and, on the verified TV, 1:1 with screen pixels
    /// (20 sends of (7.1, 14.05) moved the cursor exactly +142, +281). `dy > 0`
    /// is DOWN — the same sense as phone screen coordinates, so callers need
    /// no axis flip.
    static func move(dx: Float, dy: Float) -> Data {
        var body = Wire.field(1, varint: UInt64(MotionAction.move.rawValue))
        body += fixed32(2, dx)
        body += fixed32(3, dy)
        return Data(Wire.field(1, bytes: body))
    }

    /// `RemoteEvent{ cursor_click = 4 }` wrapping an EMPTY `CursorClick`.
    ///
    /// The message genuinely has no fields, so the click lands wherever the
    /// cursor already is. Two bytes total: field 4, wire type 2, length 0.
    static func click() -> Data {
        Data(Wire.field(4, bytes: []))
    }

    /// Android `MotionEvent` actions, as the TV browser's enum orders them.
    /// Only `.move` is used today; the rest are named because the wire values
    /// are theirs and a future drag would need `down`/`up`.
    private enum MotionAction: Int {
        case down = 0, up = 1, move = 2, cancel = 3
        case outside = 4, pointerDown = 5, pointerUp = 6
    }

    /// A protobuf fixed32 field carrying an IEEE-754 float, little-endian.
    /// Wire type 5, so the tag is `number << 3 | 5`.
    private static func fixed32(_ number: Int, _ value: Float) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(number << 3 | 5)]
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        return bytes
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./Scripts/test.sh --filter CursorMessages`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the whole suite**

Run: `./Scripts/test.sh`
Expected: PASS — 142 tests (137 + 5).

- [ ] **Step 6: Commit**

```bash
git add RemoteCore/Sources/RemoteCore/CursorMessages.swift RemoteCore/Tests/RemoteCoreTests/CursorMessagesTests.swift
git commit -m "feat: protobuf encoders for the TV browser's cursor protocol"
```

---

### Task 2: `TrackpadEngine` — drags into deltas

**Files:**
- Create: `RemoteCore/Sources/RemoteCore/TrackpadEngine.swift`
- Test: `RemoteCore/Tests/RemoteCoreTests/TrackpadEngineTests.swift`

**Interfaces:**
- Consumes: nothing (pure value type, leaf).
- Produces:
  - `public struct TrackpadRelease: Equatable, Sendable { public let flush: CGVector?; public let isTap: Bool }` with a public memberwise init.
  - `public struct TrackpadEngine: Sendable` with `public init(sensitivity: CGFloat = 2, tapDistance: CGFloat = 12, minInterval: Duration = .milliseconds(16))`, `public mutating func began(at: CGPoint)`, `public mutating func moved(to: CGPoint, now: Duration) -> CGVector?`, `public mutating func ended(at: CGPoint, now: Duration) -> TrackpadRelease`, `public mutating func cancel()`.

**Why a separate engine rather than extending `PointerEngine`:** they answer different questions. `PointerEngine` answers "which single direction should be HELD right now" for a 4-way device. This one answers "how far did the finger move since I last told the TV". Merging them would make one type serve two protocols — exactly the coupling the spec set out to avoid.

- [ ] **Step 1: Write the failing tests**

`RemoteCore/Tests/RemoteCoreTests/TrackpadEngineTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import RemoteCore

// A 60Hz drag is ~16ms per update; fixtures use that spacing.
private let frame = Duration.milliseconds(16)

@Test func aDragEmitsTheScaledDelta() {
    var engine = TrackpadEngine()   // sensitivity 2
    engine.began(at: .zero)
    #expect(engine.moved(to: CGPoint(x: 10, y: 5), now: frame) == CGVector(dx: 20, dy: 10))
}

@Test func deltasAreRelativeToTheLastPointNotTheStart() {
    var engine = TrackpadEngine(sensitivity: 1)
    engine.began(at: .zero)
    #expect(engine.moved(to: CGPoint(x: 10, y: 0), now: frame) == CGVector(dx: 10, dy: 0))
    // Second update moves another 5 — NOT 15. Absolute would drift the cursor
    // away at an accelerating rate.
    #expect(engine.moved(to: CGPoint(x: 15, y: 0), now: frame * 2) == CGVector(dx: 5, dy: 0))
}

@Test func downwardDragIsPositiveDyMatchingTheTV() {
    // The TV treats dy > 0 as DOWN, same as phone coordinates. An inversion
    // here would send the cursor the wrong way and be invisible in review.
    var engine = TrackpadEngine(sensitivity: 1)
    engine.began(at: .zero)
    #expect(engine.moved(to: CGPoint(x: 0, y: 30), now: frame)?.dy == 30)
}

@Test func updatesInsideTheIntervalCoalesceRatherThanSend() {
    var engine = TrackpadEngine(sensitivity: 1, minInterval: .milliseconds(16))
    engine.began(at: .zero)
    #expect(engine.moved(to: CGPoint(x: 4, y: 0), now: frame) == CGVector(dx: 4, dy: 0))
    // Two updates 4ms apart: both withheld, their motion banked.
    #expect(engine.moved(to: CGPoint(x: 6, y: 0), now: frame + .milliseconds(4)) == nil)
    #expect(engine.moved(to: CGPoint(x: 9, y: 0), now: frame + .milliseconds(8)) == nil)
    // Once the interval passes, the banked motion goes out as ONE delta —
    // nothing is dropped, it is merged.
    #expect(engine.moved(to: CGPoint(x: 10, y: 0), now: frame * 2) == CGVector(dx: 6, dy: 0))
}

@Test func releaseFlushesBankedMotion() {
    var engine = TrackpadEngine(sensitivity: 1, minInterval: .milliseconds(16))
    engine.began(at: .zero)
    _ = engine.moved(to: CGPoint(x: 40, y: 0), now: frame)
    #expect(engine.moved(to: CGPoint(x: 47, y: 0), now: frame + .milliseconds(2)) == nil)
    // Lifting must not swallow the last 7 points, or every drag ends slightly
    // short of where the finger stopped.
    let release = engine.ended(at: CGPoint(x: 47, y: 0), now: frame + .milliseconds(3))
    #expect(release.flush == CGVector(dx: 7, dy: 0))
    #expect(release.isTap == false)
}

@Test func aTapReportsATapAndNoMotion() {
    var engine = TrackpadEngine()
    engine.began(at: CGPoint(x: 100, y: 100))
    let release = engine.ended(at: CGPoint(x: 103, y: 102), now: frame)
    #expect(release.isTap)
    // A tap sends nothing: the jitter of a resting finger would otherwise
    // nudge the cursor off the thing being clicked.
    #expect(release.flush == nil)
}

@Test func aDragDoesNotEndInAnAccidentalClick() {
    var engine = TrackpadEngine()
    engine.began(at: .zero)
    _ = engine.moved(to: CGPoint(x: 90, y: 40), now: frame)
    #expect(engine.ended(at: CGPoint(x: 90, y: 40), now: frame * 2).isTap == false)
}

@Test func aDragThatReturnsToItsStartIsStillADragNotATap() {
    // Travel, not displacement. A loop back to the origin ends near where it
    // began; treating that as a tap would fire a click after a real drag.
    var engine = TrackpadEngine()
    engine.began(at: .zero)
    _ = engine.moved(to: CGPoint(x: 60, y: 0), now: frame)
    _ = engine.moved(to: CGPoint(x: 0, y: 0), now: frame * 2)
    #expect(engine.ended(at: .zero, now: frame * 3).isTap == false)
}

@Test func cancelEmitsNothingAndForgetsTheGesture() {
    var engine = TrackpadEngine()
    engine.began(at: .zero)
    _ = engine.moved(to: CGPoint(x: 50, y: 0), now: frame)
    engine.cancel()
    let release = engine.ended(at: CGPoint(x: 2, y: 0), now: frame * 2)
    #expect(release.flush == nil)
    #expect(release.isTap == false)
}

@Test func movedWithoutBeganStartsTheGestureRatherThanJumping() {
    // SwiftUI's DragGesture has no separate "began"; the first onChanged is
    // it. Treating that point as a delta from the origin would fling the
    // cursor across the screen.
    var engine = TrackpadEngine(sensitivity: 1)
    #expect(engine.moved(to: CGPoint(x: 200, y: 200), now: .zero) == nil)
    #expect(engine.moved(to: CGPoint(x: 210, y: 200), now: frame) == CGVector(dx: 10, dy: 0))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./Scripts/test.sh --filter TrackpadEngine`
Expected: FAIL — "cannot find 'TrackpadEngine' in scope".

- [ ] **Step 3: Write the implementation**

`RemoteCore/Sources/RemoteCore/TrackpadEngine.swift`:

```swift
import CoreGraphics
import Foundation // `hypot` — CoreGraphics does not reliably re-export the C math functions.

/// What a finger-up means: leftover motion to send, and whether it was a tap.
public struct TrackpadRelease: Equatable, Sendable {
    /// Motion banked since the last send, or nil when there is none.
    public let flush: CGVector?
    /// True when the gesture never really moved — the caller clicks.
    public let isTap: Bool

    public init(flush: CGVector?, isTap: Bool) {
        self.flush = flush
        self.isTap = isTap
    }
}

/// Turns a drag into relative deltas for the TV browser's cursor.
///
/// A sibling of `PointerEngine`, not a replacement: that one answers "which
/// single direction should be HELD right now" for a 4-way key device, this one
/// answers "how far has the finger moved since I last told the TV". Both exist
/// because the app has two cursor mechanisms and only one is available at a
/// time.
///
/// Pure and clock-injectable — `now` is passed in, so the coalescing rule is
/// unit-testable with no TV and no wall-clock waiting.
public struct TrackpadEngine: Sendable {
    /// Phone points to TV pixels. The pad is ~330pt wide against a 1280px
    /// screen and the TV applies no acceleration of its own (verified: deltas
    /// land 1:1), so at 2.0 one full swipe crosses about half the screen.
    /// Reasoned, not measured against a hand — expect to tune it.
    private let sensitivity: CGFloat
    /// Total travel below this is a tap. TRAVEL, not displacement: a drag that
    /// loops back to its origin must not be mistaken for a tap.
    private let tapDistance: CGFloat
    /// Minimum gap between sends. SwiftUI can deliver drag updates faster than
    /// the TV needs them; without this a fast swipe floods the socket with
    /// near-identical frames. Banked motion is merged, never dropped.
    ///
    /// This is NOT the Remote-v2 80ms pacing floor. That one exists because
    /// back-to-back key events close the control session; this socket took
    /// 20ms intervals during the spike without complaint.
    private let minInterval: Duration

    private var lastPoint: CGPoint?
    private var pending = CGVector(dx: 0, dy: 0)
    private var travel: CGFloat = 0
    private var lastSend: Duration?

    public init(
        sensitivity: CGFloat = 2,
        tapDistance: CGFloat = 12,
        minInterval: Duration = .milliseconds(16)
    ) {
        self.sensitivity = sensitivity
        self.tapDistance = tapDistance
        self.minInterval = minInterval
    }

    public mutating func began(at point: CGPoint) {
        lastPoint = point
        pending = CGVector(dx: 0, dy: 0)
        travel = 0
        lastSend = nil
    }

    /// The delta to send now, or nil to withhold (its motion is banked and
    /// goes out with the next send or the release).
    public mutating func moved(to point: CGPoint, now: Duration) -> CGVector? {
        guard let last = lastPoint else { began(at: point); return nil }
        let stepX = point.x - last.x
        let stepY = point.y - last.y
        lastPoint = point
        travel += hypot(stepX, stepY)
        pending.dx += stepX * sensitivity
        pending.dy += stepY * sensitivity
        guard let previous = lastSend else {
            lastSend = now
            return takePending()
        }
        guard now - previous >= minInterval else { return nil }
        lastSend = now
        return takePending()
    }

    /// Ends the gesture: any banked motion, and whether this was a tap.
    public mutating func ended(at point: CGPoint, now: Duration) -> TrackpadRelease {
        guard let last = lastPoint else { return TrackpadRelease(flush: nil, isTap: false) }
        travel += hypot(point.x - last.x, point.y - last.y)
        pending.dx += (point.x - last.x) * sensitivity
        pending.dy += (point.y - last.y) * sensitivity
        let wasTap = travel < tapDistance
        let flush = wasTap ? nil : takePending()
        cancel()
        return TrackpadRelease(flush: flush, isTap: wasTap)
    }

    /// Forgets the gesture without emitting anything — a cancelled drag, a
    /// disappearing view, or a switch away from the real cursor.
    public mutating func cancel() {
        lastPoint = nil
        pending = CGVector(dx: 0, dy: 0)
        travel = 0
        lastSend = nil
    }

    /// Hands over the banked motion and clears it. Nil when there is nothing
    /// worth a frame, so a resting finger sends no traffic at all.
    private mutating func takePending() -> CGVector? {
        guard pending.dx != 0 || pending.dy != 0 else { return nil }
        let vector = pending
        pending = CGVector(dx: 0, dy: 0)
        return vector
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./Scripts/test.sh --filter TrackpadEngine`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add RemoteCore/Sources/RemoteCore/TrackpadEngine.swift RemoteCore/Tests/RemoteCoreTests/TrackpadEngineTests.swift
git commit -m "feat: TrackpadEngine turns drags into relative cursor deltas"
```

---

### Task 3: Discover `_zeusremote._tcp`

**Files:**
- Create: `RemoteCore/Sources/RemoteCore/BrowserCursorDiscovery.swift`
- Modify: `RemoteCore/Sources/RemoteCore/DeviceDiscovery.swift` (add `hostPort(from:)` beside `hostString(from:)`)
- Modify: `project.yml` (add the service type to `NSBonjourServices`)
- Test: `RemoteCore/Tests/RemoteCoreTests/BrowserCursorDiscoveryTests.swift`

**Interfaces:**
- Consumes: `hostString(from:)` and the IPv4-pinned resolve pattern in `DeviceDiscovery.swift`.
- Produces:
  - `func hostPort(from endpoint: NWEndpoint) -> (host: String, port: UInt16)?` (internal, file scope in `DeviceDiscovery.swift`)
  - `public struct BrowserCursorService: Equatable, Sendable { public let name: String; public let host: String; public let port: UInt16 }` with a public memberwise init.
  - `@MainActor @Observable public final class BrowserCursorDiscovery` with `public private(set) var services: [BrowserCursorService]`, `public init()`, `public func start()`, `public func stop()`.

**Critical, easy to miss:** iOS refuses to browse a Bonjour type absent from `NSBonjourServices`. The browse fails *silently* — no error, no results — and the feature simply looks broken. `project.yml` currently lists only `_androidtvremote2._tcp`.

- [ ] **Step 1: Write the failing tests**

`RemoteCore/Tests/RemoteCoreTests/BrowserCursorDiscoveryTests.swift`:

```swift
import Network
import Testing
@testable import RemoteCore

// The port matters here in a way it never did for the remote: the TV browser's
// server advertises its port over Bonjour and it appears in NO source file
// (which is why grepping the APK for 8335 found nothing). Dropping it and
// hardcoding a guess would work today and break silently later.

@Test func hostPortKeepsBothHalves() {
    let endpoint = NWEndpoint.hostPort(host: .ipv4(.init("192.168.0.108")!), port: 8335)
    let resolved = hostPort(from: endpoint)
    #expect(resolved?.host == "192.168.0.108")
    #expect(resolved?.port == 8335)
}

@Test func hostPortStripsTheInterfaceScope() {
    // Same trap as PairedDevice.host: "192.168.0.108%en0" is not connectable.
    let endpoint = NWEndpoint.hostPort(host: .ipv4(.init("192.168.0.108%en0")!), port: 8335)
    #expect(hostPort(from: endpoint)?.host == "192.168.0.108")
}

@Test func hostPortRejectsAnUnresolvedServiceEndpoint() {
    let endpoint = NWEndpoint.service(name: "desktop", type: "_zeusremote._tcp", domain: "local.", interface: nil)
    #expect(hostPort(from: endpoint) == nil)
}

@MainActor
@Test func discoveryStartsEmptyAndSurvivesStopWithoutStart() {
    let discovery = BrowserCursorDiscovery()
    #expect(discovery.services.isEmpty)
    discovery.stop()   // must not crash or assert
    #expect(discovery.services.isEmpty)
}

@Test func servicesCompareByAllThreeFields() {
    let a = BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335)
    let b = BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 9000)
    #expect(a != b)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./Scripts/test.sh --filter BrowserCursorDiscovery`
Expected: FAIL — "cannot find 'hostPort' in scope".

- [ ] **Step 3: Add `hostPort(from:)` to `DeviceDiscovery.swift`**

Insert directly beneath the existing `hostString(from:)`:

```swift
/// Like `hostString(from:)` but keeps the port.
///
/// The remote's port is a constant (6466) so `hostString` throws it away. The
/// TV browser's is NOT: it is advertised in the SRV record and appears nowhere
/// in that app's code, so it must be carried from discovery to connection.
func hostPort(from endpoint: NWEndpoint) -> (host: String, port: UInt16)? {
    guard case .hostPort(_, let port) = endpoint,
          let host = hostString(from: endpoint) else { return nil }
    return (host, port.rawValue)
}
```

- [ ] **Step 4: Write `BrowserCursorDiscovery.swift`**

```swift
import Foundation
import Network
import Observation
import os

/// One TV browser instance offering the cursor protocol.
public struct BrowserCursorService: Equatable, Sendable {
    public let name: String
    public let host: String
    /// Advertised, never assumed — see `hostPort(from:)`.
    public let port: UInt16

    public init(name: String, host: String, port: UInt16) {
        self.name = name
        self.host = host
        self.port = port
    }
}

/// Browses `_zeusremote._tcp` — the Bonjour type the TV browser's embedded
/// server advertises (instance name = the TV's name, e.g. "desktop").
///
/// Structurally a twin of `DeviceDiscovery` and deliberately a SEPARATE type
/// rather than a parameter on it: this one serves a private third-party
/// protocol that can vanish in a browser update, and nothing about the remote's
/// own discovery should have to change when it does.
///
/// Note for anyone adding another Bonjour type later: iOS silently refuses to
/// browse a type that is not listed in `NSBonjourServices` in Info.plist.
/// There is no error — the browse just never reports anything.
@MainActor
@Observable
public final class BrowserCursorDiscovery {
    public private(set) var services: [BrowserCursorService] = []

    private var browser: NWBrowser?
    // Same generation guard as DeviceDiscovery: a slow resolve pass must not
    // overwrite `services` after a newer pass or a stop() superseded it.
    private var resolveGeneration = 0
    private var activeResolveTasks: [Task<Void, Never>] = []

    public init() {}

    public func start() {
        stop()
        let browser = NWBrowser(for: .bonjour(type: "_zeusremote._tcp", domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints: [(name: String, endpoint: NWEndpoint)] = results.compactMap {
                guard case .service(let name, _, _, _) = $0.endpoint else { return nil }
                return (name, $0.endpoint)
            }
            Task { @MainActor [weak self] in self?.spawnResolve(endpoints) }
        }
        browser.start(queue: .global(qos: .userInitiated))
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        resolveGeneration += 1
        for task in activeResolveTasks { task.cancel() }
        activeResolveTasks.removeAll()
        services = []
    }

    private func spawnResolve(_ found: [(name: String, endpoint: NWEndpoint)]) {
        resolveGeneration += 1
        let generation = resolveGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.resolveAll(found, generation: generation)
        }
        activeResolveTasks.append(task)
    }

    private func resolveAll(_ found: [(name: String, endpoint: NWEndpoint)], generation: Int) async {
        var resolved: [BrowserCursorService] = []
        for entry in found {
            if let endpoint = await Self.resolve(endpoint: entry.endpoint) {
                resolved.append(
                    BrowserCursorService(name: entry.name, host: endpoint.host, port: endpoint.port)
                )
            }
        }
        guard generation == resolveGeneration else { return }
        services = resolved.sorted { $0.name < $1.name }
    }

    /// IPv4-pinned for the same reason as `DeviceDiscovery`: resolving on a
    /// real LAN otherwise yields a link-local IPv6 address whose scope is
    /// stripped, leaving something nothing can connect to.
    private static var resolveParameters: NWParameters {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        return parameters
    }

    private static func resolve(endpoint: NWEndpoint) async -> (host: String, port: UInt16)? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: resolveParameters)
            // Guard against double-resume: the state handler can fire repeatedly.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ value: (host: String, port: UInt16)?) {
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let inner = connection.currentPath?.remoteEndpoint {
                        finish(hostPort(from: inner))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
    }
}
```

- [ ] **Step 5: Whitelist the service type**

In `project.yml`, change the `NSBonjourServices` line to:

```yaml
        NSBonjourServices: [_androidtvremote2._tcp, _zeusremote._tcp]
```

Then run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate`

- [ ] **Step 6: Run the tests**

Run: `./Scripts/test.sh`
Expected: PASS — 152 tests.

- [ ] **Step 7: Verify the browse against the real TV**

The TV browser must be open. Run:

```bash
dns-sd -B _zeusremote._tcp local.
```

Expected: an `Add` row naming the TV (e.g. `desktop`). If nothing appears, the browser app is not running — that is the fallback case, not a bug.

- [ ] **Step 8: Commit**

```bash
git add RemoteCore/Sources/RemoteCore/BrowserCursorDiscovery.swift RemoteCore/Sources/RemoteCore/DeviceDiscovery.swift RemoteCore/Tests/RemoteCoreTests/BrowserCursorDiscoveryTests.swift project.yml
git commit -m "feat: discover the TV browser's cursor service over Bonjour"
```

---

### Task 4: `BrowserCursorClient` — lifecycle and sending

**Files:**
- Create: `RemoteCore/Sources/RemoteCore/BrowserCursorClient.swift`
- Create: `RemoteCore/Sources/RemoteCore/MockBrowserCursorClient.swift`
- Test: `RemoteCore/Tests/RemoteCoreTests/BrowserCursorClientTests.swift`

**Interfaces:**
- Consumes: `CursorMessages`, `BrowserCursorDiscovery`, `BrowserCursorService`.
- Produces:
  - `@MainActor public protocol BrowserCursorControlling: AnyObject { var isAvailable: Bool { get }; func move(dx: Float, dy: Float); func click() }`
  - `@MainActor protocol CursorSocketing: AnyObject { var onOpen: (() -> Void)? { get set }; var onClose: (() -> Void)? { get set }; func connect(host: String, port: UInt16); func send(_ data: Data); func disconnect() }` (internal)
  - `@MainActor @Observable public final class BrowserCursorClient: BrowserCursorControlling` with `public init(discovery: BrowserCursorDiscovery = BrowserCursorDiscovery(), makeSocket: @escaping @MainActor () -> CursorSocketing = { WebSocketCursorSocket() })`, `public func start(matchingHost: String)`, `public func stop()`, plus internal `connect(to:)` and `considerServices(_:)` for tests.
  - `@MainActor @Observable public final class MockBrowserCursorClient: BrowserCursorControlling` with `public enum CursorEvent: Equatable, Sendable { case move(dx: Float, dy: Float); case click }`, `public private(set) var events: [CursorEvent]`, `public func setAvailable(_:)`.

**Design note for the implementer:** `isAvailable` must flip true on the socket's **open** callback, never when `connect` is called. `URLSessionWebSocketTask.resume()` returns immediately, and a task pointed at a dead host looks identical to a live one until the handshake completes. Reporting availability early would show the user "Free cursor" while every drag went nowhere.

Note the default argument `makeSocket: { WebSocketCursorSocket() }` references an internal type from a public initializer. Keep the initializer public but give the parameter an internal default by providing two inits if the compiler objects — a public `init()` / `init(matchingHostProvider:)` and an internal designated one taking `makeSocket`.

- [ ] **Step 1: Write the failing tests**

`RemoteCore/Tests/RemoteCoreTests/BrowserCursorClientTests.swift`:

```swift
import Foundation
import Testing
@testable import RemoteCore

@MainActor
private final class FakeSocket: CursorSocketing {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var connectedTo: (host: String, port: UInt16)?
    private(set) var sent: [Data] = []
    private(set) var disconnectCount = 0

    func connect(host: String, port: UInt16) { connectedTo = (host, port) }
    func send(_ data: Data) { sent.append(data) }
    func disconnect() { disconnectCount += 1 }

    func open() { onOpen?() }
    func drop() { onClose?() }
}

@MainActor
@Test func clientIsUnavailableUntilTheSocketActuallyOpens() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    // resume() returns instantly and a dead host looks live until the
    // handshake lands — claiming availability here would show "Free cursor"
    // while every drag went nowhere.
    #expect(client.isAvailable == false)
    socket.open()
    #expect(client.isAvailable)
}

@MainActor
@Test func movesAreDroppedWhileUnavailable() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.move(dx: 5, dy: 5)
    client.click()
    #expect(socket.sent.isEmpty)
}

@MainActor
@Test func moveAndClickSendTheVerifiedBytes() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket.open()
    client.move(dx: -6, dy: -4)
    client.click()
    #expect(socket.sent == [CursorMessages.move(dx: -6, dy: -4), CursorMessages.click()])
}

@MainActor
@Test func aDroppedSocketGoesUnavailableAndStopsSending() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket.open()
    socket.drop()
    #expect(client.isAvailable == false)
    client.move(dx: 1, dy: 1)
    #expect(socket.sent.isEmpty)
}

@MainActor
@Test func onlyTheMatchingHostIsConnected() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.start(matchingHost: "192.168.0.108")
    // A second TV on the LAN advertising the same service must never receive
    // this phone's cursor.
    client.considerServices([BrowserCursorService(name: "other", host: "192.168.0.55", port: 8335)])
    #expect(socket.connectedTo == nil)
    client.considerServices([BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335)])
    #expect(socket.connectedTo?.host == "192.168.0.108")
    #expect(socket.connectedTo?.port == 8335)
}

@MainActor
@Test func stopClosesTheSocketAndReportsUnavailable() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket.open()
    client.stop()
    #expect(socket.disconnectCount == 1)
    #expect(client.isAvailable == false)
}

@MainActor
@Test func mockRecordsAnOrderedEventLog() {
    let mock = MockBrowserCursorClient()
    mock.setAvailable(true)
    mock.move(dx: 3, dy: -2)
    mock.click()
    #expect(mock.events == [.move(dx: 3, dy: -2), .click])
}

@MainActor
@Test func mockDropsEventsWhileUnavailableJustLikeTheRealClient() {
    // Mock honesty (the Phase 2 lesson): a mock that recorded events while
    // unavailable would let a UI test prove a send that never happens.
    let mock = MockBrowserCursorClient()
    mock.move(dx: 3, dy: -2)
    #expect(mock.events.isEmpty)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./Scripts/test.sh --filter BrowserCursorClient`
Expected: FAIL — types not found.

- [ ] **Step 3: Write `BrowserCursorClient.swift`**

```swift
import Foundation
import Observation

/// What the UI needs from a cursor transport. A seam, so `PointerView` can be
/// driven by a mock and the real client's socket faked in tests.
@MainActor
public protocol BrowserCursorControlling: AnyObject {
    /// True only while a WebSocket is genuinely open. Drives the UI indicator
    /// AND the choice of input mechanism, so it must never be optimistic.
    var isAvailable: Bool { get }
    func move(dx: Float, dy: Float)
    func click()
}

/// The socket, abstracted so the client's matching and gating logic is
/// testable without a TV. Only the conforming WebSocket needs hardware.
@MainActor
protocol CursorSocketing: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    func connect(host: String, port: UInt16)
    func send(_ data: Data)
    func disconnect()
}

/// Talks the TV browser's private cursor protocol.
///
/// Deliberately NOT part of `TVController`. That protocol is the app's stable
/// remote; this one is a third-party, undocumented channel that a browser
/// update can break without warning. Keeping them apart means such a break
/// costs one file and degrades Pointer mode to its key glide, rather than
/// destabilising the remote.
@MainActor
@Observable
public final class BrowserCursorClient: BrowserCursorControlling {
    public private(set) var isAvailable = false

    private let discovery: BrowserCursorDiscovery
    private let makeSocket: @MainActor () -> CursorSocketing
    private var socket: CursorSocketing?
    private var targetHost: String?
    private var observation: Task<Void, Never>?

    public convenience init(discovery: BrowserCursorDiscovery = BrowserCursorDiscovery()) {
        self.init(discovery: discovery, makeSocket: { WebSocketCursorSocket() })
    }

    init(
        discovery: BrowserCursorDiscovery = BrowserCursorDiscovery(),
        makeSocket: @escaping @MainActor () -> CursorSocketing
    ) {
        self.discovery = discovery
        self.makeSocket = makeSocket
    }

    /// Begin looking for the cursor service on `matchingHost` — the TV we are
    /// actually paired to, and only that one.
    public func start(matchingHost: String) {
        stop()
        targetHost = matchingHost
        discovery.start()
        observation = Task { @MainActor [weak self] in
            // Poll rather than observe: `services` is @Observable, but a
            // withObservationTracking loop would need re-arming on every
            // change and this runs twice a second at most. The same loop
            // provides the reconnect — a dropped socket is picked up on the
            // next tick while the service is still advertised.
            while !Task.isCancelled {
                guard let self else { return }
                self.considerServices(self.discovery.services)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    public func stop() {
        observation?.cancel()
        observation = nil
        discovery.stop()
        targetHost = nil
        closeSocket()
    }

    /// Connect if one of `services` is our TV and we are not already up.
    /// Internal rather than private so the host-matching rule — the one that
    /// keeps this phone's cursor off a neighbour's TV — is directly testable.
    func considerServices(_ services: [BrowserCursorService]) {
        guard socket == nil, let targetHost else { return }
        guard let match = services.first(where: { $0.host == targetHost }) else { return }
        connect(to: match)
    }

    func connect(to service: BrowserCursorService) {
        closeSocket()
        let socket = makeSocket()
        self.socket = socket
        socket.onOpen = { [weak self, weak socket] in
            guard let self, let socket, self.socket === socket else { return }
            self.isAvailable = true
        }
        socket.onClose = { [weak self, weak socket] in
            guard let self, let socket, self.socket === socket else { return }
            self.isAvailable = false
            self.socket = nil
        }
        socket.connect(host: service.host, port: service.port)
    }

    public func move(dx: Float, dy: Float) {
        send(CursorMessages.move(dx: dx, dy: dy))
    }

    public func click() {
        send(CursorMessages.click())
    }

    /// No pacing floor here. The 80ms gate belongs to Remote v2, where
    /// back-to-back key events close the control session; this socket took
    /// 20ms intervals without complaint during the spike. Copying the gate
    /// across would make the cursor stutter for no reason.
    private func send(_ data: Data) {
        guard isAvailable, let socket else { return }
        socket.send(data)
    }

    private func closeSocket() {
        guard let socket else { return }
        socket.onOpen = nil
        socket.onClose = nil
        socket.disconnect()
        self.socket = nil
        isAvailable = false
    }
}
```

- [ ] **Step 4: Add the production socket to the same file**

```swift
/// `URLSessionWebSocketTask` behind `CursorSocketing`.
///
/// Two things this must do that are easy to omit:
/// - keep a `receive()` call outstanding at all times, or a close frame is
///   never noticed and the client believes a dead socket is alive;
/// - report open from the delegate callback, not from `resume()`, which
///   returns before the handshake and cannot tell a live host from a dead one.
@MainActor
final class WebSocketCursorSocket: NSObject, CursorSocketing {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    func connect(host: String, port: UInt16) {
        guard let url = URL(string: "ws://\(host):\(port)/ws") else { return }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        listen()
    }

    func send(_ data: Data) {
        task?.send(.data(data)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in self?.fail() }
        }
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func listen() {
        task?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    // The server pushes state messages we do not consume; the
                    // point of receiving is to notice the close.
                    self.listen()
                case .failure:
                    self.fail()
                }
            }
        }
    }

    private func fail() {
        guard task != nil else { return }
        task = nil
        session?.invalidateAndCancel()
        session = nil
        onClose?()
    }
}

extension WebSocketCursorSocket: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor [weak self] in self?.onOpen?() }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor [weak self] in self?.fail() }
    }
}
```

- [ ] **Step 5: Write `MockBrowserCursorClient.swift`**

```swift
import Observation

/// Preview and test stand-in. Records an ORDERED log, because the invariants
/// worth testing are orderings — a click after its motion, nothing sent while
/// unavailable.
@MainActor
@Observable
public final class MockBrowserCursorClient: BrowserCursorControlling {
    public enum CursorEvent: Equatable, Sendable {
        case move(dx: Float, dy: Float)
        case click
    }

    public private(set) var isAvailable = false
    public private(set) var events: [CursorEvent] = []

    public init(isAvailable: Bool = false) {
        self.isAvailable = isAvailable
    }

    public func setAvailable(_ available: Bool) {
        isAvailable = available
    }

    /// Mock honesty (the Phase 2 lesson): the real client drops everything
    /// while unavailable, so this one must too. A mock that recorded them
    /// would let a UI test prove a send that never happens.
    public func move(dx: Float, dy: Float) {
        guard isAvailable else { return }
        events.append(.move(dx: dx, dy: dy))
    }

    public func click() {
        guard isAvailable else { return }
        events.append(.click)
    }
}
```

- [ ] **Step 6: Run the tests**

Run: `./Scripts/test.sh`
Expected: PASS — 160 tests.

- [ ] **Step 7: Commit**

```bash
git add RemoteCore/Sources/RemoteCore/BrowserCursorClient.swift RemoteCore/Sources/RemoteCore/MockBrowserCursorClient.swift RemoteCore/Tests/RemoteCoreTests/BrowserCursorClientTests.swift
git commit -m "feat: BrowserCursorClient — WebSocket transport for the TV browser cursor"
```

---

### Task 5: Wire it into Pointer mode

**Files:**
- Modify: `App/PointerView.swift`
- Modify: `App/RemoteView.swift`
- Modify: `App/RemoteControlApp.swift`

**Interfaces:**
- Consumes: `BrowserCursorControlling`, `TrackpadEngine`, `PointerEngine`, `BrowserCursorClient`.
- Produces: no new public API — this is the UI seam.

**Behaviour to preserve exactly:** every release path in `PointerView` today (`onEnded`, `onDisappear`) and `RemoteView`'s keyboard-sheet release. They exist because a leaked held key leaves the TV scrolling with nothing on screen to stop it. Adding a second mechanism must not weaken any of them.

- [ ] **Step 1: Rewrite `App/PointerView.swift`**

```swift
import RemoteCore
import SwiftUI

/// Pointer mode: two mechanisms, one surface.
///
/// When the TV browser's cursor service is reachable, a drag sends real 2D
/// deltas over that protocol — any direction, any curve — and a tap clicks.
/// Otherwise it falls back to the only thing Android TV Remote v2 can do: HOLD
/// a direction key and let the TV's auto-repeat glide the cursor four ways.
///
/// The two must never run at once. Every path that leaves the glide releases
/// the held key first; `hold(nil)` is idempotent, so releasing defensively
/// costs nothing.
struct PointerView: View {
    let press: (KeyCommand) -> Void
    /// `TVController.setHeldDirection` — nil releases whatever is held.
    let hold: (KeyCommand?) -> Void
    let cursor: any BrowserCursorControlling

    @State private var engine = PointerEngine()
    @State private var trackpad = TrackpadEngine()
    @State private var epoch = ContinuousClock.now

    private var realCursor: Bool { cursor.isAvailable }

    var body: some View {
        RoundedRectangle(cornerRadius: 26)
            .fill(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 26)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            )
            .overlay(caption)
            .frame(height: 244)
            .contentShape(RoundedRectangle(cornerRadius: 26))
            .accessibilityLabel(realCursor
                ? "Trackpad — drag to move the cursor freely, tap to click"
                : "Pointer surface — glide to move the cursor, tap to select")
            .gesture(realCursor ? nil : glideGesture)
            .gesture(realCursor ? trackpadGesture : nil)
            .onChange(of: realCursor) { _, nowReal in
                // Switching mechanism mid-drag must strand neither: the glide's
                // key would stay down with no view left holding it, and the
                // trackpad would resume from a stale finger position.
                engine.cancel()
                trackpad.cancel()
                if nowReal { hold(nil) }
            }
            .onDisappear {
                engine.cancel()
                trackpad.cancel()
                hold(nil)
            }
    }

    private var caption: some View {
        VStack(spacing: 10) {
            Image(systemName: realCursor ? "cursorarrow" : "cursorarrow.motionlines")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(realCursor ? Theme.accent : Theme.chevron)
            Text(realCursor ? "Drag to move" : "Glide to move")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(realCursor ? "Free cursor · tap to click" : "Tap to select")
                .font(.system(size: 12))
                .foregroundStyle(realCursor ? Theme.accent.opacity(0.8) : Theme.chevron)
        }
    }

    /// The fallback: hold one direction, let the TV auto-repeat.
    private var glideGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                hold(engine.moved(to: value.location, now: epoch.duration(to: .now)))
            }
            .onEnded { value in
                // Release FIRST and unconditionally — before the tap check,
                // before anything that could take an early return.
                hold(nil)
                if let key = engine.ended(at: value.location, now: epoch.duration(to: .now)) {
                    press(key)
                }
            }
    }

    /// The real thing: relative deltas straight to the browser.
    private var trackpadGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if let delta = trackpad.moved(to: value.location, now: epoch.duration(to: .now)) {
                    cursor.move(dx: Float(delta.dx), dy: Float(delta.dy))
                }
            }
            .onEnded { value in
                let release = trackpad.ended(at: value.location, now: epoch.duration(to: .now))
                if let flush = release.flush {
                    cursor.move(dx: Float(flush.dx), dy: Float(flush.dy))
                }
                if release.isTap {
                    Haptics.tap()
                    cursor.click()
                }
            }
    }
}
```

- [ ] **Step 2: Pass the client through `App/RemoteView.swift`**

Add the stored property beside the others:

```swift
    let cursor: any BrowserCursorControlling
```

Change the pointer case in `body`:

```swift
                case .pointer: PointerView(press: press, hold: hold, cursor: cursor)
```

Add the indicator inside `header`'s inner `VStack`, directly after the connection-dot `HStack`:

```swift
                if cursor.isAvailable {
                    HStack(spacing: 5) {
                        Image(systemName: "cursorarrow")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Free cursor")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Theme.accent)
                }
```

- [ ] **Step 3: Own the client in `App/RemoteControlApp.swift`**

In `RemoteControlApp`, beside the controller:

```swift
    @State private var cursor = BrowserCursorClient()
```

and pass it down: `RootView(controller: controller, store: store, cursor: cursor)`.

In `RootView`, add `let cursor: BrowserCursorClient`, hand it to `RemoteView(controller: controller, device: device, cursor: cursor)`, and tie its lifetime to the paired device:

- in `.onAppear`, after `pairedDevice = store.pairedDevice`:
  ```swift
            if let device = pairedDevice { cursor.start(matchingHost: device.host) }
  ```
- in the unpair closure, beside `controller.disconnect()`: `cursor.stop()`
- in the pairing-success closure, after `pairedDevice = device`: `cursor.start(matchingHost: device.host)`
- in `.task`, alongside the existing connect: `cursor.start(matchingHost: device.host)`
- in the `scenePhase` handler:
  ```swift
            case .background:
                controller.disconnect()
                // iOS kills LAN sockets in the background, and the browse would
                // keep the radio busy for a cursor nobody can see.
                cursor.stop()
            case .active:
                if let device = pairedDevice, controller.connectionState == .disconnected {
                    Task { try? await controller.connect(to: device) }
                }
                if let device = pairedDevice { cursor.start(matchingHost: device.host) }
  ```

- [ ] **Step 4: Build for the simulator**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project RemoteControl.xcodeproj -scheme RemoteControl \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/rc-build build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run the whole suite**

Run: `./Scripts/test.sh`
Expected: PASS — 160 tests, unchanged (this task is UI wiring).

- [ ] **Step 6: Commit**

```bash
git add App/PointerView.swift App/RemoteView.swift App/RemoteControlApp.swift
git commit -m "feat: Pointer mode upgrades to the real cursor when the browser is up"
```

---

### Task 6: Hardware verification

**Files:**
- Modify: `docs/tvbrowser-remote-protocol.md` (record results)
- Modify: `docs/HANDOFF.md` (state, next steps)

No code. This task exists because **three of this project's bugs were invisible to a fully green suite and appeared only at the TV**. A passing suite is not evidence on protocol work.

Prerequisites: TV on, browser open on a loaded page so the cursor is visible, app running in the simulator, `adb connect 192.168.0.108:5555`.

Cursor position is machine-checkable — the cursor appears in `screencap` output, so nobody has to watch the screen:

```bash
adb shell screencap -p /sdcard/s.png && adb pull /sdcard/s.png /tmp/tv.png
```

- [ ] **Step 1: Availability** — with the browser open, the header shows "Free cursor" and the pad reads "Drag to move". Press Home on the TV; within ~2s the indicator disappears and the pad reverts to "Glide to move".
- [ ] **Step 2: Free movement** — drag a slow circle. The cursor must follow the curve, not step between four directions. This is the whole feature; if it fails, stop and diagnose.
- [ ] **Step 3: Direction** — drag down-right; the cursor goes down-right. An axis inversion is a one-character fix but invisible in code review.
- [ ] **Step 4: Click** — put the cursor over a link and tap. The page navigates.
- [ ] **Step 5: No accidental clicks** — drag across a page of links and release. Nothing must navigate.
- [ ] **Step 6: Sensitivity** — judge whether one comfortable swipe crosses a useful distance. If not, change `TrackpadEngine`'s default and record the measured value. Do not leave a guess in place once a measurement is available.
- [ ] **Step 7: No leaked hold** — hold a D-pad arrow, switch to Pointer mode mid-hold, confirm the TV stops scrolling. Then, with the browser open, confirm no glide happens while the real cursor is active.
- [ ] **Step 8: Fallback under loss** — with a drag in progress, close the browser on the TV. The app must fall back without freezing and without sending into a dead socket.
- [ ] **Step 9: Background and return** — background the app mid-session, return, confirm the cursor reconnects and the indicator comes back.
- [ ] **Step 10: Record the results**

Update `docs/tvbrowser-remote-protocol.md` with the measured sensitivity and anything that behaved differently from the spike. Update `docs/HANDOFF.md`: state, test count, what is verified and what is not.

```bash
git add docs/tvbrowser-remote-protocol.md docs/HANDOFF.md
git commit -m "docs: hardware verification of the browser cursor"
```

---

## Self-review

**Spec coverage.** Scope (cursor + click only) → Task 1. Trackpad-relative gesture → Task 2. Discovery including the advertised port → Task 3. Availability, host matching, fallback, no pacing floor → Task 4. One self-upgrading Pointer mode with a visible indicator and held-key exclusion → Task 5. Hardware gate → Task 6. `TVController` untouched throughout, as the spec requires.

**Type consistency.** `BrowserCursorControlling` is the name used in Tasks 4 and 5. `BrowserCursorService(name:host:port:)` is identical in Tasks 3 and 4. `TrackpadRelease.flush` / `.isTap` match between Task 2's implementation and Task 5's call site. `CursorMessages.move(dx:dy:)` / `click()` match between Tasks 1 and 4. `hostPort(from:)` is defined in Task 3 Step 3 and used in Task 3 Step 4.

**Known gaps, stated rather than hidden.**
- The 2.0 sensitivity default is reasoned, not measured — Task 6 Step 6 exists to replace it with a measurement.
- `WebSocketCursorSocket` is exercised only against the real TV. Its logic is deliberately thin; everything above it is faked in tests.
- The reconnect described in the spec falls out of the 500ms `considerServices` poll rather than a dedicated timer — simpler, same observable behaviour, slightly less prompt.
- The spec mentions a WebSocket-level keepalive ping. It is omitted here: the `receive()` loop already surfaces a close, and an unnecessary timer is one more thing to leak. If the TV proves to drop idle sockets, add it then.
