import CoreGraphics
import Testing
@testable import RemoteCore

// Every distance below is expressed in multiples of `step` rather than in
// literal points, so the threshold can be retuned — it has been once already,
// 44 -> 24 — without rewriting the suite. Only the tap tests use literals,
// because they are about the tap threshold, not this one.
private let step = SwipePadEngine().stepDistance
private func engine() -> SwipePadEngine { SwipePadEngine() }
/// The "Acceleration" setting on — one step per threshold crossed.
private func accelerating() -> SwipePadEngine { SwipePadEngine(multiStep: true) }

// MARK: One swipe, one step

@Test func aSwipePastTheThresholdEmitsOneStep() {
    var pad = engine()
    pad.began(at: .zero)
    #expect(pad.moved(to: CGPoint(x: step, y: 0)) == [.right])
}

@Test func movementBelowTheThresholdEmitsNothing() {
    var pad = engine()
    pad.began(at: .zero)
    #expect(pad.moved(to: CGPoint(x: step - 1, y: 0)).isEmpty)
}

@Test func eachDirectionMapsToItsOwnStep() {
    for (point, expected) in [(CGPoint(x: step, y: 0), SwipePadEngine.Step.right),
                              (CGPoint(x: -step, y: 0), .left),
                              (CGPoint(x: 0, y: step), .down),
                              (CGPoint(x: 0, y: -step), .up)] {
        var pad = engine()
        pad.began(at: .zero)
        #expect(pad.moved(to: point) == [expected])
    }
}

// MARK: One step per touch — the shipped default

@Test func aLongDragEmitsOnlyOneStepByDefault() {
    var pad = engine()
    pad.began(at: .zero)
    // Three thresholds of travel, but the default is one step per touch:
    // distance-proportional stepping overshot by several tiles per swipe,
    // which is what made the pad feel like it skipped icons.
    #expect(pad.moved(to: CGPoint(x: step * 3, y: 0)) == [.right])
}

@Test func afterItsOneStepATouchStaysSilent() {
    var pad = engine()
    pad.began(at: .zero)
    #expect(pad.moved(to: CGPoint(x: step, y: 0)) == [.right])
    // The rest of the drag, including the finger settling before lift-off,
    // must add nothing.
    #expect(pad.moved(to: CGPoint(x: step * 8, y: 0)).isEmpty)
    #expect(pad.moved(to: CGPoint(x: step * 8, y: step * 5)).isEmpty)
}

@Test func aNewTouchStepsAgainAfterAOneStepTouch() {
    var pad = engine()
    pad.began(at: .zero)
    _ = pad.moved(to: CGPoint(x: step, y: 0))
    // Swipe, lift, swipe again is the whole interaction in this mode.
    pad.began(at: .zero)
    #expect(pad.moved(to: CGPoint(x: step, y: 0)) == [.right])
}

// MARK: Acceleration on — distance, never speed

@Test func aLongDragEmitsOneStepPerThresholdCrossed() {
    var pad = accelerating()
    pad.began(at: .zero)
    // Three thresholds in ONE update. Distance decides, so all three land
    // regardless of how fast the finger got there.
    #expect(pad.moved(to: CGPoint(x: step * 3, y: 0)) == [.right, .right, .right])
}

@Test func aSlowDragEmitsTheSameStepsAsAFastOne() {
    var slow = accelerating()
    slow.began(at: .zero)
    var collected: [SwipePadEngine.Step] = []
    // The same three thresholds, delivered in 12 small updates instead of one.
    for tick in 1...12 {
        collected += slow.moved(to: CGPoint(x: step * 3 * CGFloat(tick) / 12, y: 0))
    }

    var fast = accelerating()
    fast.began(at: .zero)
    let inOneGo = fast.moved(to: CGPoint(x: step * 3, y: 0))

    #expect(collected == inOneGo)
    #expect(collected == [.right, .right, .right])
}

@Test func theAnchorAdvancesByOneStepNotToTheFinger() {
    var pad = accelerating()
    pad.began(at: .zero)
    #expect(pad.moved(to: CGPoint(x: step, y: 0)) == [.right])
    // Another whole threshold is another step. If the anchor had snapped to
    // the finger this would still work, but a HALF step further would not —
    // see the next test.
    #expect(pad.moved(to: CGPoint(x: step * 2, y: 0)) == [.right])
}

@Test func partialTravelCarriesForwardRatherThanBeingLost() {
    var pad = accelerating()
    pad.began(at: .zero)
    _ = pad.moved(to: CGPoint(x: step * 1.5, y: 0))   // one step; half banked
    // The banked half plus another half is exactly one more threshold.
    #expect(pad.moved(to: CGPoint(x: step * 2, y: 0)) == [.right])
}

// MARK: Axis locking

@Test func aSloppyDiagonalFiresOnlyTheDominantAxis() {
    var pad = engine()
    pad.began(at: .zero)
    // A full threshold across, a fraction of one down: a horizontal swipe
    // with a wobble.
    #expect(pad.moved(to: CGPoint(x: step, y: step * 0.4)) == [.right])
}

@Test func aTieGoesToHorizontalDeterministically() {
    var pad = engine()
    pad.began(at: .zero)
    // A perfect 45° drag must not stutter between axes; the rule is fixed.
    #expect(pad.moved(to: CGPoint(x: step, y: step)).first == .right)
}

@Test func anLShapedDragStepsOnBothAxesInOrder() {
    var pad = accelerating()
    pad.began(at: .zero)
    #expect(pad.moved(to: CGPoint(x: step, y: 0)) == [.right])
    // Direction change mid-touch is honoured — the axis is re-evaluated per
    // step rather than locked for the whole gesture.
    #expect(pad.moved(to: CGPoint(x: step, y: step)) == [.down])
}

// MARK: Runaway protection

@Test func oneUpdateCannotEnqueueUnboundedSteps() {
    var pad = accelerating()
    pad.began(at: .zero)
    // Forty thresholds in a single update — a dropped frame, or a fling.
    // Without the cap the TV would keep moving long after the finger stopped.
    #expect(pad.moved(to: CGPoint(x: step * 40, y: 0)).count == 4)
}

// MARK: Tap detection

@Test func aStillTouchIsATap() {
    var pad = engine()
    pad.began(at: .zero)
    _ = pad.moved(to: CGPoint(x: 3, y: 2))
    #expect(pad.ended())
}

@Test func aTouchThatSteppedIsNeverATap() {
    var pad = engine()
    pad.began(at: .zero)
    _ = pad.moved(to: CGPoint(x: step, y: 0))
    #expect(!pad.ended())
}

@Test func aWanderingFingerThatReturnsIsNotATap() {
    var pad = engine()
    pad.began(at: .zero)
    // Displacement ends at zero, but the finger travelled 20pt. Measuring
    // displacement instead of path length would call this a tap and fire OK
    // when the user was clearly dragging.
    _ = pad.moved(to: CGPoint(x: 10, y: 0))
    _ = pad.moved(to: .zero)
    #expect(!pad.ended())
}

@Test func beganResetsEverythingFromThePreviousTouch() {
    var pad = engine()
    pad.began(at: .zero)
    _ = pad.moved(to: CGPoint(x: step * 3, y: 0))
    #expect(!pad.ended())

    // A fresh touch must not inherit the last one's steps or travel, or the
    // first tap after any swipe would be swallowed.
    pad.began(at: CGPoint(x: 500, y: 500))
    _ = pad.moved(to: CGPoint(x: 502, y: 500))
    #expect(pad.ended())
}

@Test func stepsAreMeasuredFromTheTouchOriginNotTheScreenOrigin() {
    var pad = engine()
    pad.began(at: CGPoint(x: 200, y: 200))
    // A touch starting far from zero must need the same travel as any other.
    #expect(pad.moved(to: CGPoint(x: 200 + step - 1, y: 200)).isEmpty)
    #expect(pad.moved(to: CGPoint(x: 200 + step, y: 200)) == [.right])
}

@Test func aSteppedTouchIsNotATapEvenWhenItsTravelIsShort() {
    // Deliberately inverted thresholds: a step costs LESS travel than a tap
    // allows. Nothing ships this way — the shipped step is the larger — but this
    // is the only configuration that separates the two halves of the tap
    // rule, and "it stepped, so it was not a tap" must hold on its own rather
    // than leaning on the shipped step being larger. Without it a swipe would
    // also fire OK.
    var pad = SwipePadEngine(stepDistance: 5, tapDistance: 50)
    pad.began(at: .zero)
    #expect(pad.moved(to: CGPoint(x: 6, y: 0)) == [.right])
    #expect(!pad.ended())
}
