import Foundation

/// Owns the IME write handshake this TV requires and the merged read state.
/// Session-free: bytes leave through `send`, decoded messages arrive through
/// `handle` — every path is testable with a scripted fake (no TV, no clock).
///
/// The handshake (spike-verified, docs/phase2-notes.md "IME write direction"):
/// a bare batch edit is silently IGNORED. The TV accepts edits only after an
/// ime_show_request echoing the focused field's status counter, answered by a
/// field-21 message whose counters the edits must carry. No answer ever comes
/// unless the TV's on-screen keyboard NEEDS showing — so a handshake timeout
/// MEANS "keyboard closed", and the channel publishes focus lost rather than
/// lying.
///
/// One handshake covers MANY writes (probe `settext --twice`, real TV): the
/// counters from the first reply keep working for as long as the field stays
/// focused. Handshaking per write therefore breaks after the first one — the
/// IME is already showing, so the second request is answered by silence, which
/// the timeout path then misreports as "keyboard closed". Hence the session
/// bookkeeping below: handshake once, reuse until something invalidates it.
@MainActor
final class ImeChannel {
    var onFieldChanged: ((TextFieldStatus?) -> Void)?
    private(set) var focusedField: TextFieldStatus?

    /// True from the moment a write begins until it completes, aborts, or is
    /// cancelled — published through a closure exactly like `onFieldChanged`,
    /// so the controller can mirror it into `@Observable` state.
    ///
    /// A write is clear-then-append, and the TV echoes the intermediate EMPTY
    /// field between the two edits. That echo is a real, absolute field status:
    /// nothing about its VALUE distinguishes our own transient state from a
    /// genuine TV-side clear. Anything mirroring the field therefore has to be
    /// told when a value belongs to a write of ours still in progress — typing
    /// fast used to lose the beginning of the text because the phone's box
    /// adopted that intermediate and every later keystroke built on the wiped
    /// value.
    var onWriteInFlightChanged: ((Bool) -> Void)?
    private(set) var isWriteInFlight = false

    private let send: (Data) -> Void
    private let sleep: (Duration) async -> Void

    private var lastPackage = ""
    private var imeCounter: UInt64 = 0
    private var fieldCounter: UInt64 = 0
    private var stateEpoch = 0      // bumped on every incoming imeState
    private var statusEpoch = 0     // bumped on every incoming fieldStatus

    // An established IME write session: the TV has answered one
    // ime_show_request, and `imeCounter`/`fieldCounter` from that reply stay
    // valid for every subsequent edit into the same field. `sessionPackage`
    // is the app the session belongs to — the identity we invalidate against,
    // matching the focus-identity guards in `drainWrites`.
    private var handshakeDone = false
    private var sessionPackage: String?

    private var pendingText: String?
    private var writer: Task<Void, Never>?
    // `Task` has no identity comparison (`===` doesn't apply), so a stale
    // task can't be told apart from the current one by reference. This
    // monotonic counter stands in for identity: bumped every time a writer
    // is spawned (and again on reset()), it lets a task recognize — even
    // after it's been cancelled and left running past that point — whether
    // it's still the one `writer` refers to before it dares clear it.
    private var writerGeneration = 0

    init(send: @escaping (Data) -> Void,
         sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.send = send
        self.sleep = sleep
    }

    func handle(_ message: ImeMessage) {
        switch message {
        case .fieldStatus(var status):
            if status.packageName.isEmpty {
                status.packageName = lastPackage   // field-22 statuses carry no app info
            } else {
                lastPackage = status.packageName
            }
            // A status belonging to a different app means the field we
            // handshook for is gone; its counters are no longer ours to
            // reuse. Our own edit echoes come back as same-package statuses
            // (field-22 echoes carry no package and were merged onto
            // `lastPackage` just above), so they never void the session.
            if status.packageName != sessionPackage { invalidateSession() }
            focusedField = status
            statusEpoch += 1
            onFieldChanged?(status)
        case .appChanged(let package):
            lastPackage = package
            // Focus lost / foreground app changed: even if the same app
            // hands us a field again later, that is a NEW field the TV has
            // not yet issued counters for.
            invalidateSession()
            focusedField = nil
            onFieldChanged?(nil)
        case .imeState(let ime, let field):
            imeCounter = ime
            fieldCounter = field
            stateEpoch += 1
        }
    }

    /// Replace the focused field's contents. Fire-and-forget; concurrent
    /// calls coalesce — only the latest text reaches the TV.
    func setText(_ text: String) {
        pendingText = text
        // Before the `writer == nil` guard: a coalesced write is still a write
        // in flight, and the flag has to be true from the FIRST instant — the
        // clear's echo can land before this call's caller ever runs again.
        setWriteInFlight(true)
        guard writer == nil else { return }
        writerGeneration += 1
        let generation = writerGeneration
        writer = Task { [weak self] in
            await self?.drainWrites()
            self?.finishWriter(generation: generation)
        }
    }

    /// Only the task whose generation is still current may clear `writer`.
    ///
    /// `reset()` sets `writer = nil` the instant it calls `cancel()` — the
    /// cancelled task itself is only *marked* cancelled and keeps running
    /// until its next suspension point. If a fresh `setText` lands in that
    /// window (reconnect-then-type is a realistic path), it sees `writer
    /// == nil` and spawns a new task, which this function's caller
    /// (`writer`'s trailing closure) must not be allowed to wipe out when
    /// the stale task finally notices it was cancelled and unwinds.
    private func finishWriter(generation: Int) {
        guard writerGeneration == generation else { return }
        writer = nil
        // Every way out of `drainWrites` funnels here — the loop draining, an
        // abort on a focus change, a handshake timeout, a cancellation the
        // task noticed itself — so this one line covers "completes, aborts, or
        // is cancelled". A stale generation is the exception, and it is the
        // right one: whoever bumped it (reset, or a newer writer) owns the
        // flag now.
        setWriteInFlight(false)
    }

    func reset() {
        writer?.cancel()
        writer = nil
        writerGeneration += 1   // the cancelled task's captured generation can never match again
        pendingText = nil
        // The cancelled task's `finishWriter` can no longer match its
        // generation, so reset() clears the flag itself — synchronously, in the
        // same breath as focus-lost.
        setWriteInFlight(false)
        invalidateSession()
        focusedField = nil
        onFieldChanged?(nil)
    }

    /// Publishes only on an actual change, so a coalesced burst of writes is
    /// one `true` rather than one per keystroke.
    private func setWriteInFlight(_ value: Bool) {
        guard isWriteInFlight != value else { return }
        isWriteInFlight = value
        onWriteInFlightChanged?(value)
    }

    /// Forget the established handshake, so the next write makes a new one.
    private func invalidateSession() {
        handshakeDone = false
        sessionPackage = nil
    }

    // `reset()` cancels `writer`, but that alone does not stop an
    // in-flight `drainWrites`: the injected `sleep` default
    // (`try? await Task.sleep`) swallows CancellationError and returns
    // immediately, and nothing else in the poll loops observed
    // cancellation. Left unchecked, a cancelled write burned through its
    // remaining poll iterations with zero delay, still called `send(...)`
    // into a session being torn down, and could still overwrite
    // `focusedField`/fire `onFieldChanged` after the caller believed reset
    // was complete. Every loop below now checks `Task.isCancelled` and
    // bails out doing nothing further — reset()'s own one-time `nil`
    // publish remains the only observable effect of a reset.
    private func drainWrites() async {
        var retried = false
        var reHandshaked = false
        while let text = pendingText {
            if Task.isCancelled { return }
            pendingText = nil

            // NEVER send a no-op edit. The firmware applies the NET length
            // change at the cursor, and the TV echoes only edits that
            // actually took effect — so an edit that changes nothing comes
            // back as silence, and every echo-wait below reads silence as a
            // dead session. Clearing an already-empty field is exactly that:
            // a write with nothing to send. Complete it, in total silence —
            // not even a handshake, since an ime_show_request into an IME
            // that is already showing goes unanswered too and would publish
            // a bogus focus-lost.
            if text.isEmpty, focusedField?.value.isEmpty == true { continue }

            // Snapshot which field we're writing into. `performHandshake`
            // only waits on `stateEpoch` (an `.imeState` reply) — a
            // DIFFERENT message from `.fieldStatus`/`.appChanged` — and
            // each poll suspends up to 150ms, so `handle(...)` runs freely
            // for up to 1.5s while we wait. If focus moves to another
            // field/app in that window, a live re-read of `focusedField`
            // below would silently splice our edit onto the wrong app's
            // text. `packageName` is the identity we check; our own
            // accepted edits echo back as a same-package `.fieldStatus`
            // (field-22 echoes carry no package and get merged onto the
            // last known one — see `handle`), so they never trip this.
            let targetPackage = focusedField?.packageName

            // Handshake ONLY when no session is established. Once the TV has
            // answered once, a second ime_show_request is answered by silence
            // (its IME is already showing) and this timeout path would report
            // a perfectly live keyboard as closed — the Task 7 field bug.
            if !handshakeDone {
                guard await performHandshake() else {
                    if Task.isCancelled { return }   // cancelled, not a real timeout — stay silent
                    // Keyboard closed on the TV — the only observed cause of a
                    // missing reply to a FIRST request. Tell the UI the truth
                    // instead of hanging.
                    focusedField = nil
                    onFieldChanged?(nil)
                    return
                }
                if Task.isCancelled { return }   // don't resurrect a session reset() just voided
                handshakeDone = true
                sessionPackage = targetPackage
            }

            // Re-check identity now that the handshake may have suspended us:
            // abort exactly like a timeout if focus moved elsewhere.
            guard let target = focusedField, target.packageName == targetPackage else {
                invalidateSession()
                focusedField = nil
                onFieldChanged?(nil)
                return
            }

            let currentLength = target.value.count
            if currentLength > 0 {
                if Task.isCancelled { return }
                send(ImeEncoder.deleteTail(imeCounter: imeCounter,
                                           fieldCounter: fieldCounter, count: currentLength))
                _ = await awaitBump(of: \.statusEpoch)   // echo is truth; proceed either way
            }
            if Task.isCancelled { return }

            // Third suspension point, same danger as the one above: the
            // delete's echo-wait just suspended us for up to 1.5s, and
            // that's plenty of time for focus to have moved to another
            // app in between. Re-check identity once more before the
            // append goes out — otherwise our text lands in whatever
            // field is newly focused instead of the one we were asked
            // to edit.
            guard let stillTarget = focusedField, stillTarget.packageName == targetPackage else {
                invalidateSession()
                focusedField = nil
                onFieldChanged?(nil)
                return
            }
            // Erasing everything: the delete above IS the whole write, and
            // its echo was its confirmation. Appending "" here would be the
            // no-op described at the top of the loop — unechoed, and the
            // silence would trip the self-heal below into voiding a live
            // session and re-handshaking into the already-showing IME. That
            // is what made "erase all, then type again" go permanently dead
            // on real hardware.
            if text.isEmpty { continue }

            send(ImeEncoder.append(imeCounter: imeCounter, fieldCounter: fieldCounter, text: text))
            let echoed = await awaitBump(of: \.statusEpoch)
            if Task.isCancelled { return }

            // Self-healing. Silence where our own edit's echo belongs means
            // the counters we reused are no longer accepted — the session
            // expired server-side (the TV dismissed its IME, the app swapped
            // fields without telling us, …). Void it and give this write one
            // more go, which will handshake afresh. Exactly one: if that
            // handshake also goes unanswered, the keyboard really is closed
            // and the timeout path above publishes focus lost rather than
            // spinning.
            if !echoed {
                invalidateSession()
                if !reHandshaked, pendingText == nil {
                    reHandshaked = true
                    pendingText = text
                }
                continue
            }
            // Same identity guard on the retry check: an unrelated status
            // push landing while we wait for our own echo must not be
            // mistaken for it (which could fire a bogus retry) — but it
            // also must not be treated as a fresh write-abort here, since
            // the append was already sent; `handle` has already published
            // the real focus change on its own.
            if focusedField?.packageName == targetPackage,
               let value = focusedField?.value, value != text,
               pendingText == nil, !retried {
                retried = true          // absolute statuses make one retry safe
                pendingText = text
            }
        }
    }

    private func performHandshake() async -> Bool {
        for _ in 0..<2 {   // the spec's "one retry"
            if Task.isCancelled { return false }
            let epoch = stateEpoch
            send(ImeEncoder.showRequest(statusCounter: focusedField?.counter ?? 0))
            for _ in 0..<10 {
                if Task.isCancelled { return false }
                await sleep(.milliseconds(150))
                if stateEpoch != epoch { return true }
            }
        }
        return false
    }

    /// Polls for the next bump of an epoch (≤1.5s of injected sleep).
    private func awaitBump(of keyPath: KeyPath<ImeChannel, Int>) async -> Bool {
        let epoch = self[keyPath: keyPath]
        for _ in 0..<10 {
            if Task.isCancelled { return false }
            await sleep(.milliseconds(150))
            if self[keyPath: keyPath] != epoch { return true }
        }
        return false
    }
}
