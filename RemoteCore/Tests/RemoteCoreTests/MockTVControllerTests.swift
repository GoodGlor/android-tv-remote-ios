import Testing
@testable import RemoteCore

@MainActor
@Test func discoveryPopulatesAfterStart() async throws {
    let controller = MockTVController(delay: .zero)
    controller.startDiscovery()
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.discoveredDevices.count == 2)
    #expect(controller.discoveredDevices.first?.name == "Xiaomi TV P1e 32")
}

@MainActor
@Test func fullPairingFlowReturnsPairedDevice() async throws {
    let controller = MockTVController(delay: .zero)
    let device = DiscoveredDevice(name: "Xiaomi TV P1e 32", host: "192.168.31.24", serviceName: "Xiaomi TV P1e 32")
    try await controller.beginPairing(with: device)
    let paired = try await controller.submitPairingCode("A1B2C3")
    #expect(paired == PairedDevice(name: "Xiaomi TV P1e 32", host: "192.168.31.24", serviceName: "Xiaomi TV P1e 32"))
    #expect(controller.connectionState == .connected)
}

@MainActor
@Test func nonHexCodeThrowsWrongCode() async throws {
    let controller = MockTVController(delay: .zero)
    let device = DiscoveredDevice(name: "TV", host: "10.0.0.2", serviceName: "TV")
    try await controller.beginPairing(with: device)
    await #expect(throws: TVControllerError.wrongCode) {
        _ = try await controller.submitPairingCode("XYZ!!!")
    }
    #expect(controller.connectionState == .disconnected)
}

@MainActor
@Test func submitWithoutBeginThrowsCancelled() async {
    let controller = MockTVController(delay: .zero)
    await #expect(throws: TVControllerError.cancelled) {
        _ = try await controller.submitPairingCode("A1B2C3")
    }
}

@MainActor
@Test func disconnectResetsState() async throws {
    let controller = MockTVController(delay: .zero)
    try await controller.connect(to: PairedDevice(name: "TV", host: "10.0.0.2", serviceName: "TV"))
    #expect(controller.connectionState == .connected)
    controller.disconnect()
    #expect(controller.connectionState == .disconnected)
}

/// Mock honesty (the Phase 2 lesson, inverted): the real `AndroidTVController`
/// clears `focusedTextField` on `disconnect()` (see
/// `disconnectClearsTheFocusedField` in AndroidTVControllerTests), so a mock
/// that kept reporting a live field after disconnect would make a preview or
/// test built on it show the keyboard tile lit when the TV is gone.
@MainActor
@Test func mockDisconnectClearsTheFocusedField() async throws {
    let controller = MockTVController(delay: .zero)
    try await controller.connect(to: PairedDevice(name: "TV", host: "10.0.0.2", serviceName: "TV"))
    controller.focusTextField(TextFieldStatus(
        counter: 1, value: "x", selectionStart: 1, selectionEnd: 1, hint: "", packageName: "app"))
    #expect(controller.focusedTextField != nil)

    controller.disconnect()
    #expect(controller.focusedTextField == nil)
}

@MainActor
@Test func keysAndTextAreLoggedOnlyWhileConnected() async throws {
    let controller = MockTVController(delay: .zero)
    controller.sendKey(.up)
    controller.sendText("dropped")
    #expect(controller.sentKeys.isEmpty)
    #expect(controller.sentText.isEmpty)
    try await controller.connect(to: PairedDevice(name: "TV", host: "10.0.0.2", serviceName: "TV"))
    controller.sendKey(.ok)
    controller.sendText("hello")
    #expect(controller.sentKeys == [.ok])
    #expect(controller.sentText == "hello")
}

/// Mock honesty: the real TV accepts an IME write only into a field it has
/// reported as focused (with its keyboard open). A mock that accepted writes
/// unconditionally would let the keyboard UI pass tests against behavior the
/// TV does not have.
@MainActor
@Test func mockSetTextRequiresAFocusedFieldLikeTheRealTV() {
    let mock = MockTVController(delay: .zero)
    mock.setText("hello")                       // no field focused → must be dropped
    #expect(mock.lastSetText == nil)
    mock.focusTextField(TextFieldStatus(counter: 1, value: "", selectionStart: 0,
                                        selectionEnd: 0, hint: "Пошук", packageName: "browser"))
    mock.setText("hello")
    #expect(mock.lastSetText == "hello")
    #expect(mock.focusedTextField?.value == "hello")
}

/// Mock honesty again: the real transport gates `search` on `.connected`, so
/// the mock must record nothing before the connection exists.
@MainActor
@Test func mockRecordsSearchesOnlyWhileConnected() async throws {
    let mock = MockTVController(delay: .zero)
    mock.search("early", target: .youtube)
    #expect(mock.sentSearches.isEmpty)

    try await mock.connect(to: PairedDevice(name: "TV", host: "10.0.0.2", serviceName: "TV"))
    mock.search("йога", target: .youtube)
    mock.search("stranger", target: .web)
    #expect(mock.sentSearches == [
        MockTVController.SentSearch(query: "йога", target: .youtube),
        MockTVController.SentSearch(query: "stranger", target: .web),
    ])
}

/// Mock honesty (Task 7 fix 3): the real controller reports `isWriteInFlight`
/// true only while one of ITS writes is unsettled — the window in which the TV
/// echoes our own intermediate empty field — and false at every other moment.
///
/// The mock's write is ATOMIC: `setText` publishes exactly one status, the
/// final one, with no intermediate in between. There is therefore no instant at
/// which an observer of the mock could see a write in flight, and reporting
/// false throughout is the honest answer rather than a convenient one. This
/// test pins both halves: the flag never claims a write is running, AND the
/// mock never publishes the intermediate that would make that claim necessary.
@MainActor
@Test func mockReportsWriteInFlightConsistentlyWithTheRealController() async throws {
    let mock = MockTVController(delay: .zero)
    try await mock.connect(to: PairedDevice(name: "TV", host: "10.0.0.2", serviceName: "TV"))
    #expect(mock.isWriteInFlight == false)

    mock.focusTextField(TextFieldStatus(counter: 1, value: "hi", selectionStart: 2,
                                        selectionEnd: 2, hint: "", packageName: "browser"))
    mock.setText("привіт")
    // Settled the instant setText returns, and never seen empty on the way.
    #expect(mock.isWriteInFlight == false)
    #expect(mock.focusedTextField?.value == "привіт")

    // ...and cleared on teardown, like the real controller's endImeChannel().
    mock.disconnect()
    #expect(mock.isWriteInFlight == false)
}

// MARK: - Held direction
//
// Mock honesty, the Phase 2 lesson applied to the one invariant that can leave
// the user's TV scrolling by itself: every rule the real controller enforces is
// enforced here too. A mock that were more forgiving — holding while
// disconnected, or forgetting a hold on teardown — would let a UI test prove a
// release the real path never performs.

@MainActor
@Test func mockReleasesTheHeldKeyOnDisconnectLikeTheRealController() async throws {
    let mock = MockTVController(delay: .zero)
    try await mock.connect(to: PairedDevice(name: "TV", host: "10.0.0.2", serviceName: "TV"))
    mock.setHeldDirection(.right)
    #expect(mock.heldDirection == .right)

    mock.disconnect()
    #expect(mock.heldDirection == nil)
    #expect(mock.holdEvents == [.hold(.right), .release(.right)])
}

@MainActor
@Test func mockReleasesBeforeHoldingOnADirectionChange() async throws {
    let mock = MockTVController(delay: .zero)
    try await mock.connect(to: PairedDevice(name: "TV", host: "10.0.0.2", serviceName: "TV"))
    mock.setHeldDirection(.right)
    mock.setHeldDirection(.right)   // idempotent — no extra traffic
    mock.setHeldDirection(.up)
    mock.setHeldDirection(nil)
    #expect(mock.holdEvents == [.hold(.right), .release(.right), .hold(.up), .release(.up)])
}

@MainActor
@Test func mockRefusesToHoldWhileDisconnectedAndIgnoresNonDirectionalKeys() async throws {
    let mock = MockTVController(delay: .zero)
    // Not connected: the real controller sends nothing, so neither does this.
    mock.setHeldDirection(.left)
    #expect(mock.heldDirection == nil)
    #expect(mock.holdEvents.isEmpty)

    try await mock.connect(to: PairedDevice(name: "TV", host: "10.0.0.2", serviceName: "TV"))
    mock.setHeldDirection(.left)
    // A non-directional key is a caller bug — ignored, not treated as a
    // release, exactly as in AndroidTVController.
    mock.setHeldDirection(.ok)
    #expect(mock.heldDirection == .left)
    #expect(mock.holdEvents == [.hold(.left)])
}
