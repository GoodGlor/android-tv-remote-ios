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
