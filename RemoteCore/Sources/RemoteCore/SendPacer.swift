import Foundation

/// Keeps two outbound control messages from leaving in the same turn.
///
/// This TV's parser cannot split two protocol messages that arrive in one TCP
/// segment: it closes the control session outright with
/// `receiveDataError(POSIXErrorCode 96)`. `setHeldDirection` produced exactly
/// that shape — a release and a hold emitted back-to-back on every direction
/// change — so dragging in a circle disconnected the app.
///
/// The floor is about SEPARATION, not rate. Measured on the Xiaomi
/// MiTV-MOSR1 (2026-08-23, `rc-probe pace`, 12-60 direction changes per run):
///
/// | gap | result |
/// |---|---|
/// | 0ms | drops every time |
/// | 1ms | survives every time |
/// | 8ms | survives a 60-change soak, twice |
/// | 16/40/80ms | survives |
///
/// So 8ms — half a display frame, imperceptible — with 8x margin over the
/// measured failure point, because what has to be separated is the arrival at
/// the TV and Wi-Fi can re-coalesce what we spaced out. The 80ms that
/// `sendText` used was ~80x more than the hardware needs.
///
/// A send already clear of the floor goes out SYNCHRONOUSLY: an ordinary
/// button press pays nothing, which is the whole point of measuring rather
/// than inheriting the old constant.
@MainActor
final class SendPacer {
    /// Measured floor plus margin — see the table above. `nonisolated` so it
    /// can be a default argument to `init`, which callers reach off the actor.
    nonisolated static let defaultFloor = Duration.milliseconds(8)

    private let floor: Duration
    private let clock: () -> ContinuousClock.Instant
    private let pause: (Duration) async -> Void

    private var lastSend: ContinuousClock.Instant?
    private var pending: [() -> Void] = []
    private var drainTask: Task<Void, Never>?

    init(
        floor: Duration = SendPacer.defaultFloor,
        clock: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        pause: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.floor = floor
        self.clock = clock
        self.pause = pause
    }

    /// Sends immediately when the floor is already satisfied and nothing is
    /// waiting; otherwise queues, preserving order. Order matters more than it
    /// looks: a release queued behind its own hold is what keeps a held key
    /// from leaking, so this queue is never reordered and never drops work.
    func send(_ work: @escaping () -> Void) {
        guard pending.isEmpty, isClear else {
            pending.append(work)
            startDraining()
            return
        }
        fire(work)
    }

    /// Sends everything still queued at once, floor ignored, and stops the
    /// drain. For teardown ONLY.
    ///
    /// The floor is worth breaking here because the two failure modes are not
    /// symmetric: a coalesced read costs a session that is closing anyway,
    /// while a release that never leaves costs a key held down on a TV with
    /// nothing left on screen able to lift it.
    func flush() {
        drainTask?.cancel()
        drainTask = nil
        let queued = pending
        pending.removeAll()
        for work in queued { work() }
        if !queued.isEmpty { lastSend = clock() }
    }

    /// True when nothing has been sent yet, or the floor has already elapsed.
    private var isClear: Bool {
        guard let last = lastSend else { return true }
        return clock() - last >= floor
    }

    private func fire(_ work: () -> Void) {
        work()
        lastSend = clock()
    }

    /// How long until the floor is satisfied; nil when it already is.
    private var remainingWait: Duration? {
        guard let last = lastSend else { return nil }
        let elapsed = clock() - last
        return elapsed >= floor ? nil : floor - elapsed
    }

    private func startDraining() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [self] in
            while !pending.isEmpty {
                if let wait = remainingWait { await pause(wait) }
                // A drain only ever suspends here, so a `flush()` that landed
                // while we were parked is always seen BEFORE we touch the
                // queue or the handle — which is what keeps an orphaned drain
                // from stealing work from the one that replaced it.
                if Task.isCancelled { return }
                guard !pending.isEmpty else { break }
                fire(pending.removeFirst())
            }
            drainTask = nil
        }
    }
}
