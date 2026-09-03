import Foundation
import Observation

/// The real transport behind the TVController seam. Owns discovery, a pairing
/// session, and a control session; publishes connectionState for the views.
///
/// Continuation discipline (the whole file hangs on it): every stored
/// continuation is resumed exactly once and nilled in the same breath, and no
/// path may install a second continuation over a live one — a leaked
/// `CheckedContinuation` hangs its caller forever.
@MainActor
@Observable
public final class AndroidTVController: TVController {
    public private(set) var connectionState: ConnectionState = .disconnected
    /// Stored, not computed off `imeChannel`: `@Observable` only tracks stored
    /// properties, and the keyboard UI has to re-render the moment the TV
    /// reports a new field.
    public private(set) var focusedTextField: TextFieldStatus?
    /// Mirrors `ImeChannel.isWriteInFlight`. Stored for the same reason
    /// `focusedTextField` is: `@Observable` tracks stored properties only, and
    /// the keyboard sheet reads this through the `any TVController`
    /// existential — a computed passthrough to `imeChannel` would never
    /// re-render it, which is exactly the state the sheet must not miss.
    public private(set) var isWriteInFlight = false
    public var discoveredDevices: [DiscoveredDevice] { discovery.devices }
    public var discoveryPermissionDenied: Bool { discovery.permissionDenied }

    private let makePairing: () -> any PairingSessioning
    private let makeControl: () -> any ControlSessioning
    private let discovery: DeviceDiscovery

    private var pairingSession: (any PairingSessioning)?
    private var pairingDevice: DiscoveredDevice?
    private var beginContinuation: CheckedContinuation<Void, any Error>?
    private var submitContinuation: CheckedContinuation<Void, any Error>?

    private var controlSession: (any ControlSessioning)?
    /// Lives and dies with `controlSession`: it owns an in-flight write
    /// handshake whose bytes only mean anything on that one socket.
    private var imeChannel: ImeChannel?
    private var connectedDevice: PairedDevice?
    private var connectContinuation: CheckedContinuation<Void, any Error>?
    private var reconnectAllowed = true
    /// The one direction key currently held down, nil when none. Single-valued
    /// by construction: `setHeldDirection` is the only writer and it releases
    /// before it holds, so two keys can never be down at once.
    private var heldDirection: KeyCommand?

    /// `makePairing`/`makeControl` default to the production Lib sessions built
    /// from `identity`; tests inject fakes. Called without them this is the
    /// production wiring: `AndroidTVController(identity:)`.
    public init(
        identity: IdentityProvider,
        discovery: DeviceDiscovery = DeviceDiscovery(),
        makePairing: (() -> any PairingSessioning)? = nil,
        makeControl: (() -> any ControlSessioning)? = nil
    ) {
        self.discovery = discovery
        self.makePairing = makePairing ?? { LibPairingSession(identity: identity) }
        self.makeControl = makeControl ?? { LibControlSession(identity: identity) }
    }

    // MARK: Discovery

    public func startDiscovery() { discovery.start() }
    public func stopDiscovery() { discovery.stop() }

    // MARK: Pairing

    public func beginPairing(with device: DiscoveredDevice) async throws {
        cancelPairing()
        pairingDevice = device
        let session = makePairing()
        pairingSession = session
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session, self.pairingSession === session else { return }
            self.handlePairing(event)
        }
        try await withCheckedThrowingContinuation { continuation in
            beginContinuation = continuation
            session.start(host: device.host)
        }
    }

    public func submitPairingCode(_ code: String) async throws -> PairedDevice {
        // A double-tap on Submit must not overwrite (and leak) the first
        // call's continuation, nor send the code twice.
        guard submitContinuation == nil else { throw TVControllerError.cancelled }
        // A failed pairing round tears the session down (see handlePairing):
        // retrying then fails fast here instead of sending into a dead socket
        // and waiting for an event that can never arrive.
        guard let session = pairingSession, let device = pairingDevice else {
            throw TVControllerError.cancelled
        }
        try await withCheckedThrowingContinuation { continuation in
            submitContinuation = continuation
            session.sendCode(code)
        }
        endPairingSession()
        return PairedDevice(name: device.name, host: device.host, serviceName: device.serviceName)
    }

    public func cancelPairing() {
        endPairingSession()
        beginContinuation?.resume(throwing: TVControllerError.cancelled)
        beginContinuation = nil
        submitContinuation?.resume(throwing: TVControllerError.cancelled)
        submitContinuation = nil
    }

    /// Drops the pairing session for good. Clearing `onEvent` first means a
    /// session we no longer own can never call back into us — we do not want
    /// that safety to rest on the library nilling its own state handler.
    private func endPairingSession() {
        pairingSession?.onEvent = nil
        pairingSession?.cancel()
        pairingSession = nil
        pairingDevice = nil
    }

    private func handlePairing(_ event: PairingEvent) {
        switch event {
        case .codeDisplayed:
            beginContinuation?.resume()
            beginContinuation = nil
        case .paired:
            submitContinuation?.resume()
            submitContinuation = nil
        case .failed(let error):
            beginContinuation?.resume(throwing: error)
            beginContinuation = nil
            submitContinuation?.resume(throwing: error)
            submitContinuation = nil
            // The library closes the socket on a rejected secret
            // (`PairingManager.receive()`: `.error(.secretNotSuccess)` then
            // `disconnect()`), and every other failure leaves its state
            // machine wedged. Retrying on this session could only hang, so
            // the session dies here: a retry means a fresh `beginPairing`,
            // which makes the TV display a code again whether or not it kept
            // showing the old one.
            endPairingSession()
        }
    }

    // MARK: Control

    public func connect(to device: PairedDevice) async throws {
        // A second connect must never install its continuation over a live
        // one — the first caller would await an event that is now routed to a
        // session it does not own. (Reachable: a key press during the up-to-5s
        // re-resolve inside attemptReconnect.)
        guard connectContinuation == nil else {
            throw TVControllerError.connectionFailed("connect already in flight")
        }
        // Before the old session is torn down: the release has to travel on
        // the socket the hold travelled on. A key held on the session we are
        // about to drop would otherwise stay down on the TV forever — the new
        // session has no idea it exists.
        releaseHeldDirection()
        controlSession?.onEvent = nil
        controlSession?.onImeMessage = nil
        controlSession?.disconnect()
        // Before the new channel exists, so the old one's teardown (which
        // publishes focus-lost) cannot clobber the new one's first field.
        endImeChannel()
        connectedDevice = device
        connectionState = .connecting
        let session = makeControl()
        controlSession = session
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session, self.controlSession === session else { return }
            self.handleControl(event)
        }
        // The IME channel is per-session: it sends through this session only,
        // and this session's decoded messages drive it. Both directions are
        // weak — a channel outliving its controller (its write task can) must
        // not keep either alive.
        let channel = ImeChannel(send: { [weak session] in session?.sendRaw($0) })
        channel.onFieldChanged = { [weak self] field in
            self?.focusedTextField = field
        }
        channel.onWriteInFlightChanged = { [weak self] inFlight in
            self?.isWriteInFlight = inFlight
        }
        session.onImeMessage = { [weak channel] in channel?.handle($0) }
        imeChannel = channel
        do {
            try await withCheckedThrowingContinuation { continuation in
                connectContinuation = continuation
                session.connect(host: device.host)
            }
        } catch {
            // Only our own session's failure may move the published state: a
            // disconnect() or a newer connect() has already published its own.
            if controlSession === session { connectionState = .disconnected }
            throw error
        }
        // Deliberately no `connectionState = .connected` here.
        // handleControl(.connected) already published it. Events reach us
        // through a `Task { @MainActor }` hop, so a `.dropped` can land
        // between the resume and this line; re-publishing .connected would
        // strand the controller on a dead socket forever.
    }

    public func disconnect() {
        // Resume any in-flight connect first: the library's disconnect() nils
        // its state handler *before* cancelling the socket, so no further
        // ControlEvent will ever arrive to resume it.
        connectContinuation?.resume(throwing: TVControllerError.cancelled)
        connectContinuation = nil
        // Before the socket goes: same reason as in connect(to:) — the TV only
        // learns the key is up if the release rides the session that pressed
        // it. This also covers app backgrounding, which routes through here.
        releaseHeldDirection()
        controlSession?.onEvent = nil
        controlSession?.onImeMessage = nil
        controlSession?.disconnect()
        controlSession = nil
        endImeChannel()
        connectedDevice = nil
        connectionState = .disconnected
    }

    /// Kills the IME channel and the focus it published. Called wherever the
    /// control session dies, because focus is a property of that session: a
    /// surviving channel would keep polling for a handshake reply that can
    /// never come, and the UI would go on offering to type into a field the
    /// TV no longer has.
    private func endImeChannel() {
        // Detach first: `reset()` publishes focus-lost, and on the connect
        // path a newer channel already owns `focusedTextField`.
        imeChannel?.onFieldChanged = nil
        imeChannel?.onWriteInFlightChanged = nil
        imeChannel?.reset()
        imeChannel = nil
        focusedTextField = nil
        // Same reason as the line above: a channel killed mid-write would
        // otherwise leave the flag stuck true, and the sheet — which skips
        // adoption while it is — would never adopt a TV-side edit again.
        isWriteInFlight = false
    }

    public func sendKey(_ key: KeyCommand) {
        switch connectionState {
        case .connected:
            controlSession?.sendKey(key)
        case .disconnected:
            attemptReconnect()
        case .connecting:
            break
        }
    }

    /// See `TVController.setHeldDirection(_:)`. Unlike `sendKey`, a failed
    /// hold kicks NO reconnect: a glide is only meaningful against the session
    /// the user is looking at, and reconnecting mid-drag would start a hold
    /// the finger-up of this drag has already been dispatched for.
    public func setHeldDirection(_ key: KeyCommand?) {
        // A non-directional key is a caller bug, and treating it as a release
        // would quietly paper over it. nil — and only nil — means release.
        if let key, !key.isDirectional { return }
        guard key != heldDirection else { return }
        releaseHeldDirection()
        // New holds need a live session; a release does not (below).
        guard let key, connectionState == .connected, let session = controlSession else { return }
        session.holdKey(key)
        heldDirection = key
    }

    /// Ends the current hold, if any. Deliberately NOT gated on
    /// `connectionState`: best-effort into a half-dead session is strictly
    /// better than skipping the release, because the failure mode of a missed
    /// release is a TV that scrolls by itself until the user power-cycles it.
    /// Clearing `heldDirection` first means even a session that has already
    /// gone away leaves our own state consistent.
    private func releaseHeldDirection() {
        guard let held = heldDirection else { return }
        heldDirection = nil
        controlSession?.releaseKey(held)
    }

    public func sendText(_ text: String) {
        guard connectionState == .connected else { return }
        controlSession?.sendText(text)
    }

    /// Unlike `sendKey`, this does NOT kick a reconnect: the write is only
    /// meaningful against the field the TV has focused *right now*, and that
    /// focus does not survive the drop.
    public func setText(_ text: String) {
        guard connectionState == .connected else { return }
        imeChannel?.setText(text)
    }

    // MARK: Search

    /// Gated on `.connected` like `sendText`/`setText`: an app-link message
    /// sent into a half-dead session buys nothing, and unlike `sendKey` this
    /// kicks no reconnect — the user asked THIS session to search.
    public func search(_ query: String, target: SearchTarget) {
        guard connectionState == .connected else { return }
        let encoded = Self.percentEncodeQuery(query)
        switch target {
        case .youtube:
            controlSession?.sendDeepLink("https://www.youtube.com/results?search_query=\(encoded)")
        case .web:
            controlSession?.sendDeepLink("https://www.google.com/search?q=\(encoded)")
        }
    }

    /// RFC 3986 unreserved — encode everything else, spaces included (as
    /// %20, not "+"): verified to work with Cyrillic queries. Shared by
    /// `.youtube` and `.web`, which differ only in the URL template.
    private static func percentEncodeQuery(_ query: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
    }

    private func handleControl(_ event: ControlEvent) {
        switch event {
        case .connected:
            // Published here, not after the await in connect(to:), so a
            // .dropped arriving straight after has the last word.
            connectionState = .connected
            reconnectAllowed = true
            connectContinuation?.resume()
            connectContinuation = nil
        case .dropped(let error):
            if let continuation = connectContinuation {
                continuation.resume(throwing: error ?? TVControllerError.connectionFailed("dropped"))
                connectContinuation = nil
            }
            connectionState = .disconnected
            // The socket is gone, so the release may well not land — but the
            // attempt costs nothing and our own "what is held" state MUST be
            // cleared, or the next session would inherit a phantom hold and
            // refuse to press that direction again (setHeldDirection would
            // see it as already held and no-op).
            releaseHeldDirection()
            // The socket is gone, and with it any hope of the handshake reply
            // an in-flight write is polling for. Same teardown as an explicit
            // disconnect: the reconnect path builds a fresh channel.
            endImeChannel()
            // Re-arm: each fresh drop deserves its own single reconnect
            // attempt. Without this, a reconnect attempt that itself fails
            // would leave `reconnectAllowed` false forever — silently
            // dropping every subsequent key press for the app's lifetime.
            reconnectAllowed = true
        }
    }

    /// One reconnect per drop; a fresh drop re-arms it. On stale-IP failure,
    /// re-resolve the Bonjour service name once.
    private func attemptReconnect() {
        guard reconnectAllowed, let device = connectedDevice else { return }
        reconnectAllowed = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await connect(to: device)
            } catch {
                guard connectedDevice != nil, connectionState == .disconnected else { return }
                if let host = await DeviceDiscovery.resolveHost(serviceName: device.serviceName),
                   host != device.host {
                    // resolveHost can take seconds. A disconnect() (or a
                    // connection established by another key press) in that
                    // window must not be resurrected here.
                    guard connectedDevice != nil, connectionState == .disconnected else { return }
                    let moved = PairedDevice(name: device.name, host: host, serviceName: device.serviceName)
                    try? await connect(to: moved)
                }
            }
        }
    }
}
