import CoreGraphics

/// Turns a drag into discrete focus steps — the Apple TV touch surface.
///
/// This is the THIRD navigation surface and the only one that works
/// everywhere, so the distinction matters:
///
/// | surface | sends | works |
/// |---|---|---|
/// | D-pad buttons | a HELD arrow, TV auto-repeats | everywhere |
/// | swipe pad (this) | one arrow per swipe threshold | everywhere |
/// | `TrackpadEngine` | free 2D cursor deltas | TV browser only |
///
/// A near-identical "Touchpad mode" was deleted in `d27ce86` because one
/// swipe = one step "could not move the cursor at all". That verdict was
/// about driving the TV BROWSER'S CURSOR, which only glides while a key is
/// auto-repeating and barely twitches on a discrete press. Moving FOCUS
/// between tiles is the opposite problem: one press moves exactly one tile,
/// which is what a step should do. The old finding still holds inside the
/// browser — use the real cursor there.
///
/// `multiStep` decides how far one touch can carry:
///
/// - `false` (the shipped default) — ONE step per touch, however far the
///   finger travels. Swipe, lift, swipe again. This is the default because
///   distance-proportional stepping overshoots badly in practice: a natural
///   swipe across the pad crosses several thresholds and jumps several
///   tiles, which is not what "move one across" should do.
/// - `true` — one step per threshold crossed, so a long drag keeps moving.
///   Surfaced in Settings as "Acceleration". Steps still follow DISTANCE and
///   never speed: three thresholds is three steps whether the finger was
///   fast or slow.
///
/// Pure and free of any clock — unlike `TrackpadEngine`, nothing here is
/// paced or coalesced, so the whole rule is testable from geometry alone.
public struct SwipePadEngine: Sendable {
    public enum Step: Equatable, Sendable { case up, down, left, right }

    /// Travel that makes one step. 24pt: 44 was the first guess and felt like
    /// a long drag before anything happened (user, 2026-08-23). Kept well
    /// clear of `tapDistance` (12) so a tap can never be mistaken for a swipe
    /// — that margin is the real floor on how small this can go.
    public let stepDistance: CGFloat
    /// Total path below which a touch is a tap, not a swipe. Matches
    /// `TrackpadEngine.tapDistance` so both pads treat a still finger alike.
    public let tapDistance: CGFloat

    /// Whether one touch may produce more than one step. See the type
    /// comment — this is the Settings "Acceleration" switch.
    public let multiStep: Bool

    /// Safety valve for a single update that jumps many thresholds — a
    /// dropped frame, or a fling. Without it one update could enqueue dozens
    /// of key events and the TV would run away from the user long after the
    /// finger stopped. Steps beyond this are dropped, not deferred.
    private static let maxStepsPerUpdate = 4

    /// Where the next step is measured from. Advances by exactly one
    /// `stepDistance` per step rather than snapping to the finger, so a slow
    /// continuous drag keeps emitting evenly instead of drifting.
    private var anchor: CGPoint = .zero
    private var previous: CGPoint = .zero
    /// Path length, not displacement: a finger that wanders and returns has
    /// not been still, and must not count as a tap.
    private var travel: CGFloat = 0
    private var stepped = false

    public init(stepDistance: CGFloat = 24, tapDistance: CGFloat = 12, multiStep: Bool = false) {
        self.stepDistance = stepDistance
        self.tapDistance = tapDistance
        self.multiStep = multiStep
    }

    public mutating func began(at point: CGPoint) {
        anchor = point
        previous = point
        travel = 0
        stepped = false
    }

    /// The steps this movement crossed, in order. Usually empty or one.
    public mutating func moved(to point: CGPoint) -> [Step] {
        travel += hypot(point.x - previous.x, point.y - previous.y)
        previous = point

        // One-step mode is spent as soon as it fires: the rest of the drag,
        // and the finger settling before lift-off, must stay silent.
        guard multiStep || !stepped else { return [] }

        let cap = multiStep ? Self.maxStepsPerUpdate : 1
        var steps: [Step] = []
        while steps.count < cap {
            let dx = point.x - anchor.x
            let dy = point.y - anchor.y
            // Dominant axis wins, so a sloppy diagonal does not fire both at
            // once. A tie goes to horizontal — arbitrary, but fixed, because
            // an unstable tie-break would make a 45° drag stutter between axes.
            if abs(dx) >= abs(dy), abs(dx) >= stepDistance {
                steps.append(dx > 0 ? .right : .left)
                anchor.x += dx > 0 ? stepDistance : -stepDistance
            } else if abs(dy) > abs(dx), abs(dy) >= stepDistance {
                steps.append(dy > 0 ? .down : .up)
                anchor.y += dy > 0 ? stepDistance : -stepDistance
            } else {
                break
            }
        }
        if !steps.isEmpty { stepped = true }
        return steps
    }

    /// True when the touch was a tap — short, and it never stepped. Both
    /// halves are load-bearing: a drag that crossed a threshold and returned
    /// to where it started has a small displacement but is not a tap.
    ///
    /// Non-mutating: `began(at:)` owns the reset, so asking twice is safe.
    public func ended() -> Bool {
        !stepped && travel < tapDistance
    }
}
