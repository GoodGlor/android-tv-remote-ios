import CoreGraphics
import Testing
@testable import RemoteCore

// A 60Hz drag is ~16ms per update; fixtures use that spacing.
private let frame = Duration.milliseconds(16)

/// The shipped sensitivity, read rather than repeated: it has been retuned
/// once already (2 -> 3.6) and the two tests that exercise the DEFAULT should
/// not have to change again. Every other test pins `sensitivity: 1`, because
/// it is testing coalescing or tap rules, not scaling.
private let scale = TrackpadEngine().sensitivity

@Test func aDragEmitsTheScaledDelta() {
    var engine = TrackpadEngine()   // default sensitivity, tapDistance 12
    engine.began(at: .zero)
    // Travel (20, 10) -> hypot ~22.4, past the tap threshold, so this sends
    // immediately rather than being withheld as potential jitter.
    #expect(engine.moved(to: CGPoint(x: 20, y: 10), now: frame)
            == CGVector(dx: 20 * scale, dy: 10 * scale))
}

@Test func deltasAreRelativeToTheLastPointNotTheStart() {
    var engine = TrackpadEngine(sensitivity: 1)
    engine.began(at: .zero)
    // First move already clears the tap threshold (travel 20 >= 12), so it
    // sends immediately rather than banking.
    #expect(engine.moved(to: CGPoint(x: 20, y: 0), now: frame) == CGVector(dx: 20, dy: 0))
    // Second update moves another 5 — NOT 15/25. Absolute would drift the
    // cursor away at an accelerating rate.
    #expect(engine.moved(to: CGPoint(x: 25, y: 0), now: frame * 2) == CGVector(dx: 5, dy: 0))
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
    // First move already clears the tap threshold (travel 14 >= 12), so
    // pacing — not the tap gate — is what's under test from here.
    #expect(engine.moved(to: CGPoint(x: 14, y: 0), now: frame) == CGVector(dx: 14, dy: 0))
    // Two updates 4ms apart: both withheld, their motion banked.
    #expect(engine.moved(to: CGPoint(x: 16, y: 0), now: frame + .milliseconds(4)) == nil)
    #expect(engine.moved(to: CGPoint(x: 19, y: 0), now: frame + .milliseconds(8)) == nil)
    // Once the interval passes, the banked motion goes out as ONE delta —
    // nothing is dropped, it is merged.
    #expect(engine.moved(to: CGPoint(x: 20, y: 0), now: frame * 2) == CGVector(dx: 6, dy: 0))
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

@Test func jitterInsideTheTapRadiusSendsNothingAtAll() {
    // Not just "flush == nil" at the end — NO send at any point during the
    // gesture. Sending mid-gesture before the tap threshold is crossed would
    // nudge the cursor on a resting finger's jitter and let a tap land
    // somewhere the finger never visually touched.
    var engine = TrackpadEngine()   // tapDistance 12, default sensitivity
    engine.began(at: CGPoint(x: 100, y: 100))
    #expect(engine.moved(to: CGPoint(x: 102, y: 100), now: frame) == nil)
    #expect(engine.moved(to: CGPoint(x: 103, y: 101), now: frame * 2) == nil)
    let release = engine.ended(at: CGPoint(x: 103, y: 101), now: frame * 3)
    #expect(release.isTap == true)
    #expect(release.flush == nil)
}

@Test func crossingTheTapThresholdFlushesTheBankedSubThresholdMotion() {
    // Once real motion crosses the threshold, the first send must include
    // everything banked while still under it — total displacement is
    // conserved, nothing withheld is dropped.
    var engine = TrackpadEngine(sensitivity: 1, tapDistance: 12)
    engine.began(at: .zero)
    // 5pt of travel — under the 12pt threshold — withheld.
    #expect(engine.moved(to: CGPoint(x: 5, y: 0), now: frame) == nil)
    // Another 5pt: cumulative travel 10, still under threshold — withheld.
    #expect(engine.moved(to: CGPoint(x: 10, y: 0), now: frame * 2) == nil)
    // 5pt more: cumulative travel 15, now past the threshold — the send
    // includes ALL 15pt banked so far, not just this last step.
    #expect(engine.moved(to: CGPoint(x: 15, y: 0), now: frame * 3) == CGVector(dx: 15, dy: 0))
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
    // The delta (15) crosses the tap threshold on its own, proving it is a
    // small relative step from the last point — not the huge jump a delta
    // from the origin (200) would produce.
    #expect(engine.moved(to: CGPoint(x: 215, y: 200), now: frame) == CGVector(dx: 15, dy: 0))
}
