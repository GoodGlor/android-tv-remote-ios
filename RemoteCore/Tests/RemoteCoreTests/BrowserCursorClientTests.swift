import Foundation
import Testing
@testable import RemoteCore

@MainActor
private final class FakeSocket: CursorSocketing {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    private(set) var connectedTo: (host: String, port: UInt16)?
    private(set) var sent: [Data] = []
    private(set) var disconnectCount = 0

    func connect(host: String, port: UInt16) { connectedTo = (host, port) }
    func send(_ data: Data) { sent.append(data) }
    func disconnect() { disconnectCount += 1 }

    func open() { onOpen?() }
    func drop() { onClose?() }
    func receive(_ data: Data) { onMessage?(data) }
}

/// Real bytes captured from the TV browser server's TV→phone push channel
/// (device `desktop`, 2026-08-22) — see `docs/tvbrowser-remote-protocol.md`.
/// Envelope field 5 = `app_state`, containing field 1 (varint `foreground`)
/// and field 2 (bytes `screen`).
private enum AppStateFixtures {
    /// f5 payload = 08 01 12 07 "browser" → foreground=true, screen="browser".
    static let pageOpen = Data([
        0x2A, 0x0B, 0x08, 0x01, 0x12, 0x07, 0x62, 0x72, 0x6F, 0x77, 0x73, 0x65, 0x72,
    ])
    /// f5 payload = 08 01 12 04 "home" → foreground=true, screen="home".
    static let startScreen = Data([
        0x2A, 0x08, 0x08, 0x01, 0x12, 0x04, 0x68, 0x6F, 0x6D, 0x65,
    ])
    /// f5 payload = 12 04 "home" → foreground ABSENT (proto3 default false),
    /// screen="home". The actual "browser backgrounded" capture.
    static let backgroundedOnHome = Data([
        0x2A, 0x06, 0x12, 0x04, 0x68, 0x6F, 0x6D, 0x65,
    ])
    /// No field 5 at all — one of the several unrelated frames per burst.
    static let unrelatedFrame = Data([0x08, 0x01])
    /// Field 5 present but its payload is truncated mid length-prefix.
    static let garbage = Data([0x2A, 0x05, 0xFF, 0xFF])
    /// f5 payload = 12 07 "browser" → foreground ABSENT (proto3 default
    /// false), screen="browser". SYNTHESISED, not captured — we have never
    /// observed the TV send this exact combination. Every real fixture above
    /// leaves the `foreground` half of the availability rule untested,
    /// because both non-foreground captures (`backgroundedOnHome`) also
    /// carry `screen == "home"`, so `screen` alone already explains them.
    /// This fixture isolates "backgrounded WHILE a page is open," the one
    /// state the `foreground` check actually guards. Pins the rule, not the
    /// protocol.
    static let backgroundedWhilePageOpen = Data([
        0x2A, 0x09, 0x12, 0x07, 0x62, 0x72, 0x6F, 0x77, 0x73, 0x65, 0x72,
    ])
    /// Envelope with a top-level field BEFORE app_state: `08 01`
    /// (control_mode, field 1) then `2A 0B ...` (app_state, the same
    /// page-open payload as `pageOpen`). Real bursts carry several top-level
    /// fields per frame (see the docs' "Envelope" section) — pins that the
    /// app_state lookup locates field 5 by its field number, rather than
    /// assuming it is the first field in the envelope.
    static let appStateNotFirstField = Data([
        0x08, 0x01,
        0x2A, 0x0B, 0x08, 0x01, 0x12, 0x07, 0x62, 0x72, 0x6F, 0x77, 0x73, 0x65, 0x72,
    ])
}

@MainActor
@Test func clientIsUnavailableUntilTheSocketActuallyOpens() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    // resume() returns instantly and a dead host looks live until the
    // handshake lands — claiming availability here would show "Free cursor"
    // while every drag went nowhere.
    #expect(client.isAvailable == false)
    client.move(dx: 1, dy: 1)
    #expect(socket.sent.isEmpty)
    socket.open()
    // Availability additionally requires an app_state frame reporting a
    // usable screen (FIX 1) — the handshake alone is not enough.
    socket.receive(AppStateFixtures.pageOpen)
    #expect(client.isAvailable)
}

@MainActor
@Test func movesAreDroppedWhileUnavailable() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.move(dx: 5, dy: 5)
    client.click()
    #expect(socket.sent.isEmpty)
}

@MainActor
@Test func moveAndClickSendTheVerifiedBytes() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket.open()
    socket.receive(AppStateFixtures.pageOpen)
    client.move(dx: -6, dy: -4)
    client.click()
    #expect(socket.sent == [CursorMessages.move(dx: -6, dy: -4), CursorMessages.click()])
}

@MainActor
@Test func aDroppedSocketGoesUnavailableAndStopsSending() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket.open()
    socket.drop()
    #expect(client.isAvailable == false)
    client.move(dx: 1, dy: 1)
    #expect(socket.sent.isEmpty)
}

@MainActor
@Test func onlyTheMatchingServiceNameIsConnected() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    // beginMatching (not start(matchingServiceName:)) —
    // start(matchingServiceName:) also kicks off real NWBrowser discovery
    // and a poll loop, which a unit test must not touch. beginMatching only
    // records the target service name.
    client.beginMatching(serviceName: "desktop")
    // A different TV on the LAN — a different instance name — must never
    // receive this phone's cursor, even though it advertises the same
    // service type.
    client.considerServices([BrowserCursorService(name: "other", host: "192.168.0.55", port: 8335)])
    #expect(socket.connectedTo == nil)
    client.considerServices([BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335)])
    #expect(socket.connectedTo?.host == "192.168.0.108")
    #expect(socket.connectedTo?.port == 8335)
}

@MainActor
@Test func aServiceWhoseIPHasChangedIsStillOurTV() {
    // The real hardware bug: the stored pairing was made while the TV
    // answered on 192.168.0.103. The router has since handed it a new DHCP
    // lease and it now answers on 192.168.0.108 — a host completely
    // different from anything previously seen, matching neither .103 nor
    // any value this client has been told about before. Matching on the
    // Bonjour instance name ("desktop") rather than the IP must still find it
    // and connect to wherever it currently lives.
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.beginMatching(serviceName: "desktop")
    client.considerServices([BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335)])
    // Must have connected — using the service's CURRENT host and port, not
    // any stale address.
    #expect(socket.connectedTo?.host == "192.168.0.108")
    #expect(socket.connectedTo?.port == 8335)
}

@MainActor
@Test func stopClosesTheSocketAndReportsUnavailable() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket.open()
    client.stop()
    #expect(socket.disconnectCount == 1)
    #expect(client.isAvailable == false)
}

@MainActor
@Test func aStaleSocketsCallbacksCannotFlipAvailability() {
    var sockets: [FakeSocket] = []
    let client = BrowserCursorClient(makeSocket: {
        let socket = FakeSocket()
        sockets.append(socket)
        return socket
    })
    client.connect(to: BrowserCursorService(name: "a", host: "192.168.0.108", port: 8335))
    // Capture the closure itself, not just `sockets[0].onOpen` — the second
    // connect()'s closeSocket() will nil out `sockets[0].onOpen`, which would
    // make the test pass even without the identity guard. Grabbing the
    // reference first models the real race: an in-flight delegate callback
    // from the abandoned task, dispatched before teardown reached it.
    let staleOnOpen = sockets[0].onOpen
    client.connect(to: BrowserCursorService(name: "b", host: "192.168.0.109", port: 8335))
    // The second connect() must have torn the first socket fully down: no
    // stale socket is left installed underneath the new one.
    #expect(sockets[0].disconnectCount == 1)
    // If this late-arriving handshake from the abandoned socket is allowed to
    // flip availability, a connection nobody wants would look live.
    staleOnOpen?()
    #expect(client.isAvailable == false)
}

@MainActor
@Test func aStaleSocketsOnCloseCannotClearLiveAvailability() {
    var sockets: [FakeSocket] = []
    let client = BrowserCursorClient(makeSocket: {
        let socket = FakeSocket()
        sockets.append(socket)
        return socket
    })
    client.connect(to: BrowserCursorService(name: "a", host: "192.168.0.108", port: 8335))
    // Capture before the second connect()'s closeSocket() nils it out — same
    // technique as the onOpen test above, and for the same reason: this
    // models an in-flight close notification from the abandoned socket,
    // dispatched before teardown reached it.
    let staleOnClose = sockets[0].onClose
    client.connect(to: BrowserCursorService(name: "b", host: "192.168.0.109", port: 8335))
    sockets[1].open()
    sockets[1].receive(AppStateFixtures.pageOpen)
    #expect(client.isAvailable)
    // A late close from the stale socket must not tear down the live one.
    staleOnClose?()
    #expect(client.isAvailable)
    // The live socket (b) is still installed and still receiving sends.
    client.move(dx: 1, dy: 1)
    #expect(sockets[1].sent == [CursorMessages.move(dx: 1, dy: 1)])
}

@MainActor
@Test func aStaleSocketsOnMessageCannotFlipLiveAvailability() {
    var sockets: [FakeSocket] = []
    let client = BrowserCursorClient(makeSocket: {
        let socket = FakeSocket()
        sockets.append(socket)
        return socket
    })
    client.connect(to: BrowserCursorService(name: "a", host: "192.168.0.108", port: 8335))
    // Capture before the second connect()'s closeSocket() nils it out — same
    // technique as the onOpen/onClose tests above: this models an in-flight
    // message notification from the abandoned socket, dispatched before
    // teardown reached it.
    let staleOnMessage = sockets[0].onMessage
    client.connect(to: BrowserCursorService(name: "b", host: "192.168.0.109", port: 8335))
    // closeSocket() must tear onMessage down along with onOpen/onClose, or a
    // socket nobody wants can still feed frames into the client.
    #expect(sockets[0].onMessage == nil)

    sockets[1].open()
    sockets[1].receive(AppStateFixtures.pageOpen)
    #expect(client.isAvailable)
    // A late message from the stale socket — reporting an UNAVAILABLE
    // state — must not be allowed to affect the live connection.
    staleOnMessage?(AppStateFixtures.startScreen)
    #expect(client.isAvailable)
}

@MainActor
@Test func considerServicesLeavesAHealthySocketAloneOnRepeatedPolls() {
    // The poll loop calls considerServices every 500ms. Without the
    // `socket == nil` guard, a second call while a socket is already open
    // (even mid-handshake) would tear it down and reconnect — flapping the
    // cursor twice a second on a perfectly healthy connection.
    var sockets: [FakeSocket] = []
    let client = BrowserCursorClient(makeSocket: {
        let socket = FakeSocket()
        sockets.append(socket)
        return socket
    })
    let service = BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335)
    client.beginMatching(serviceName: "desktop")

    client.considerServices([service])
    sockets[0].open()
    client.considerServices([service])

    #expect(sockets.count == 1)
    #expect(sockets[0].disconnectCount == 0)
}

@MainActor
@Test func mockRecordsAnOrderedEventLog() {
    let mock = MockBrowserCursorClient()
    mock.setAvailable(true)
    mock.move(dx: 3, dy: -2)
    mock.click()
    #expect(mock.events == [.move(dx: 3, dy: -2), .click])
}

@MainActor
@Test func mockDropsEventsWhileUnavailableJustLikeTheRealClient() {
    // Mock honesty (the Phase 2 lesson): a mock that recorded events while
    // unavailable would let a UI test prove a send that never happens.
    let mock = MockBrowserCursorClient()
    mock.move(dx: 3, dy: -2)
    #expect(mock.events.isEmpty)
}

@MainActor
@Test func repeatedStartOnTheSameServiceNameLeavesALiveSocketAlone() {
    // The lifecycle bug: .onAppear starts, then .task starts again after
    // `await controller.connect` returns, and every scenePhase.active
    // transition starts again too (Control Centre and the app switcher fire
    // .active without ever visiting .background). Each of those is a
    // legitimate call to start(matchingServiceName:) with the SAME service
    // name while a socket is already open. Without the idempotency guard
    // this tears the live socket down and forces a fresh discovery poll +
    // handshake for no reason — the user watches "Free cursor" flap off.
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    let service = BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335)

    // Reach the "already observing" state the guard checks (`observation !=
    // nil`) through the seams, so this suite never opens a real NWBrowser —
    // no Local Network prompt, and no dependence on the machine's network.
    // The poll loop this starts is harmless: discovery was never started, so
    // it only ever sees an empty service list.
    client.beginMatching(serviceName: "desktop")
    client.beginObserving()
    // Simulate discovery having matched — the same call considerServices
    // would make once discovery reports the service, without waiting on a
    // real Bonjour resolve.
    client.connect(to: service)
    socket.open()
    socket.receive(AppStateFixtures.pageOpen)
    #expect(client.isAvailable)

    // The repeated lifecycle call: same service name, socket already live.
    client.start(matchingServiceName: "desktop")
    #expect(client.isAvailable)
    #expect(socket.disconnectCount == 0)

    client.stop()
}

@MainActor
@Test func startOnADifferentServiceNameStillTearsDownAndRestarts() {
    // The guard's other half: a genuine pairing change (a different TV
    // paired) must still stop the old socket and restart discovery, not get
    // swallowed by the idempotency check.
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    let service = BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335)

    client.start(matchingServiceName: "desktop")
    client.connect(to: service)
    socket.open()
    socket.receive(AppStateFixtures.pageOpen)
    #expect(client.isAvailable)

    client.start(matchingServiceName: "other")
    #expect(client.isAvailable == false)
    #expect(socket.disconnectCount == 1)

    client.stop()
}

// MARK: - app_state gating (FIX 1)
//
// The server keeps the socket open while the browser is merely backgrounded,
// or sitting on its own start screen — so socket-open alone is not a usable
// availability signal. These pin decoding + gating to the exact bytes
// captured on hardware; see `AppStateFixtures` and
// `docs/tvbrowser-remote-protocol.md`.

@MainActor
@Test func aPageOpenFrameMakesAnOpenSocketAvailable() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket.open()
    socket.receive(AppStateFixtures.pageOpen)
    #expect(client.isAvailable)
}

@MainActor
@Test func theStartScreenFrameLeavesAnOpenSocketUnavailable() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket.open()
    socket.receive(AppStateFixtures.startScreen)
    #expect(client.isAvailable == false)
}

@MainActor
@Test func aBackgroundedBrowserOnHomeLeavesAnOpenSocketUnavailable() {
    // foreground is ABSENT from the wire (proto3 default false), not merely
    // present-and-false — this is the actual "browser backgrounded" capture.
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket.open()
    socket.receive(AppStateFixtures.backgroundedOnHome)
    #expect(client.isAvailable == false)
}

@MainActor
@Test func aBackgroundedBrowserWithAPageOpenLeavesAnOpenSocketUnavailable() {
    // Pins the `foreground` half of the rule (see
    // AppStateFixtures.backgroundedWhilePageOpen for why the fixture above
    // cannot do this on its own). Without a real `&& foreground == true`
    // check, `screen == "browser"` alone would wrongly report available.
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket.open()
    socket.receive(AppStateFixtures.backgroundedWhilePageOpen)
    #expect(client.isAvailable == false)
}

@MainActor
@Test func appStateIsFoundEvenWhenItIsNotTheFirstTopLevelField() {
    // Pins that decodeAppState locates field 5 by number, not by position —
    // real bursts carry several top-level fields (see docs "Envelope").
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket.open()
    socket.receive(AppStateFixtures.appStateNotFirstField)
    #expect(client.isAvailable)
}

@MainActor
@Test func isAvailableStartsFalseEvenWithAnOpenSocket() {
    // Before any app_state has arrived, availability must never be assumed
    // optimistically — the whole point of this gating is that the tab must
    // never appear when the cursor cannot move.
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket.open()
    #expect(client.isAvailable == false)
}

@MainActor
@Test func aFrameWithoutAppStateLeavesPriorStateUnchanged() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket.open()
    socket.receive(AppStateFixtures.pageOpen)
    #expect(client.isAvailable)
    // The server sends several unrelated frames per burst; none of them may
    // clear the availability a real app_state frame already established.
    socket.receive(AppStateFixtures.unrelatedFrame)
    #expect(client.isAvailable)
}

@MainActor
@Test func aTruncatedOrGarbageFrameDoesNotCrashAndDoesNotFlipAvailability() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket.open()
    socket.receive(AppStateFixtures.pageOpen)
    #expect(client.isAvailable)
    socket.receive(AppStateFixtures.garbage)
    #expect(client.isAvailable)

    // Also verify garbage arriving before any real state doesn't fake one up.
    let socket2 = FakeSocket()
    let client2 = BrowserCursorClient(makeSocket: { socket2 })
    client2.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket2.open()
    socket2.receive(AppStateFixtures.garbage)
    #expect(client2.isAvailable == false)
}

@MainActor
@Test func moveAndClickSendNothingWhileTheScreenIsHome() {
    let socket = FakeSocket()
    let client = BrowserCursorClient(makeSocket: { socket })
    client.connect(to: BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335))
    socket.open()
    socket.receive(AppStateFixtures.startScreen)
    client.move(dx: 1, dy: 1)
    client.click()
    #expect(socket.sent.isEmpty)
}

@MainActor
@Test func aDropThenReconnectStartsUnavailableUntilFreshAppState() {
    // Exercises the onClose path specifically: drop() fires the socket's
    // real onClose callback, which must clear lastAppState/isAvailable
    // itself — distinct from the stop()-driven path below, which reaches
    // the same outcome via connect()'s own closeSocket() instead.
    var sockets: [FakeSocket] = []
    let client = BrowserCursorClient(makeSocket: {
        let socket = FakeSocket()
        sockets.append(socket)
        return socket
    })
    let service = BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335)
    client.connect(to: service)
    sockets[0].open()
    sockets[0].receive(AppStateFixtures.pageOpen)
    #expect(client.isAvailable)

    sockets[0].drop()
    #expect(client.isAvailable == false)

    // Reconnect without a fresh app_state must not inherit the prior
    // connection's remembered screen.
    client.connect(to: service)
    sockets[1].open()
    #expect(client.isAvailable == false)
}

@MainActor
@Test func aStopThenReconnectStartsUnavailableUntilFreshAppState() {
    // The other half: stop() (not a socket drop) tears the connection down,
    // and a subsequent connect() must equally not inherit the prior
    // connection's remembered screen. This path never fires the socket's
    // own onClose callback — stop() calls closeSocket() directly — so it is
    // deliberately kept separate from the drop() case above rather than
    // folded into one test that would obscure which teardown path is which.
    var sockets: [FakeSocket] = []
    let client = BrowserCursorClient(makeSocket: {
        let socket = FakeSocket()
        sockets.append(socket)
        return socket
    })
    let service = BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335)
    client.connect(to: service)
    sockets[0].open()
    sockets[0].receive(AppStateFixtures.pageOpen)
    #expect(client.isAvailable)

    client.stop()
    #expect(client.isAvailable == false)

    // Reconnect without a fresh app_state must not inherit the prior
    // connection's remembered screen.
    client.connect(to: service)
    sockets[1].open()
    #expect(client.isAvailable == false)
}
