import Foundation
import Testing
@testable import RemoteCore

// MARK: - Fakes
//
// Fidelity notes — these matter, because polite fakes hide continuation leaks:
//  * The real Lib sessions deliver every event through a `Task { @MainActor }`
//    hop. `asyncEvents = true` reproduces that hop, and with it the window in
//    which a second event overtakes the resumption of an awaiting caller.
//  * Production builds a FRESH session per pairing/connect attempt, so `make()`
//    hands out a new object each time; the factory aggregates what every
//    session saw and `fire` delivers to the newest one (the one the controller
//    currently owns).
//  * `cancel()`/`disconnect()` emit NOTHING, exactly like the library, which
//    nils its state handler before cancelling the socket. Anything awaiting an
//    event at that moment can only be resumed by the controller itself.

@MainActor
final class FakePairingSession: PairingSessioning {
    var onEvent: ((PairingEvent) -> Void)?
    private unowned let factory: FakePairingFactory

    init(factory: FakePairingFactory) { self.factory = factory }

    func start(host: String) { factory.startedHosts.append(host) }
    func sendCode(_ code: String) { factory.sentCodes.append(code) }
    func cancel() { factory.cancelled = true }

    func fire(_ event: PairingEvent) {
        guard factory.asyncEvents else { onEvent?(event); return }
        Task { @MainActor in self.onEvent?(event) }
    }
}

@MainActor
final class FakePairingFactory {
    private(set) var sessions: [FakePairingSession] = []
    var startedHosts: [String] = []
    var sentCodes: [String] = []
    var cancelled = false
    var asyncEvents = false

    func make() -> FakePairingSession {
        let session = FakePairingSession(factory: self)
        sessions.append(session)
        return session
    }

    func fire(_ event: PairingEvent) { sessions.last?.fire(event) }
}

@MainActor
final class FakeControlSession: ControlSessioning {
    var onEvent: ((ControlEvent) -> Void)?
    /// Decoded IME traffic. Tests push messages through this the same way
    /// `LibControlSession` does — `session.onImeMessage?(...)` — which is the
    /// only way to reach the controller's `ImeChannel` from outside.
    var onImeMessage: ((ImeMessage) -> Void)?
    private unowned let factory: FakeControlFactory

    init(factory: FakeControlFactory) { self.factory = factory }

    func connect(host: String) { factory.connectedHosts.append(host) }
    func sendKey(_ key: KeyCommand) { factory.sentKeys.append(key) }
    // Recorded into ONE ordered list, not two: the invariant under test is
    // that a release precedes the hold that displaced it, which two separate
    // arrays could not show.
    func holdKey(_ key: KeyCommand) { factory.holdEvents.append(.hold(key)) }
    func releaseKey(_ key: KeyCommand) { factory.holdEvents.append(.release(key)) }
    func sendText(_ text: String) { factory.sentTexts.append(text) }
    func sendRaw(_ data: Data) { factory.sentRaw.append(data) }
    func sendDeepLink(_ uri: String) { factory.sentDeepLinks.append(uri) }
    func disconnect() { factory.disconnected = true }

    func fire(_ event: ControlEvent) {
        guard factory.asyncEvents else { onEvent?(event); return }
        Task { @MainActor in self.onEvent?(event) }
    }
}

@MainActor
final class FakeControlFactory {
    private(set) var sessions: [FakeControlSession] = []
    var connectedHosts: [String] = []
    var sentKeys: [KeyCommand] = []
    /// Holds and releases across ALL sessions this factory made, in order —
    /// so a release that had to ride the session being torn down is visible.
    var holdEvents: [KeyHoldEvent] = []
    var sentTexts: [String] = []
    var sentRaw: [Data] = []
    var sentDeepLinks: [String] = []
    var disconnected = false
    var asyncEvents = false

    func make() -> FakeControlSession {
        let session = FakeControlSession(factory: self)
        sessions.append(session)
        return session
    }

    func fire(_ event: ControlEvent) { sessions.last?.fire(event) }
}

// MARK: - Deadline-bounded awaits
//
// A regression here is a continuation that never resumes, and awaiting one
// directly would HANG the suite instead of failing it. `PendingCall` runs the
// call in its own task and lets the test poll for a result with a deadline, so
// a leak fails fast.

@MainActor
final class PendingCall<T> {
    private(set) var result: Result<T, any Error>?

    init(_ body: @escaping @MainActor () async throws -> T) {
        Task { @MainActor in
            do { self.result = .success(try await body()) } catch { self.result = .failure(error) }
        }
    }

    /// Returns nil if the call is still pending when the deadline passes.
    func settled(within timeout: Duration = .milliseconds(500)) async -> Result<T, any Error>? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while result == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return result
    }
}

@MainActor
private func expectThrows<T>(_ call: PendingCall<T>, _ expected: TVControllerError, _ what: String) async {
    guard let result = await call.settled() else {
        Issue.record("\(what) never resumed — leaked continuation")
        return
    }
    switch result {
    case .success:
        Issue.record("\(what) should have thrown \(expected)")
    case .failure(let error):
        #expect(error as? TVControllerError == expected)
    }
}

@discardableResult
@MainActor
private func expectSucceeds<T>(_ call: PendingCall<T>, _ what: String) async -> T? {
    guard let result = await call.settled() else {
        Issue.record("\(what) never resumed — leaked continuation")
        return nil
    }
    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        Issue.record("\(what) threw \(error)")
        return nil
    }
}

@MainActor
private func makeController() -> (AndroidTVController, FakePairingFactory, FakeControlFactory) {
    let pairing = FakePairingFactory()
    let control = FakeControlFactory()
    let identity = IdentityProvider.bundled()!
    let controller = AndroidTVController(
        identity: identity,
        makePairing: { pairing.make() },
        makeControl: { control.make() }
    )
    return (controller, pairing, control)
}

/// The arrange half the IME tests repeat: a controller sitting on a live
/// control session. Returns the factory (which aggregates what every session
/// saw) rather than the session, matching the rest of this file; the session
/// itself is `control.sessions.last`, and it is the object IME messages are
/// pushed through.
@MainActor
private func makeConnectedController() async throws -> (AndroidTVController, FakeControlFactory) {
    let (controller, _, control) = makeController()
    async let connect: Void = controller.connect(to: paired)
    try await Task.sleep(for: .milliseconds(20))   // let connect install its continuation
    control.fire(.connected)
    try await connect
    return (controller, control)
}

private let tv = DiscoveredDevice(name: "TV", host: "192.168.31.24", serviceName: "TV")
private let paired = PairedDevice(name: "TV", host: "192.168.31.24", serviceName: "TV")
private let movedTV = PairedDevice(name: "TV", host: "192.168.31.99", serviceName: "TV")

// MARK: - Pairing

@MainActor
@Test func beginPairingResolvesWhenCodeDisplayed() async throws {
    let (controller, pairing, _) = makeController()
    async let begin: Void = controller.beginPairing(with: tv)
    try await Task.sleep(for: .milliseconds(20))     // let beginPairing install its continuation
    pairing.fire(.codeDisplayed)
    try await begin
    #expect(pairing.startedHosts == ["192.168.31.24"])
}

@MainActor
@Test func submitCodeResolvesOnPairedAndReturnsDevice() async throws {
    let (controller, pairing, _) = makeController()
    async let begin: Void = controller.beginPairing(with: tv)
    try await Task.sleep(for: .milliseconds(20))
    pairing.fire(.codeDisplayed)
    try await begin
    async let submit = controller.submitPairingCode("A1B2C3")
    try await Task.sleep(for: .milliseconds(20))
    pairing.fire(.paired)
    let device = try await submit
    #expect(pairing.sentCodes == ["A1B2C3"])
    #expect(device == paired)
}

/// A rejected code closes the pairing socket on the TV side (PairingManager
/// sets `.error(.secretNotSuccess)` then calls `disconnect()`), so the session
/// is dead. Retrying on it must fail fast rather than wait forever for an event
/// that can never arrive; the real retry is a fresh `beginPairing`, which works
/// whether or not the TV keeps showing the same code.
@MainActor
@Test func wrongCodeEndsTheRoundAndRetryNeedsFreshPairing() async throws {
    let (controller, pairing, _) = makeController()
    pairing.asyncEvents = true
    let begin = PendingCall { try await controller.beginPairing(with: tv) }
    try await Task.sleep(for: .milliseconds(20))
    pairing.fire(.codeDisplayed)
    await expectSucceeds(begin, "beginPairing")

    let submit = PendingCall { _ = try await controller.submitPairingCode("FFFFFF") }
    try await Task.sleep(for: .milliseconds(20))
    pairing.fire(.failed(.wrongCode))
    await expectThrows(submit, .wrongCode, "submitPairingCode(wrong)")
    #expect(pairing.cancelled)   // dead session torn down

    // Retry on the dead session: fails fast, and sends nothing into the void.
    let retry = PendingCall { _ = try await controller.submitPairingCode("A1B2C3") }
    await expectThrows(retry, .cancelled, "submitPairingCode on a finished round")
    #expect(pairing.sentCodes == ["FFFFFF"])

    // A fresh pairing round is the supported retry, and it uses a new session.
    let begin2 = PendingCall { try await controller.beginPairing(with: tv) }
    try await Task.sleep(for: .milliseconds(20))
    pairing.fire(.codeDisplayed)
    await expectSucceeds(begin2, "second beginPairing")
    #expect(pairing.startedHosts.count == 2)
    #expect(pairing.sessions.count == 2)

    let submit2 = PendingCall { try await controller.submitPairingCode("A1B2C3") }
    try await Task.sleep(for: .milliseconds(20))
    pairing.fire(.paired)
    let device = await expectSucceeds(submit2, "second submitPairingCode")
    #expect(device == paired)
}

/// A double-tap on Submit must not overwrite (and strand) the first call's
/// continuation, nor send the code twice.
@MainActor
@Test func secondSubmitWhileOneIsInFlightThrows() async throws {
    let (controller, pairing, _) = makeController()
    pairing.asyncEvents = true
    let begin = PendingCall { try await controller.beginPairing(with: tv) }
    try await Task.sleep(for: .milliseconds(20))
    pairing.fire(.codeDisplayed)
    await expectSucceeds(begin, "beginPairing")

    let first = PendingCall { try await controller.submitPairingCode("A1B2C3") }
    try await Task.sleep(for: .milliseconds(20))
    let second = PendingCall { try await controller.submitPairingCode("A1B2C3") }
    await expectThrows(second, .cancelled, "second submitPairingCode")
    #expect(pairing.sentCodes == ["A1B2C3"])     // sent once

    pairing.fire(.paired)
    let device = await expectSucceeds(first, "first submitPairingCode")
    #expect(device == paired)
}

/// Pairing is NOT connecting. `MockTVController.submitPairingCode` flips itself
/// to `.connected`, which masked a shipped bug: the real controller finishes the
/// pairing round and opens no control session at all, so the app layer must call
/// `connect(to:)` after `onPaired` or the remote is dead on arrival — every key
/// press no-ops, because `attemptReconnect` has no `connectedDevice` to retry.
@MainActor
@Test func submitPairingCodeDoesNotConnectByItself() async throws {
    let (controller, pairing, control) = makeController()
    pairing.asyncEvents = true
    let begin = PendingCall { try await controller.beginPairing(with: tv) }
    try await Task.sleep(for: .milliseconds(20))
    pairing.fire(.codeDisplayed)
    await expectSucceeds(begin, "beginPairing")

    let submit = PendingCall { try await controller.submitPairingCode("A1B2C3") }
    try await Task.sleep(for: .milliseconds(20))
    pairing.fire(.paired)
    let device = await expectSucceeds(submit, "submitPairingCode")
    #expect(device == paired)

    #expect(controller.connectionState == .disconnected)
    #expect(control.sessions.isEmpty)              // no control session was opened

    // And nothing recovers on its own: a key press cannot bootstrap a
    // connection, because pairing never recorded a device to connect to.
    controller.sendKey(.ok)
    try await Task.sleep(for: .milliseconds(50))
    #expect(control.connectedHosts.isEmpty)
    #expect(control.sentKeys.isEmpty)
    #expect(controller.connectionState == .disconnected)

    // The app's contract: an explicit connect after pairing is what works.
    let connect = PendingCall { try await controller.connect(to: paired) }
    try await Task.sleep(for: .milliseconds(20))
    control.fire(.connected)
    await expectSucceeds(connect, "connect after pairing")
    #expect(controller.connectionState == .connected)
}

@MainActor
@Test func cancelPairingResumesBeginWithCancelled() async throws {
    let (controller, pairing, _) = makeController()
    async let begin: Void = controller.beginPairing(with: tv)
    try await Task.sleep(for: .milliseconds(20))
    controller.cancelPairing()
    do {
        try await begin
        Issue.record("expected beginPairing to throw .cancelled")
    } catch {
        #expect(error as? TVControllerError == .cancelled)
    }
    #expect(pairing.cancelled)
}

// MARK: - Control

@MainActor
@Test func connectPublishesStatesAndSendsKeys() async throws {
    let (controller, _, control) = makeController()
    async let connect: Void = controller.connect(to: paired)
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.connectionState == .connecting)
    control.fire(.connected)
    try await connect
    #expect(controller.connectionState == .connected)
    controller.sendKey(.ok)
    #expect(control.sentKeys == [.ok])
}

@MainActor
@Test func dropMovesToDisconnected() async throws {
    let (controller, _, control) = makeController()
    async let connect: Void = controller.connect(to: paired)
    try await Task.sleep(for: .milliseconds(20))
    control.fire(.connected)
    try await connect
    control.fire(.dropped(nil))
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.connectionState == .disconnected)
}

/// The TV sleeps (or the socket closes) right after the handshake: `.connected`
/// and `.dropped` both land before the awaiting connect task runs again. The
/// controller must end up .disconnected — reporting .connected on a dead socket
/// would swallow every later key press and never reconnect.
@MainActor
@Test func dropRightAfterConnectedLeavesDisconnected() async throws {
    let (controller, _, control) = makeController()
    control.asyncEvents = true                       // real sessions hop via Task { @MainActor }
    let connect = PendingCall { try await controller.connect(to: paired) }
    try await Task.sleep(for: .milliseconds(20))
    control.fire(.connected)
    control.fire(.dropped(.connectionFailed("socket closed")))
    _ = await connect.settled()
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.connectionState == .disconnected)
}

/// The library's `disconnect()` nils its state handler before cancelling, so no
/// further event can ever arrive: the controller itself must resume whoever is
/// awaiting the connect, or that caller (and its task, and self) leaks forever.
@MainActor
@Test func disconnectWhileConnectingResumesTheAwaitingConnect() async throws {
    let (controller, _, control) = makeController()
    control.asyncEvents = true
    let connect = PendingCall { try await controller.connect(to: paired) }
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.connectionState == .connecting)

    controller.disconnect()                          // emits no event, by design

    await expectThrows(connect, .cancelled, "connect(to:) after disconnect()")
    #expect(control.disconnected)
    #expect(controller.connectionState == .disconnected)
}

/// A second connect must not overwrite the first one's continuation — that
/// stranded caller could never be resumed by anything.
@MainActor
@Test func secondConnectWhileOneIsInFlightThrows() async throws {
    let (controller, _, control) = makeController()
    control.asyncEvents = true
    let first = PendingCall { try await controller.connect(to: paired) }
    try await Task.sleep(for: .milliseconds(20))

    let second = PendingCall { try await controller.connect(to: movedTV) }
    await expectThrows(second, .connectionFailed("connect already in flight"), "overlapping connect")
    #expect(control.connectedHosts == ["192.168.31.24"])   // first session untouched
    #expect(control.sessions.count == 1)

    control.fire(.connected)
    await expectSucceeds(first, "first connect")
    #expect(controller.connectionState == .connected)
}

/// The controller clears a session's `onEvent` before dropping it, so a session
/// it no longer owns cannot move the published state.
@MainActor
@Test func eventsFromAReplacedSessionAreIgnored() async throws {
    let (controller, _, control) = makeController()
    control.asyncEvents = true
    let connect = PendingCall { try await controller.connect(to: paired) }
    try await Task.sleep(for: .milliseconds(20))
    control.fire(.connected)
    await expectSucceeds(connect, "connect")
    let firstSession = control.sessions[0]

    controller.disconnect()
    firstSession.fire(.connected)                    // stale session shouting into the void
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.connectionState == .disconnected)
}

@MainActor
@Test func sendKeyWhileDisconnectedTriggersOneReconnect() async throws {
    let (controller, _, control) = makeController()
    async let connect: Void = controller.connect(to: paired)
    try await Task.sleep(for: .milliseconds(20))
    control.fire(.connected)
    try await connect
    control.fire(.dropped(nil))
    try await Task.sleep(for: .milliseconds(20))
    controller.sendKey(.up)                      // swallowed, but kicks reconnect
    try await Task.sleep(for: .milliseconds(20))
    #expect(control.connectedHosts.count == 2)   // initial + reconnect
    controller.sendKey(.down)                    // still connecting: no third attempt
    try await Task.sleep(for: .milliseconds(20))
    #expect(control.connectedHosts.count == 2)
}

/// `sendText` is gated on `.connected` and, unlike `sendKey`, does NOT kick a
/// reconnect — text typed at a dead socket is dropped, not queued.
@MainActor
@Test func sendTextOnlyReachesTheTVWhileConnected() async throws {
    let (controller, _, control) = makeController()

    controller.sendText("before")                    // disconnected
    #expect(control.sentTexts.isEmpty)
    #expect(control.sessions.isEmpty)                // and no reconnect was kicked

    let connect = PendingCall { try await controller.connect(to: paired) }
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.connectionState == .connecting)
    controller.sendText("during")                    // connecting: still gated
    #expect(control.sentTexts.isEmpty)

    control.fire(.connected)
    await expectSucceeds(connect, "connect")
    controller.sendText("hello")
    #expect(control.sentTexts == ["hello"])

    controller.disconnect()
    controller.sendText("after")
    #expect(control.sentTexts == ["hello"])
}

// MARK: - IME (text field)

/// The read direction end to end: decoded IME messages arrive on the session,
/// pass through the controller's `ImeChannel`, and land on the published
/// `focusedTextField` the views observe. An app change means focus is gone —
/// writes are impossible then, and the UI must be told.
@MainActor
@Test func imeMessagesFlowIntoFocusedTextField() async throws {
    let (controller, control) = try await makeConnectedController()
    let session = try #require(control.sessions.last)

    let status = TextFieldStatus(counter: 7, value: "", selectionStart: 0, selectionEnd: 0,
                                 hint: "Пошук", packageName: "com.internet.tvbrowser")
    session.onImeMessage?(.fieldStatus(status))
    #expect(controller.focusedTextField == status)

    session.onImeMessage?(.appChanged(packageName: "com.netflix.ninja"))
    #expect(controller.focusedTextField == nil)
}

/// The write direction's first byte on the wire: `setText` must not send a bare
/// batch edit (the TV ignores those) but the show-request that opens the
/// handshake, echoing the focused field's status counter.
@MainActor
@Test func setTextSendsTheHandshakeOpenerThroughTheSession() async throws {
    let (controller, control) = try await makeConnectedController()
    let session = try #require(control.sessions.last)

    let status = TextFieldStatus(counter: 85, value: "", selectionStart: 0, selectionEnd: 0,
                                 hint: "", packageName: "app")
    session.onImeMessage?(.fieldStatus(status))
    controller.setText("hello")
    // The channel writes from its own task; the opener goes out before its
    // first suspension, so yielding is enough — no sleep-and-hope.
    for _ in 0..<50 where control.sentRaw.isEmpty { await Task.yield() }
    #expect(control.sentRaw.first == ImeEncoder.showRequest(statusCounter: 85))

    // Stop the handshake's reply poll (real 150ms sleeps) from outliving the
    // test: no TV is going to answer it here.
    controller.disconnect()
}

/// Focus belongs to a session. Losing the session must clear it, or the
/// keyboard UI would offer to type into a field that no longer exists.
@MainActor
@Test func disconnectClearsTheFocusedField() async throws {
    let (controller, control) = try await makeConnectedController()
    let session = try #require(control.sessions.last)
    session.onImeMessage?(.fieldStatus(TextFieldStatus(
        counter: 1, value: "x", selectionStart: 1, selectionEnd: 1, hint: "", packageName: "app")))
    #expect(controller.focusedTextField != nil)

    controller.disconnect()
    #expect(controller.focusedTextField == nil)
}

/// A dropped socket is the other way a session dies, and it must clear focus
/// just as `disconnect()` does — the drop path is the one the TV actually
/// takes when it sleeps mid-session.
@MainActor
@Test func aDroppedSessionClearsTheFocusedField() async throws {
    let (controller, control) = try await makeConnectedController()
    let session = try #require(control.sessions.last)
    session.onImeMessage?(.fieldStatus(TextFieldStatus(
        counter: 1, value: "x", selectionStart: 1, selectionEnd: 1, hint: "", packageName: "app")))
    #expect(controller.focusedTextField != nil)

    control.fire(.dropped(.connectionFailed("socket closed")))
    #expect(controller.focusedTextField == nil)
}

/// `setText` is gated on `.connected` exactly like `sendText`: text aimed at a
/// dead socket is dropped, not queued, and kicks no reconnect.
@MainActor
@Test func setTextWhileDisconnectedSendsNothing() async throws {
    let (controller, _, control) = makeController()
    controller.setText("hello")
    #expect(control.sentRaw.isEmpty)
    #expect(control.sessions.isEmpty)
}

// MARK: - Search

/// YouTube draws a PRIVATE on-screen keyboard — while typing in it the TV emits
/// zero IME traffic, so its search box can never be written through the
/// protocol. The search deep link is the whole route, and it is real-TV-verified
/// with Cyrillic: the query must reach the TV percent-encoded, spaces as %20.
@MainActor
@Test func youtubeSearchSendsThePercentEncodedDeepLink() async throws {
    let (controller, control) = try await makeConnectedController()
    controller.search("йога уроки", target: .youtube)
    #expect(control.sentDeepLinks ==
        ["https://www.youtube.com/results?search_query=%D0%B9%D0%BE%D0%B3%D0%B0%20%D1%83%D1%80%D0%BE%D0%BA%D0%B8"])
    #expect(control.sentKeys.isEmpty)   // no field needed, so nothing is opened
}

/// `.web` bypasses the TV's text field entirely (a TV field cannot be
/// submitted remotely — see docs/phase2-notes.md), going out as a Google
/// search app-link instead. Same route shape as `.youtube`, so it gets the
/// same Cyrillic coverage plus the characters that expose a "+"-for-space or
/// under-encoding bug the Cyrillic-only case wouldn't catch.
@MainActor
@Test func webSearchSendsThePercentEncodedGoogleDeepLink() async throws {
    let (controller, control) = try await makeConnectedController()
    controller.search("йога уроки", target: .web)
    #expect(control.sentDeepLinks ==
        ["https://www.google.com/search?q=%D0%B9%D0%BE%D0%B3%D0%B0%20%D1%83%D1%80%D0%BE%D0%BA%D0%B8"])
    #expect(control.sentKeys.isEmpty)   // no field needed, so nothing is opened
}

/// Closes a coverage gap the Cyrillic-only YouTube test left open: "+", "&",
/// "=" and a literal space must all be percent-encoded (space as %20, never
/// "+"), or a query containing them would corrupt the URL's query string or
/// silently truncate at the wrong character.
@MainActor
@Test func webSearchEncodesReservedAndUnsafeCharacters() async throws {
    let (controller, control) = try await makeConnectedController()
    controller.search("a+b&c=d e", target: .web)
    #expect(control.sentDeepLinks ==
        ["https://www.google.com/search?q=a%2Bb%26c%3Dd%20e"])
    #expect(control.sentKeys.isEmpty)
}

/// Like `sendText`/`setText` and unlike `sendKey`, search is gated on
/// `.connected` and kicks no reconnect — a deep link into a dead socket is
/// nothing but a lost session.
@MainActor
@Test func searchWhileDisconnectedSendsNothing() async throws {
    let (controller, _, control) = makeController()
    controller.search("stranger", target: .youtube)
    controller.search("stranger", target: .web)
    #expect(control.sentDeepLinks.isEmpty)
    #expect(control.sentKeys.isEmpty)
    #expect(control.sessions.isEmpty)
}

@MainActor
@Test func disconnectIsCleanAndFinal() async throws {
    let (controller, _, control) = makeController()
    async let connect: Void = controller.connect(to: paired)
    try await Task.sleep(for: .milliseconds(20))
    control.fire(.connected)
    try await connect
    controller.disconnect()
    #expect(control.disconnected)
    #expect(controller.connectionState == .disconnected)
}

// MARK: - write-in-flight (Task 7 fix 3)

/// The flag has to reach the views the same way `focusedTextField` does — as a
/// STORED, `@Observable`-tracked property on the controller — or SwiftUI will
/// not re-evaluate the keyboard sheet through the `any TVController`
/// existential and the mirror keeps adopting our own intermediate echo.
@MainActor
@Test func writeInFlightFlowsIntoTheControllerAndClearsOnDisconnect() async throws {
    let (controller, control) = try await makeConnectedController()
    let session = try #require(control.sessions.last)
    session.onImeMessage?(.fieldStatus(TextFieldStatus(
        counter: 85, value: "hi", selectionStart: 2, selectionEnd: 2,
        hint: "", packageName: "app")))
    #expect(controller.isWriteInFlight == false)

    controller.setText("hello")
    #expect(controller.isWriteInFlight)

    // Teardown is the other half: a channel killed mid-write must not leave
    // the flag stuck true, or the sheet would never adopt anything again.
    controller.disconnect()
    #expect(controller.isWriteInFlight == false)
    #expect(controller.focusedTextField == nil)
}

/// A dropped socket kills the session the same way `disconnect()` does, and
/// the drop path is the one a sleeping TV actually takes.
@MainActor
@Test func aDroppedSessionClearsWriteInFlight() async throws {
    let (controller, control) = try await makeConnectedController()
    let session = try #require(control.sessions.last)
    session.onImeMessage?(.fieldStatus(TextFieldStatus(
        counter: 85, value: "hi", selectionStart: 2, selectionEnd: 2,
        hint: "", packageName: "app")))
    controller.setText("hello")
    #expect(controller.isWriteInFlight)

    control.fire(.dropped(.connectionFailed("socket closed")))
    #expect(controller.isWriteInFlight == false)
    #expect(controller.focusedTextField == nil)
}

// MARK: - Held direction (pointer glide)
//
// The failure these guard against is not a wrong pixel — it is a key left
// DOWN. Android auto-repeats a held D-pad key, so a leaked START_LONG leaves
// the TV scrolling by itself with nothing in the app able to stop it. Every
// test below is therefore about a release: that one happens, that it happens
// BEFORE the hold that displaced it, and that no teardown path skips it.

@MainActor
@Test func changingDirectionReleasesTheOldKeyBeforeHoldingTheNew() async throws {
    let (controller, control) = try await makeConnectedController()
    controller.setHeldDirection(.right)
    controller.setHeldDirection(.up)
    // The ORDER is the point: hold-then-release would mean both keys were
    // down at once, and a release arriving after the new hold could race it.
    #expect(control.holdEvents == [.hold(.right), .release(.right), .hold(.up)])
}

@MainActor
@Test func fingerUpReleasesTheHeldKey() async throws {
    let (controller, control) = try await makeConnectedController()
    controller.setHeldDirection(.left)
    controller.setHeldDirection(nil)
    #expect(control.holdEvents == [.hold(.left), .release(.left)])
}

@MainActor
@Test func settingTheSameDirectionTwiceSendsNothingExtra() async throws {
    let (controller, control) = try await makeConnectedController()
    controller.setHeldDirection(.down)
    controller.setHeldDirection(.down)
    controller.setHeldDirection(.down)
    // A drag calls this on every gesture update — dozens of times a second.
    // Re-sending START_LONG each time would flood the socket, which is what
    // closes the control session on real hardware.
    #expect(control.holdEvents == [.hold(.down)])
}

@MainActor
@Test func disconnectReleasesTheHeldKey() async throws {
    let (controller, control) = try await makeConnectedController()
    controller.setHeldDirection(.right)
    controller.disconnect()
    #expect(control.holdEvents == [.hold(.right), .release(.right)])
    // And the release rode the session that pressed the key, not a later one:
    // it lands before the session is dropped.
    #expect(control.disconnected)
}

@MainActor
@Test func aDroppedSessionReleasesTheHeldKey() async throws {
    let (controller, control) = try await makeConnectedController()
    controller.setHeldDirection(.up)
    control.fire(.dropped(.connectionFailed("socket closed")))
    #expect(control.holdEvents == [.hold(.up), .release(.up)])
    // The socket is gone so the release may not land — but the controller's
    // own state must be clear, or the next session would inherit a phantom
    // hold and silently refuse to press .up ever again.
    controller.setHeldDirection(nil)
    #expect(control.holdEvents == [.hold(.up), .release(.up)])
}

@MainActor
@Test func reconnectingReleasesAKeyHeldOnTheOldSession() async throws {
    let (controller, control) = try await makeConnectedController()
    controller.setHeldDirection(.left)
    async let reconnect: Void = controller.connect(to: paired)
    try await Task.sleep(for: .milliseconds(20))
    control.fire(.connected)
    try await reconnect
    #expect(control.holdEvents == [.hold(.left), .release(.left)])
    #expect(control.sessions.count == 2)
}

@MainActor
@Test func holdingWhileDisconnectedSendsNothing() async throws {
    let (controller, _, control) = makeController()
    controller.setHeldDirection(.right)
    #expect(control.holdEvents.isEmpty)
    // And releasing a hold that never happened is silent too — not a stray
    // END_LONG for a key the TV never saw go down.
    controller.setHeldDirection(nil)
    #expect(control.holdEvents.isEmpty)
}

@MainActor
@Test func nonDirectionalKeysAreIgnoredAndDoNotDisturbAHeldKey() async throws {
    let (controller, control) = try await makeConnectedController()
    controller.setHeldDirection(.right)
    // .ok is a caller bug. Ignoring it (rather than treating it as a release)
    // keeps the bug visible instead of silently ending the user's glide.
    controller.setHeldDirection(.ok)
    controller.setHeldDirection(.home)
    #expect(control.holdEvents == [.hold(.right)])
    controller.setHeldDirection(nil)
    #expect(control.holdEvents == [.hold(.right), .release(.right)])
}
