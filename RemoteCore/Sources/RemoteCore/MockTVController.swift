import Observation

/// Stand-in transport for previews and tests: instant fake discovery, accepts
/// any 6-hex-digit code, records every command.
@MainActor
@Observable
public final class MockTVController: TVController {
    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var discoveredDevices: [DiscoveredDevice] = []
    public private(set) var sentKeys: [KeyCommand] = []
    public private(set) var sentText: String = ""
    public private(set) var pairingDevice: DiscoveredDevice?
    public private(set) var focusedTextField: TextFieldStatus?
    public private(set) var lastSetText: String?
    /// Mock honesty (the Phase 2 lesson): the real transport reports this true
    /// only while one of its writes is unsettled — the window in which the TV
    /// echoes our own intermediate empty field. The mock's `setText` is ATOMIC:
    /// it publishes exactly one status, the final one, with no intermediate in
    /// between and no suspension point anywhere in the write. There is
    /// therefore no instant at which an observer of the mock could see a write
    /// in flight, and false at every observable moment is the honest answer —
    /// not a convenient one. Faking a true here would let the keyboard UI pass
    /// tests against a sequence the mock never actually produces.
    public private(set) var isWriteInFlight = false
    /// The direction key currently held down, nil when none.
    public private(set) var heldDirection: KeyCommand?
    /// Every hold and release in order. Ordered because the invariant worth
    /// testing is an ORDER: the old direction comes up before the new one
    /// goes down, and nothing is ever left down.
    public private(set) var holdEvents: [KeyHoldEvent] = []
    /// A struct rather than a tuple: tuples aren't Equatable, so an array of
    /// them can't be compared in a single `#expect`.
    public struct SentSearch: Equatable, Sendable {
        public let query: String
        public let target: SearchTarget

        public init(query: String, target: SearchTarget) {
            self.query = query
            self.target = target
        }
    }
    public private(set) var sentSearches: [SentSearch] = []

    private let delay: Duration
    private var discoveryTask: Task<Void, Never>?

    public init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    public func startDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            discoveredDevices = [
                DiscoveredDevice(name: "Xiaomi TV P1e 32", host: "192.168.31.24", serviceName: "Xiaomi TV P1e 32"),
                DiscoveredDevice(name: "Mi Box S", host: "192.168.31.47", serviceName: "Mi Box S"),
            ]
        }
    }

    public func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    public func beginPairing(with device: DiscoveredDevice) async throws {
        try? await Task.sleep(for: delay)
        pairingDevice = device
    }

    public func submitPairingCode(_ code: String) async throws -> PairedDevice {
        guard let device = pairingDevice else { throw TVControllerError.cancelled }
        guard code.count == 6, code.allSatisfy(\.isHexDigit) else {
            // Matches the real transport: a rejected code ends the pairing
            // round, so a retry starts again from beginPairing.
            pairingDevice = nil
            throw TVControllerError.wrongCode
        }
        connectionState = .connecting
        try? await Task.sleep(for: delay)
        connectionState = .connected
        pairingDevice = nil
        return PairedDevice(name: device.name, host: device.host, serviceName: device.serviceName)
    }

    public func cancelPairing() {
        pairingDevice = nil
    }

    public func connect(to device: PairedDevice) async throws {
        // Mirrors the real controller's session-replacement teardown: the
        // release has to ride the session that pressed the key, so it happens
        // before the old session is replaced.
        releaseHeldDirection()
        connectionState = .connecting
        try? await Task.sleep(for: delay)
        connectionState = .connected
    }

    public func disconnect() {
        // First, exactly like AndroidTVController.disconnect(): a held key
        // must come up before the transport goes away. Mirrored here because
        // a mock that quietly forgot the hold would let a UI test "prove" a
        // release the real path never performs.
        releaseHeldDirection()
        connectionState = .disconnected
        // Mock honesty: the real transport clears focus on both disconnect()
        // and a dropped session (see AndroidTVController.endImeChannel()) —
        // a mock that kept reporting a live field here would make a preview
        // or test built on it show the keyboard tile lit after disconnect.
        focusedTextField = nil
        // Teardown clears it in the real controller's endImeChannel() too.
        isWriteInFlight = false
    }

    public func sendKey(_ key: KeyCommand) {
        guard connectionState == .connected else { return }
        sentKeys.append(key)
    }

    /// Mock honesty (the Phase 2 lesson — a divergent mock hid a critical bug
    /// behind 48 green tests). Every rule the real controller applies is
    /// applied here, in the same order and for the same reason: non-directional
    /// keys are ignored rather than treated as a release; the same direction
    /// twice is a no-op; a change releases before it holds; a new hold needs
    /// `.connected`; a release does NOT, because a missed release is the one
    /// failure the user cannot recover from.
    public func setHeldDirection(_ key: KeyCommand?) {
        if let key, !key.isDirectional { return }
        guard key != heldDirection else { return }
        releaseHeldDirection()
        guard let key, connectionState == .connected else { return }
        heldDirection = key
        holdEvents.append(.hold(key))
    }

    private func releaseHeldDirection() {
        guard let held = heldDirection else { return }
        heldDirection = nil
        holdEvents.append(.release(held))
    }

    public func sendText(_ text: String) {
        guard connectionState == .connected else { return }
        sentText = text
    }

    /// Mock honesty: the real transport gates this on `.connected` too.
    public func search(_ query: String, target: SearchTarget) {
        guard connectionState == .connected else { return }
        sentSearches.append(SentSearch(query: query, target: target))
    }

    /// Preview/test control: pretend the TV focused (or left) a text field.
    /// The real transport learns this from the TV; nothing in the mock can,
    /// so the caller stages it.
    public func focusTextField(_ status: TextFieldStatus?) {
        focusedTextField = status
    }

    public func setText(_ text: String) {
        // Mock honesty (Phase 2 lesson): the real TV accepts writes only for
        // a focused field with its keyboard open — the mock must not be more
        // permissive, or tests will pass against behavior the TV lacks.
        guard let field = focusedTextField else { return }
        // Kept honest rather than hardcoded: the write genuinely is in flight
        // for the length of this body, and genuinely settled when it returns.
        isWriteInFlight = true
        defer { isWriteInFlight = false }
        lastSetText = text
        // The TV echoes an accepted edit back as a new status. Counter +2
        // because the write is two edits (clear, then append), each bumping it.
        focusedTextField = TextFieldStatus(
            counter: field.counter + 2, value: text,
            selectionStart: text.count, selectionEnd: text.count,
            hint: field.hint, packageName: field.packageName)
    }
}
