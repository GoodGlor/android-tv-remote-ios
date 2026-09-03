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
/// The app once had a second, key-based mechanism (`PointerEngine`) that
/// answered "which single direction should be HELD right now" for a 4-way
/// device. It was deleted with the glide fallback: Pointer mode now appears
/// only when this real cursor is live, so there is nothing left for a 4-way
/// approximation to do.
///
/// Pure and clock-injectable — `now` is passed in, so the coalescing rule is
/// unit-testable with no TV and no wall-clock waiting.
public struct TrackpadEngine: Sendable {
    /// Phone points to TV pixels, MEASURED on hardware (2026-08-23, TV
    /// `desktop` 1280x720, iPhone 17 Pro 402pt wide; `Scripts/cursor-calibrate.py`):
    ///
    /// - The TV applies deltas **exactly 1:1** — 100/200/300 units moved
    ///   100/200/300px, ratio 1.000 every time. No acceleration of its own,
    ///   so this constant alone decides the feel.
    /// - The pad is 354pt wide (402 screen - 2x24 padding) and 244pt tall.
    /// - At 3.0 a full-width swipe covers 1062px, 83% of the screen, and a
    ///   full-height swipe covers 732px against a 720px screen — vertically
    ///   almost exactly one screen per swipe.
    ///
    /// Tuned on hardware with the user: 2.0 was too slow (~1.8 swipes to
    /// cross), 3.6 (= 1280/354, one swipe across) was a little fast. 3.0 sits
    /// between them and happens to make the SHORT axis the one that maps 1:1,
    /// which is the better axis to get right — the pad is 354 wide but only
    /// 244 tall, and one sensitivity serves both, so vertical is always the
    /// axis that runs out of pad first.
    /// Readable so tests and calibration can derive from it rather than
    /// repeating its value, the way `SwipePadEngine.stepDistance` is.
    public let sensitivity: CGFloat
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
        sensitivity: CGFloat = 3.0,
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
        // Withhold until the tap threshold is crossed: sending before then
        // would nudge the cursor on a resting finger's jitter and let a tap
        // land somewhere it never visually touched. Motion is already banked
        // in `pending`, so the first send past the threshold flushes it all —
        // nothing is lost, only delayed.
        guard travel >= tapDistance else { return nil }
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
