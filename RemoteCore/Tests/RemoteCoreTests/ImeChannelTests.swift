import Foundation
import Testing
@testable import RemoteCore

/// Drives ImeChannel with scripted messages. `sleep` yields instead of
/// sleeping, so tests run in microseconds while preserving suspension points.
@MainActor
private func makeChannel() -> (ImeChannel, sent: () -> [Data]) {
    var sent: [Data] = []
    let channel = ImeChannel(send: { sent.append($0) }, sleep: { _ in await Task.yield() })
    return (channel, { sent })
}

/// Spin the main actor until `condition` or a bounded number of yields.
@MainActor
private func spin(until condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { await Task.yield() }
}

private let browserField = TextFieldStatus(
    counter: 85, value: "hi", selectionStart: 2, selectionEnd: 2,
    hint: "Пошук", packageName: "com.internet.tvbrowser")

@MainActor @Test func statusPublishesAndMergesPackage() {
    let (channel, _) = makeChannel()
    var published: [TextFieldStatus?] = []
    channel.onFieldChanged = { published.append($0) }
    channel.handle(.fieldStatus(browserField))
    // A field-22 status arrives with no package — the channel must remember it.
    var bare = browserField
    bare.packageName = ""
    channel.handle(.fieldStatus(bare))
    #expect(published.count == 2)
    #expect(published[1]?.packageName == "com.internet.tvbrowser")
}

@MainActor @Test func appChangeClearsFocus() {
    let (channel, _) = makeChannel()
    channel.handle(.fieldStatus(browserField))
    channel.handle(.appChanged(packageName: "com.netflix.ninja"))
    #expect(channel.focusedField == nil)
}

@MainActor @Test func setTextRunsHandshakeThenClearThenAppend() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))               // "hi", counter 85
    channel.setText("привіт")
    await spin { sent().count == 1 }
    #expect(sent()[0] == ImeEncoder.showRequest(statusCounter: 85))
    channel.handle(.imeState(0, 0))                          // TV's counter reset
    await spin { sent().count == 2 }
    #expect(sent()[1] == ImeEncoder.deleteTail(imeCounter: 0, fieldCounter: 0, count: 2))
    let cleared = TextFieldStatus(counter: 86, value: "", selectionStart: 0, selectionEnd: 0,
                                  hint: "Пошук", packageName: "com.internet.tvbrowser")
    channel.handle(.fieldStatus(cleared))                    // clear echo
    await spin { sent().count == 3 }
    #expect(sent()[2] == ImeEncoder.append(imeCounter: 0, fieldCounter: 0, text: "привіт"))
}

@MainActor @Test func emptyFieldSkipsTheClearEdit() async {
    let (channel, sent) = makeChannel()
    let empty = TextFieldStatus(counter: 77, value: "", selectionStart: 0, selectionEnd: 0,
                                hint: "", packageName: "app")
    channel.handle(.fieldStatus(empty))
    channel.setText("hello")
    await spin { sent().count == 1 }
    channel.handle(.imeState(0, 0))
    await spin { sent().count == 2 }
    #expect(sent()[1] == ImeEncoder.append(imeCounter: 0, fieldCounter: 0, text: "hello"))
}

@MainActor @Test func handshakeTimeoutRetriesOnceThenClearsFocus() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))
    var published: [TextFieldStatus?] = []
    channel.onFieldChanged = { published.append($0) }
    channel.setText("x")                                     // never answer
    await spin { sent().count == 2 && published.contains(where: { $0 == nil }) }
    #expect(sent().count == 2)                               // original + one retry
    #expect(sent()[0] == sent()[1])
    #expect(channel.focusedField == nil)                     // keyboard closed on TV
}

@MainActor @Test func coalescingKeepsOnlyTheLatestText() async {
    let (channel, sent) = makeChannel()
    let empty = TextFieldStatus(counter: 1, value: "", selectionStart: 0, selectionEnd: 0,
                                hint: "", packageName: "app")
    channel.handle(.fieldStatus(empty))
    channel.setText("a")
    channel.setText("ab")
    channel.setText("abc")                                   // only this must reach the wire
    await spin { sent().count == 1 }
    channel.handle(.imeState(0, 0))
    await spin { sent().count == 2 }
    #expect(sent()[1] == ImeEncoder.append(imeCounter: 0, fieldCounter: 0, text: "abc"))
}

@MainActor @Test func countersFromTheReplyAreUsedNotStaleOnes() async {
    let (channel, sent) = makeChannel()
    channel.handle(.imeState(1, 0))                          // stale connect-time counters
    let empty = TextFieldStatus(counter: 5, value: "", selectionStart: 0, selectionEnd: 0,
                                hint: "", packageName: "app")
    channel.handle(.fieldStatus(empty))
    channel.setText("x")
    await spin { sent().count == 1 }
    channel.handle(.imeState(3, 7))                          // the reply carries NEW counters
    await spin { sent().count == 2 }
    #expect(sent()[1] == ImeEncoder.append(imeCounter: 3, fieldCounter: 7, text: "x"))
}

// MARK: - reset() during an in-flight write
//
// Regression tests for a defect where `writer?.cancel()` alone did not stop
// a write mid-handshake: the injected `sleep` default swallows
// CancellationError via `try?`, and the poll loops never checked
// `Task.isCancelled`. A cancelled write could keep polling, still `send`
// into a session being torn down, and still overwrite `focusedField` /
// fire `onFieldChanged` after the caller believed reset was complete.
//
// The fake `sleep` used here (`{ _ in await Task.yield() }`) never throws,
// so it does not exercise the CancellationError path directly — these
// tests instead assert on the `Task.isCancelled` guards' observable
// effect: nothing further is sent or published once `reset()` returns.

@MainActor @Test func resetDuringHandshakeStopsFurtherSends() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))
    channel.setText("x")                                     // handshake in flight; no reply ever comes
    await spin { sent().count == 1 }
    let countAtReset = sent().count
    channel.reset()
    // Pump the run loop hard; if the cancelled write kept polling it would
    // have sent the handshake retry (and possibly more) well within this.
    await spin { false }
    #expect(sent().count == countAtReset)
}

@MainActor @Test func resetDuringHandshakeStopsFurtherPublish() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))
    var published: [TextFieldStatus?] = []
    channel.onFieldChanged = { published.append($0) }
    channel.setText("x")                                     // handshake in flight; no reply ever comes
    await spin { sent().count == 1 }
    channel.reset()
    #expect(channel.focusedField == nil)
    #expect(published == [nil])                              // reset's own one-time publish
    await spin { false }
    #expect(channel.focusedField == nil)
    #expect(published == [nil])                               // no further callback of any kind
    #expect(!published.contains { $0 != nil })                // and certainly nothing non-nil
}

// MARK: - concurrency defects found in review (round 2)
//
// Two more defects in the handshake's own plan, not in the transcription:
// (1) `Task` has no identity comparison, so `reset()` nilling `writer`
//     synchronously while the cancelled task is only *marked* cancelled
//     (not yet stopped) let a fresh `setText` spawn a second task, which
//     the stale task's own unconditional `writer = nil` then clobbered —
//     leaving a THIRD `setText` free to spawn a concurrent writer.
// (2) `drainWrites` re-read `focusedField` live after the handshake
//     suspended for up to 1.5s; a focus change landing in that window was
//     invisible to the write, so it could delete-and-append into whatever
//     field/app was newly focused instead of the one it was asked to edit.

/// Give a stale, cancelled write task a bounded number of scheduling turns
/// to reach its own `Task.isCancelled` check and unwind — WITHOUT pumping
/// so hard that a second, legitimately-waiting write times out on its own
/// 20-poll handshake budget (10 polls × 2 rounds under the fake clock,
/// where each poll costs roughly one scheduling turn). The default of 3 is
/// comfortably above what the stale task needs (roughly 1 turn) and
/// comfortably below the innocent handshake's 10-turn-per-round budget.
@MainActor
private func yieldTicks(_ count: Int = 3) async {
    for _ in 0..<count { await Task.yield() }
}

@MainActor @Test func resetThenImmediateSetTextDoesNotClobberTheNewWriter() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))                // "hi", counter 85
    channel.setText("first")                                  // T1: handshake sent, never answered
    await spin { sent().count == 1 }
    #expect(sent()[0] == ImeEncoder.showRequest(statusCounter: 85))

    channel.reset()                                           // cancels T1 — still alive till it notices
    channel.handle(.fieldStatus(browserField))                // re-focus, as a reconnect would
    channel.setText("second")                                 // T2 spawns: writer was nil after reset
    await spin { sent().count == 2 }
    #expect(sent()[1] == ImeEncoder.showRequest(statusCounter: 85))

    // Let the stale T1 get scheduled far enough to reach its own
    // finishWriter check. Pre-fix, its trailing `writer = nil` is
    // unconditional and wipes the reference to the still-running T2. Kept
    // short (see yieldTicks) so T2's own handshake — deliberately left
    // unanswered up to this point — doesn't have room to time out on its
    // own and confound the result.
    await yieldTicks()

    // If `writer` was wiped above, this sees writer == nil and spawns a
    // THIRD task concurrently with T2 — a second showRequest would go out
    // even though T2's own handshake is still outstanding.
    channel.setText("third")
    await yieldTicks()
    #expect(sent().count == 2)                                // no extra/duplicate showRequest

    // The single surviving writer (T2) still completes "second" normally
    // once its handshake reply arrives — the fix must not break this.
    channel.handle(.imeState(0, 0))
    await spin { sent().count == 3 }
    #expect(sent()[2] == ImeEncoder.deleteTail(imeCounter: 0, fieldCounter: 0, count: 2))
    let cleared = TextFieldStatus(counter: 86, value: "", selectionStart: 0, selectionEnd: 0,
                                  hint: "Пошук", packageName: "com.internet.tvbrowser")
    channel.handle(.fieldStatus(cleared))
    await spin { sent().count == 4 }
    #expect(sent()[3] == ImeEncoder.append(imeCounter: 0, fieldCounter: 0, text: "second"))
    #expect(sent().count == 4)                                // exactly one writer's sequence, no more
}

@MainActor @Test func focusChangeBetweenHandshakeAndDeleteAbortsTheWrite() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))                // "hi", counter 85, com.internet.tvbrowser
    var published: [TextFieldStatus?] = []
    channel.onFieldChanged = { published.append($0) }
    channel.setText("привіт")
    await spin { sent().count == 1 }
    #expect(sent()[0] == ImeEncoder.showRequest(statusCounter: 85))

    // The handshake reply arrives, but so does a focus change to a
    // different app in the same beat — before the write ever gets to read
    // the field to build the delete/append.
    channel.handle(.appChanged(packageName: "com.netflix.ninja"))
    channel.handle(.imeState(0, 0))
    await spin { false }                                      // give the writer every chance to misfire

    #expect(sent().count == 1)                                // no delete, no append — write aborted
    #expect(channel.focusedField == nil)
    // `published` is [TextFieldStatus?], so `.last` is doubly-optional;
    // unwrap the outer Optional first so this checks the last PUBLISHED
    // VALUE is nil, not merely that the array is non-empty.
    #expect(!published.isEmpty)
    #expect(published.last! == nil)
}

@MainActor @Test func focusChangeBetweenDeleteAndAppendAbortsTheWrite() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))                // "hi", counter 85, com.internet.tvbrowser
    var published: [TextFieldStatus?] = []
    channel.onFieldChanged = { published.append($0) }
    channel.setText("привіт")
    await spin { sent().count == 1 }
    #expect(sent()[0] == ImeEncoder.showRequest(statusCounter: 85))

    channel.handle(.imeState(0, 0))                            // handshake succeeds
    await spin { sent().count == 2 }
    #expect(sent()[1] == ImeEncoder.deleteTail(imeCounter: 0, fieldCounter: 0, count: 2))

    // A THIRD suspension point: we're now waiting on the delete's echo.
    // Focus moves to a different app in that window — before the write
    // ever gets to read the field again to build the append.
    let otherField = TextFieldStatus(counter: 1, value: "", selectionStart: 0, selectionEnd: 0,
                                     hint: "", packageName: "other.app")
    channel.handle(.appChanged(packageName: "other.app"))
    channel.handle(.fieldStatus(otherField))
    await spin { false }                                       // give the writer every chance to misfire

    #expect(sent().count == 2)                                 // no append — write aborted
    #expect(channel.focusedField == nil)
    #expect(!published.isEmpty)
    #expect(published.last! == nil)                            // focus published as lost
}

@MainActor @Test func sameFieldPackageEchoCompletesTheWriteNormally() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))                // "hi", counter 85, com.internet.tvbrowser
    channel.setText("ok")
    await spin { sent().count == 1 }
    channel.handle(.imeState(0, 0))
    await spin { sent().count == 2 }
    #expect(sent()[1] == ImeEncoder.deleteTail(imeCounter: 0, fieldCounter: 0, count: 2))

    // The clear echo carries no package — field-22 statuses never do — so
    // the identity guard must merge it against the last known package
    // rather than mistake the empty packageName for a focus change.
    let cleared = TextFieldStatus(counter: 86, value: "", selectionStart: 0, selectionEnd: 0,
                                  hint: "Пошук", packageName: "")
    channel.handle(.fieldStatus(cleared))
    await spin { sent().count == 3 }
    #expect(sent()[2] == ImeEncoder.append(imeCounter: 0, fieldCounter: 0, text: "ok"))
    #expect(channel.focusedField?.packageName == "com.internet.tvbrowser")
}

// MARK: - one handshake covers MANY writes (Task 7, found on real hardware)
//
// The text mirror accepted exactly ONE write and then went dead until the
// user typed on the TV's own remote. Cause: `drainWrites` handshook on every
// write, but the TV answers an ime_show_request only when its IME actually
// needs showing — once a session is up, the second request is answered by
// silence, `performHandshake` burns its two rounds and returns false, and the
// timeout path reports a perfectly live keyboard as closed. Probe
// `settext --twice` proved the counters from the FIRST reply keep working
// indefinitely while the field stays focused. So: handshake once, reuse it,
// and invalidate only when the session can no longer be trusted.

private func browserStatus(_ counter: UInt64, _ value: String) -> TextFieldStatus {
    TextFieldStatus(counter: counter, value: value, selectionStart: value.count,
                    selectionEnd: value.count, hint: "Пошук",
                    packageName: "com.internet.tvbrowser")
}

@MainActor @Test func aSecondWriteReusesTheSessionInsteadOfHandshakingAgain() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))                 // "hi", counter 85
    channel.setText("привіт")
    await spin { sent().count == 1 }
    channel.handle(.imeState(0, 0))                            // the one and only handshake reply
    await spin { sent().count == 2 }
    channel.handle(.fieldStatus(browserStatus(86, "")))        // clear echo
    await spin { sent().count == 3 }
    channel.handle(.fieldStatus(browserStatus(87, "привіт")))  // append echo
    await spin { false }                                       // writer #1 unwinds

    // Second write into the same still-focused field. Pre-fix this sent a
    // second showRequest that nothing ever answers, and 3s later published
    // focus-lost — greying the tile and blocking everything after it.
    channel.setText("другий")
    await spin { sent().count == 4 }
    channel.handle(.fieldStatus(browserStatus(88, "")))
    await spin { sent().count == 5 }
    channel.handle(.fieldStatus(browserStatus(89, "другий")))
    await spin { false }

    #expect(sent() == [
        ImeEncoder.showRequest(statusCounter: 85),
        ImeEncoder.deleteTail(imeCounter: 0, fieldCounter: 0, count: 2),
        ImeEncoder.append(imeCounter: 0, fieldCounter: 0, text: "привіт"),
        ImeEncoder.deleteTail(imeCounter: 0, fieldCounter: 0, count: 6),
        ImeEncoder.append(imeCounter: 0, fieldCounter: 0, text: "другий"),
    ])
    #expect(channel.focusedField?.value == "другий")           // still live, still writable
}

@MainActor @Test func aPackageChangeVoidsTheSessionAndForcesAFreshHandshake() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))                 // "hi", counter 85
    channel.setText("a")
    await spin { sent().count == 1 }
    channel.handle(.imeState(4, 9))
    await spin { sent().count == 2 }
    channel.handle(.fieldStatus(browserStatus(86, "")))
    await spin { sent().count == 3 }
    channel.handle(.fieldStatus(browserStatus(87, "a")))
    await spin { false }
    #expect(sent().count == 3)

    // Same app, same field: the session (and its counters) are reused.
    channel.setText("b")
    await spin { sent().count == 4 }
    channel.handle(.fieldStatus(browserStatus(88, "")))
    await spin { sent().count == 5 }
    channel.handle(.fieldStatus(browserStatus(89, "b")))
    await spin { false }
    #expect(sent().count == 5)

    // Focus moves to a DIFFERENT app. Those counters belong to a field we no
    // longer own, so the next write must handshake from scratch.
    let other = TextFieldStatus(counter: 3, value: "", selectionStart: 0, selectionEnd: 0,
                                hint: "", packageName: "com.netflix.ninja")
    channel.handle(.fieldStatus(other))
    channel.setText("c")
    await spin { sent().count == 6 }
    channel.handle(.imeState(7, 7))                            // fresh counters from the new reply
    await spin { sent().count == 7 }

    #expect(sent() == [
        ImeEncoder.showRequest(statusCounter: 85),
        ImeEncoder.deleteTail(imeCounter: 4, fieldCounter: 9, count: 2),
        ImeEncoder.append(imeCounter: 4, fieldCounter: 9, text: "a"),
        ImeEncoder.deleteTail(imeCounter: 4, fieldCounter: 9, count: 1),
        ImeEncoder.append(imeCounter: 4, fieldCounter: 9, text: "b"),
        ImeEncoder.showRequest(statusCounter: 3),
        ImeEncoder.append(imeCounter: 7, fieldCounter: 7, text: "c"),
    ])
}

@MainActor @Test func aMissingAppendEchoVoidsTheSessionAndRetriesWithAFreshHandshake() async {
    let (channel, sent) = makeChannel()
    let empty = TextFieldStatus(counter: 9, value: "", selectionStart: 0, selectionEnd: 0,
                                hint: "", packageName: "app")
    channel.handle(.fieldStatus(empty))
    var published: [TextFieldStatus?] = []
    channel.onFieldChanged = { published.append($0) }
    channel.setText("x")
    await spin { sent().count == 1 }
    channel.handle(.imeState(2, 3))
    await spin { sent().count == 2 }                           // append (empty field: no clear)

    // The echo never comes: the reused counters were rejected, i.e. the
    // session expired server-side. Self-heal — retry the write ONCE, this
    // time re-establishing the session first.
    await spin { sent().count == 3 }

    // Nobody answers that handshake either, so the keyboard really is closed:
    // one retry round, then focus-lost. It must NOT spin on this forever.
    await spin { channel.focusedField == nil }

    #expect(sent() == [
        ImeEncoder.showRequest(statusCounter: 9),
        ImeEncoder.append(imeCounter: 2, fieldCounter: 3, text: "x"),
        ImeEncoder.showRequest(statusCounter: 9),              // self-healing re-handshake
        ImeEncoder.showRequest(statusCounter: 9),              // its own single retry round
    ])
    #expect(channel.focusedField == nil)
    #expect(published == [nil])                                // focus-lost published exactly once
}

@MainActor @Test func focusLostThenRegainedInTheSameAppStillHandshakes() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))
    channel.setText("a")
    await spin { sent().count == 1 }
    channel.handle(.imeState(0, 0))
    await spin { sent().count == 2 }
    channel.handle(.fieldStatus(browserStatus(86, "")))
    await spin { sent().count == 3 }
    channel.handle(.fieldStatus(browserStatus(87, "a")))
    await spin { false }

    // The keyboard closes and reopens on the SAME app: the package is
    // unchanged, so only the `.appChanged` can void the session — and it
    // must, because the reopened field's counters are new ones.
    channel.handle(.appChanged(packageName: "com.internet.tvbrowser"))
    channel.handle(.fieldStatus(browserStatus(90, "")))
    channel.setText("b")
    await spin { sent().count == 4 }
    #expect(sent().count == 4)
    #expect(sent().last == ImeEncoder.showRequest(statusCounter: 90))
}

// MARK: - never send a no-op edit (Task 7 fix 2, found on real hardware)
//
// Typing worked, but erasing EVERYTHING and typing again killed the field
// until the TV pushed a status of its own. Cause: clearing means
// `setText("")`, and `drainWrites` unconditionally followed its delete with
// `append(text: "")`. This firmware applies the NET length change at the
// cursor, so an append of "" changes nothing — and the TV echoes only edits
// that actually took effect, so nothing came back. The missing echo tripped
// the self-heal, which voided a perfectly live session and re-handshook into
// the already-showing IME — the exact silence `4a8def9` fixed. Rule: never
// send an edit whose net change is zero.

@MainActor @Test func clearingAFieldSendsTheDeleteAndNoAppend() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))                 // "hi", counter 85
    var published: [TextFieldStatus?] = []
    channel.onFieldChanged = { published.append($0) }
    channel.setText("")                                        // the user erased everything
    await spin { sent().count == 1 }
    #expect(sent()[0] == ImeEncoder.showRequest(statusCounter: 85))
    channel.handle(.imeState(0, 0))
    await spin { sent().count == 2 }
    #expect(sent()[1] == ImeEncoder.deleteTail(imeCounter: 0, fieldCounter: 0, count: 2))
    channel.handle(.fieldStatus(browserStatus(86, "")))        // the delete's echo IS the confirmation
    await spin { false }                                       // every chance to send a stray append

    #expect(sent().count == 2)                                 // no append of "" — it would be a no-op
    #expect(channel.focusedField?.value == "")                 // session not poisoned
    #expect(!published.contains { $0 == nil })                 // and no bogus focus-lost
}

@MainActor @Test func typingAfterAClearStillReachesTheTvOnTheSameSession() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))                 // "hi", counter 85
    channel.setText("")
    await spin { sent().count == 1 }
    channel.handle(.imeState(0, 0))
    await spin { sent().count == 2 }
    channel.handle(.fieldStatus(browserStatus(86, "")))
    await spin { false }                                       // writer #1 unwinds

    // The field is empty and the session is still the original one, so this
    // must go out as a bare append — no clear, and above all no second
    // ime_show_request (the TV's IME is already showing and would not answer).
    channel.setText("нове")
    await spin { sent().count == 3 }
    channel.handle(.fieldStatus(browserStatus(87, "нове")))
    await spin { false }

    #expect(sent() == [
        ImeEncoder.showRequest(statusCounter: 85),
        ImeEncoder.deleteTail(imeCounter: 0, fieldCounter: 0, count: 2),
        ImeEncoder.append(imeCounter: 0, fieldCounter: 0, text: "нове"),
    ])
    #expect(channel.focusedField?.value == "нове")
}

@MainActor @Test func clearingAnAlreadyEmptyFieldSendsNothingAtAll() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserStatus(85, "")))         // already empty
    var published: [TextFieldStatus?] = []
    channel.onFieldChanged = { published.append($0) }
    channel.setText("")
    await spin { false }

    // Not even a handshake: there is no edit to authorise, and an
    // unanswered ime_show_request would publish a bogus focus-lost.
    #expect(sent().isEmpty)
    #expect(published.isEmpty)
    #expect(channel.focusedField?.counter == 85)

    // ...and the channel is still fully usable afterwards.
    channel.setText("x")
    await spin { sent().count == 1 }
    #expect(sent()[0] == ImeEncoder.showRequest(statusCounter: 85))
    channel.handle(.imeState(0, 0))
    await spin { sent().count == 2 }
    #expect(sent()[1] == ImeEncoder.append(imeCounter: 0, fieldCounter: 0, text: "x"))
}

/// Guards the OPPOSITE defect from the three above: the self-heal must still
/// fire when a NON-empty write's echo genuinely goes missing. This one cannot
/// fail before the fix — it asserts behaviour the fix must preserve, not
/// behaviour the fix adds.
@MainActor @Test func aLostEchoOnANonEmptyWriteStillSelfHeals() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))                 // "hi", counter 85
    var published: [TextFieldStatus?] = []
    channel.onFieldChanged = { published.append($0) }
    channel.setText("привіт")
    await spin { sent().count == 1 }
    channel.handle(.imeState(0, 0))
    await spin { sent().count == 2 }
    channel.handle(.fieldStatus(browserStatus(86, "")))        // the delete echoes...
    await spin { sent().count == 3 }
    #expect(sent()[2] == ImeEncoder.append(imeCounter: 0, fieldCounter: 0, text: "привіт"))

    // ...but the append's echo never arrives. That silence is a genuinely
    // expired session: void it and retry once with a fresh handshake.
    await spin { channel.focusedField == nil }

    #expect(sent() == [
        ImeEncoder.showRequest(statusCounter: 85),
        ImeEncoder.deleteTail(imeCounter: 0, fieldCounter: 0, count: 2),
        ImeEncoder.append(imeCounter: 0, fieldCounter: 0, text: "привіт"),
        ImeEncoder.showRequest(statusCounter: 86),             // self-healing re-handshake
        ImeEncoder.showRequest(statusCounter: 86),             // its own single retry round
    ])
    #expect(published.last! == nil)                            // keyboard really is closed
}

// MARK: - write-in-flight (Task 7 fix 3, found on real hardware)
//
// Typing fast lost the BEGINNING of the text: `одісея` typed quickly showed
// `о`, then `од`, and ended at `ея`. Cause: a write is clear-then-append, and
// the TV echoes the intermediate EMPTY field between the two edits. The
// keyboard sheet adopted that echo — wiping the user's box mid-typing — and
// every keystroke landing afterwards built on the wiped value, so what
// survived was the tail. The sheet cannot tell our own transient state from a
// real TV-side clear by VALUE (both are an absolute, empty field-22 status),
// so the channel has to say so: `isWriteInFlight` is true for as long as one
// of our writes is unsettled, and the sheet skips adoption while it is.

@MainActor @Test func writeInFlightSpansTheWholeClearThenAppendWrite() async {
    let (channel, sent) = makeChannel()
    var published: [Bool] = []
    channel.onWriteInFlightChanged = { published.append($0) }
    channel.handle(.fieldStatus(browserField))                 // "hi", counter 85

    #expect(channel.isWriteInFlight == false)                  // idle
    channel.setText("привіт")
    #expect(channel.isWriteInFlight)                           // ...from the very first instant

    await spin { sent().count == 1 }
    channel.handle(.imeState(0, 0))                            // handshake reply
    await spin { sent().count == 2 }                           // deleteTail went out
    #expect(channel.isWriteInFlight)
    // THE echo that used to wipe the phone's text box: our own intermediate.
    channel.handle(.fieldStatus(browserStatus(86, "")))
    #expect(channel.isWriteInFlight)                           // still ours, still unsettled
    await spin { sent().count == 3 }                           // append went out
    channel.handle(.fieldStatus(browserStatus(87, "привіт")))  // append echo
    await spin { channel.isWriteInFlight == false }

    #expect(channel.isWriteInFlight == false)                  // settled
    #expect(published == [true, false])                        // published, and only on change
}

@MainActor @Test func writeInFlightClearsWhenAWriteAbortsOnFocusChange() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))
    channel.setText("привіт")
    await spin { sent().count == 1 }
    #expect(channel.isWriteInFlight)

    // Focus moves to another app while the handshake reply is awaited: the
    // write aborts without ever sending its edits.
    channel.handle(.appChanged(packageName: "com.netflix.ninja"))
    channel.handle(.imeState(0, 0))
    await spin { channel.isWriteInFlight == false }

    #expect(sent().count == 1)                                 // aborted, as before
    #expect(channel.isWriteInFlight == false)                  // and not left stuck true
}

@MainActor @Test func resetClearsWriteInFlight() async {
    let (channel, sent) = makeChannel()
    var published: [Bool] = []
    channel.handle(.fieldStatus(browserField))
    channel.setText("привіт")
    await spin { sent().count == 1 }
    #expect(channel.isWriteInFlight)

    channel.onWriteInFlightChanged = { published.append($0) }
    channel.reset()
    #expect(channel.isWriteInFlight == false)                  // synchronously, like focus-lost
    #expect(published == [false])
    await spin { false }                                       // the cancelled task unwinds
    #expect(channel.isWriteInFlight == false)                  // and does not resurrect it
}
