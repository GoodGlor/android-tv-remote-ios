import Foundation
import Security
@preconcurrency import AndroidTVRemoteControl

/// The bundled PKCS#12 imported once and kept in memory, per the spec.
///
/// `TLSManager.getNWParams` calls `certificateProvider()` on *every* connect,
/// and the controller builds a fresh session per connect, so a memo local to
/// `makeManagers` would never be hit — the cache has to outlive the session.
/// It is read from the library's connect queue, hence the lock. Only a
/// successful import is cached, so a transient failure stays retryable.
private final class IdentityMaterial: @unchecked Sendable {
    static let shared = IdentityMaterial()

    private let lock = NSLock()
    private var imported: [String: CFArray?] = [:]

    func items(for identity: IdentityProvider) -> AndroidTVRemoteControl.Result<CFArray?> {
        let key = identity.p12URL.absoluteString
        lock.lock()
        let cached = imported[key]
        lock.unlock()
        if let cached { return .Result(cached) }

        let result = CertManager().cert(identity.p12URL, identity.password)
        if case .Result(let items) = result {
            lock.lock()
            imported[key] = items
            lock.unlock()
        }
        return result
    }
}

/// Builds the TLS/crypto managers the library needs from our bundled identity.
/// The server certificate closure is filled during the TLS handshake via
/// `secTrustClosure` — exactly the demo's wiring.
private func makeManagers(_ identity: IdentityProvider) -> (TLSManager, CryptoManager) {
    let cryptoManager = CryptoManager()
    cryptoManager.clientPublicCertificate = {
        CertManager().getSecKey(identity.publicCertURL)
    }
    let tlsManager = TLSManager {
        IdentityMaterial.shared.items(for: identity)
    }
    tlsManager.secTrustClosure = { secTrust in
        cryptoManager.serverPublicCertificate = {
            guard let key = SecTrustCopyKey(secTrust) else {
                return .Error(.secTrustCopyKeyError)
            }
            return .Result(key)
        }
    }
    return (tlsManager, cryptoManager)
}

@MainActor
public final class LibPairingSession: PairingSessioning {
    public var onEvent: ((PairingEvent) -> Void)?
    private let pairingManager: PairingManager

    public init(identity: IdentityProvider) {
        let (tlsManager, cryptoManager) = makeManagers(identity)
        pairingManager = PairingManager(tlsManager, cryptoManager)
        pairingManager.stateChanged = { [weak self] state in
            // Library queue → map synchronously → hop with a Sendable event.
            guard let event = pairingEvent(from: state) else { return }
            Task { @MainActor [weak self] in self?.onEvent?(event) }
        }
    }

    public func start(host: String) {
        // The library's default (60s) becomes the TCP connect timeout. A TV
        // that is off at the mains never answers the SYN, and 60s of "Look at
        // your TV…" with no code is not a failure the user can read.
        pairingManager.connect(host, "RemoteControl", "iPhone", timeout: 15)
    }

    public func sendCode(_ code: String) {
        pairingManager.sendSecret(code)
    }

    public func cancel() {
        pairingManager.disconnect()
    }
}

@MainActor
public final class LibControlSession: ControlSessioning {
    public var onEvent: ((ControlEvent) -> Void)?

    /// Every raw byte the TV sends, as it arrives. Debug affordance for
    /// `rc-probe dump` — the app never sets this.
    ///
    /// The library's `receiveData` hook is purely observational: it fires on
    /// its own queue and the normal `handleData()` path runs regardless, so
    /// listening here cannot disturb the session. Note these are raw TCP
    /// chunks (<=512 bytes), NOT whole messages — deframing is the caller's
    /// job, because a chunk may split or combine protocol messages.
    public var onRawData: ((Data) -> Void)?

    /// The same stream after deframing and decoding: one call per IME message
    /// the TV sends. Independent of `onRawData` — both fire, so rc-probe's
    /// byte dump keeps working while the app consumes decoded messages.
    public var onImeMessage: ((ImeMessage) -> Void)?

    private let remoteManager: RemoteManager
    /// Every outbound message goes through this, so no pair of them can
    /// leave in the same turn. See `SendPacer` for the measurements.
    private let pacer = SendPacer()

    /// Carry-over bytes between `receiveData` chunks. TCP chunks (<=512 bytes)
    /// split and combine protocol messages freely, so the deframer needs a
    /// buffer that survives the callback; `Wire.deframe` consumes whole frames
    /// and leaves the partial tail behind for the next chunk.
    private var imeBuffer: [UInt8] = []

    public init(identity: IdentityProvider) {
        let (tlsManager, _) = makeManagers(identity)
        remoteManager = RemoteManager(
            tlsManager,
            CommandNetwork.DeviceInfo("RemoteControl", "iPhone", "1.0.0", "com.example.RemoteControl", "1")
        )
        remoteManager.stateChanged = { [weak self] state in
            guard let event = controlEvent(from: state) else { return }
            Task { @MainActor [weak self] in self?.onEvent?(event) }
        }
        remoteManager.receiveData = { [weak self] data, _ in
            guard let data, !data.isEmpty else { return }
            // Fires on the library's queue; everything below (the buffer
            // included) is MainActor state, so hop first and decode there.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onRawData?(data)
                self.imeBuffer.append(contentsOf: data)
                for message in Wire.deframe(&self.imeBuffer) {
                    if let ime = ImeDecoder.decode(message) {
                        self.onImeMessage?(ime)
                    }
                }
            }
        }
    }

    public func connect(host: String) {
        // Tighter than pairing: while this is in flight the controller is
        // `.connecting`, and `sendKey` silently drops every press. Failing at
        // 8s lets `attemptReconnect` fall through to the Bonjour re-resolve
        // instead of parking the remote for a minute on a stale IP.
        remoteManager.connect(host, timeout: 8)
    }

    public func sendKey(_ key: KeyCommand) {
        if case .launchApp(let app) = key {
            pacer.send { [remoteManager] in remoteManager.send(DeepLink(KeyCodeMap.appLink(for: app))) }
        } else if let keycode = KeyCodeMap.key(for: key) {
            sendRawKeyCode(keycode.rawValue, longPress: KeyCodeMap.usesLongPress(key))
        }
    }

    // MARK: Held keys
    //
    // START_LONG … END_LONG is the protocol's key-down/key-up pair, and these
    // two methods are the ONLY place either is sent. Everything that holds a
    // key — the pointer's glide, the menu's long press of OK, rc-probe's hold
    // affordance — goes through them, so "held" means exactly one thing and
    // there is exactly one place to look when a key is stuck down.

    public func holdKey(_ key: KeyCommand) {
        guard let keycode = KeyCodeMap.key(for: key) else { return }
        sendDown(keycode)
    }

    public func releaseKey(_ key: KeyCommand) {
        guard let keycode = KeyCodeMap.key(for: key) else { return }
        sendUp(keycode)
    }

    private func sendDown(_ key: Key) {
        pacer.send { [remoteManager] in remoteManager.send(KeyPress(key, .START_LONG)) }
    }
    private func sendUp(_ key: Key) {
        pacer.send { [remoteManager] in remoteManager.send(KeyPress(key, .END_LONG)) }
    }

    public func sendText(_ text: String) {
        // ASCII fallback: the library has no IME message, so text becomes one
        // key event per character. Unsupported characters (incl. Cyrillic) are
        // skipped.
        //
        // The events MUST be paced. Sending them back-to-back makes the TV
        // close the control connection outright — verified against a Xiaomi
        // TV P1e 32, where "hello" sent as a tight loop produced
        // `receiveDataError(POSIXErrorCode 96)` and a dropped session, while a
        // single key event was fine.
        let keycodes = KeyCodeMap.asciiKeys(for: text)
        guard !keycodes.isEmpty else { return }
        // Queued, not slept through: the pacer already owns the gap, and its
        // measured 8ms replaces the 80ms guess this loop used to carry — the
        // same constraint, an order of magnitude cheaper.
        for keycode in keycodes {
            pacer.send { [remoteManager] in remoteManager.send(KeyPress(keycode)) }
        }
    }

    /// Launches an arbitrary URI via the protocol's app-link message. The app
    /// reaches this through `sendKey(.launchApp)`; rc-probe calls it directly
    /// to try candidate URIs. CAUTION: a URI no installed app handles drops
    /// the control session outright — real-TV-verified URIs only.
    public func sendDeepLink(_ uri: String) {
        pacer.send { [remoteManager] in remoteManager.send(DeepLink(uri)) }
    }

    /// Sends arbitrary pre-encoded RemoteMessage bytes (the manager adds the
    /// varint length frame). Born as an rc-probe debug affordance for the IME
    /// spike; now also the app's outbound IME path, since the library models
    /// none of those messages.
    public func sendRaw(_ data: Data) {
        struct Raw: RequestDataProtocol { let data: Data }
        pacer.send { [remoteManager] in remoteManager.send(Raw(data: data)) }
    }

    /// Holds a raw keycode down for a fixed duration. Debug affordance for
    /// rc-probe only: the hold length is a parameter (not the menu's fixed
    /// 700ms) because the length is the thing under test — this is how the
    /// glide finding was made. Goes through `sendDown`/`sendUp` like every
    /// other hold.
    public func sendRawKeyCodeHeld(_ code: UInt, milliseconds: Int) {
        guard let key = Key(rawValue: code) else { return }
        holdRawKey(key, milliseconds: milliseconds)
    }

    /// Sends an arbitrary Android keycode. Debug affordance for `rc-probe`
    /// only — the app always goes through `sendKey(_:)`. Exists so keycode
    /// candidates can be tried against a real TV without a rebuild of the
    /// app's command vocabulary.
    public func sendRawKeyCode(_ code: UInt, longPress: Bool = false) {
        guard let key = Key(rawValue: code) else { return }
        guard longPress else {
            pacer.send { [remoteManager] in remoteManager.send(KeyPress(key)) }
            return
        }
        // Android TV's context menu is usually a long press of OK, which the
        // protocol expresses as START_LONG … END_LONG around a hold.
        holdRawKey(key, milliseconds: 700)
    }

    /// A self-terminating hold: down, wait, up — the release is scheduled in
    /// the same breath as the press so no caller can forget it. Only for
    /// FIXED-length holds; the pointer's open-ended glide cannot use this and
    /// goes through `holdKey`/`releaseKey` instead, with the controller
    /// owning the release.
    private func holdRawKey(_ key: Key, milliseconds: Int) {
        Task { @MainActor [weak self] in
            self?.sendDown(key)
            try? await Task.sleep(for: .milliseconds(milliseconds))
            self?.sendUp(key)
        }
    }

    public func disconnect() {
        // Anything still queued — above all the release of a held key —
        // goes out before the socket does. A key left down outlives this
        // session and keeps the TV scrolling.
        pacer.flush()
        remoteManager.disconnect()
    }
}
