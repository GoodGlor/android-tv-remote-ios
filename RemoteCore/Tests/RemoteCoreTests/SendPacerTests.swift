import Foundation
import Testing
@testable import RemoteCore

/// A clock the test advances by hand, plus a `pause` that advances it by
/// exactly what the pacer asked to wait. Together they make the drain
/// deterministic: no real sleeping, and every wait the pacer requests is
/// recorded so the tests can assert on the gap rather than on wall-clock.
@MainActor
private final class FakeClock {
    private(set) var now = ContinuousClock.now
    private(set) var waits: [Duration] = []

    func advance(_ duration: Duration) { now = now.advanced(by: duration) }

    var read: () -> ContinuousClock.Instant { { [self] in now } }

    var pause: (Duration) async -> Void {
        { [self] duration in
            waits.append(duration)
            advance(duration)
        }
    }
}

private let floor = Duration.milliseconds(8)

@MainActor
private func makePacer(_ clock: FakeClock) -> SendPacer {
    SendPacer(floor: floor, clock: clock.read, pause: clock.pause)
}

// MARK: The point of the whole type — no cost when the floor is already clear

@MainActor
@Test func theFirstSendGoesOutSynchronously() {
    let clock = FakeClock()
    let pacer = makePacer(clock)
    var sent: [String] = []

    pacer.send { sent.append("a") }

    // Not "eventually" — the button press must be on the wire before send()
    // returns, or the remote feels laggy.
    #expect(sent == ["a"])
    #expect(clock.waits.isEmpty)
}

@MainActor
@Test func aSendPastTheFloorAlsoGoesOutSynchronously() {
    let clock = FakeClock()
    let pacer = makePacer(clock)
    var sent: [String] = []

    pacer.send { sent.append("a") }
    clock.advance(.milliseconds(9))
    pacer.send { sent.append("b") }

    #expect(sent == ["a", "b"])
    #expect(clock.waits.isEmpty)
}

@MainActor
@Test func aSendExactlyAtTheFloorIsNotDeferred() {
    let clock = FakeClock()
    let pacer = makePacer(clock)
    var sent: [String] = []

    pacer.send { sent.append("a") }
    clock.advance(floor)
    pacer.send { sent.append("b") }

    #expect(sent == ["a", "b"])
}

// MARK: The bug this exists to fix

@MainActor
@Test func twoSendsInTheSameInstantAreSeparated() async {
    let clock = FakeClock()
    let pacer = makePacer(clock)
    var sent: [String] = []

    // Exactly what setHeldDirection does on a direction change: release then
    // hold, no clock movement between them. Before the pacer both left in one
    // TCP segment and the TV closed the session.
    pacer.send { sent.append("release") }
    pacer.send { sent.append("hold") }

    #expect(sent == ["release"], "the second send must not ride along with the first")

    await drain()

    #expect(sent == ["release", "hold"])
    #expect(clock.waits == [floor], "the deferred send waits the floor, no more")
}

@MainActor
@Test func aBurstIsSpacedOutInOrder() async {
    let clock = FakeClock()
    let pacer = makePacer(clock)
    var sent: [Int] = []

    for index in 0..<5 { pacer.send { sent.append(index) } }
    await drain()

    // Order is the leak-safety property: a release queued behind its hold must
    // stay behind it.
    #expect(sent == [0, 1, 2, 3, 4])
    #expect(clock.waits == [floor, floor, floor, floor])
}

@MainActor
@Test func aDeferredSendWaitsOnlyTheRemainder() async {
    let clock = FakeClock()
    let pacer = makePacer(clock)
    var sent: [String] = []

    pacer.send { sent.append("a") }
    clock.advance(.milliseconds(5))
    pacer.send { sent.append("b") }
    await drain()

    // 5ms of the floor already elapsed, so only 3ms is owed. Waiting the full
    // floor would be a needless 5ms of latency on every direction change.
    #expect(clock.waits == [.milliseconds(3)])
    #expect(sent == ["a", "b"])
}

@MainActor
@Test func aSendNeverJumpsAheadOfQueuedWork() async {
    let clock = FakeClock()
    let pacer = makePacer(clock)
    var sent: [String] = []

    pacer.send { sent.append("release") }   // clear, goes out at once
    pacer.send { sent.append("hold") }      // inside the floor, so it queues

    // The floor is now satisfied — but "hold" is still waiting. If a later
    // send were allowed to go out on that basis it would overtake the queue,
    // and a hold landing before its own release is exactly the stuck-key leak
    // the ordering exists to prevent.
    clock.advance(.milliseconds(20))
    pacer.send { sent.append("tap") }

    #expect(sent == ["release"], "nothing may overtake queued work")

    await drain()
    #expect(sent == ["release", "hold", "tap"])
}

// MARK: Teardown — the release must never be the thing that gets dropped

@MainActor
@Test func flushSendsEverythingStillQueued() {
    let clock = FakeClock()
    let pacer = makePacer(clock)
    var sent: [String] = []

    pacer.send { sent.append("hold") }
    pacer.send { sent.append("release") }
    #expect(sent == ["hold"])

    pacer.flush()

    // A queued release is a key still down on the TV. Teardown breaks the
    // floor rather than leave it queued.
    #expect(sent == ["hold", "release"])
    #expect(clock.waits.isEmpty, "flush must not wait")
}

@MainActor
@Test func flushDoesNotResendWhatTheDrainAlreadySent() async {
    let clock = FakeClock()
    let pacer = makePacer(clock)
    var sent: [String] = []

    pacer.send { sent.append("a") }
    pacer.send { sent.append("b") }
    await drain()
    #expect(sent == ["a", "b"])

    pacer.flush()

    #expect(sent == ["a", "b"], "nothing was queued, so flush sends nothing")
}

@MainActor
@Test func aFlushedPacerStillSendsAfterwards() async {
    let clock = FakeClock()
    let pacer = makePacer(clock)
    var sent: [String] = []

    pacer.send { sent.append("a") }
    pacer.send { sent.append("b") }
    pacer.flush()
    #expect(sent == ["a", "b"])

    // A flush must leave the pacer usable: if the orphaned drain took the
    // drain slot with it, every later send would queue and never leave.
    clock.advance(.milliseconds(20))
    pacer.send { sent.append("c") }
    #expect(sent == ["a", "b", "c"])

    pacer.send { sent.append("d") }
    await drain()
    #expect(sent == ["a", "b", "c", "d"])
}

@MainActor
@Test func flushDuringAParkedDrainSendsEachItemExactlyOnce() async {
    let clock = FakeClock()
    let pacer = makePacer(clock)
    var sent: [String] = []

    pacer.send { sent.append("a") }
    pacer.send { sent.append("b") }
    pacer.send { sent.append("c") }
    // The drain is parked in `pause` with b and c still queued.
    pacer.flush()
    await drain()

    #expect(sent == ["a", "b", "c"])
}

/// Lets the drain task run to completion. The fake `pause` returns immediately,
/// so a handful of yields covers a queue far longer than any test's.
private func drain() async {
    for _ in 0..<50 { await Task.yield() }
}
