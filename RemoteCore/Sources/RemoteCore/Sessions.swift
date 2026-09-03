import Foundation
@preconcurrency import AndroidTVRemoteControl

/// Sendable events — the ONLY values that cross from library queues to the
/// MainActor.
public enum PairingEvent: Equatable, Sendable {
    case codeDisplayed
    case paired
    case failed(TVControllerError)
}

public enum ControlEvent: Equatable, Sendable {
    case connected
    case dropped(TVControllerError?)   // nil = clean disconnect
}

/// Seams the adapter is tested through; `LibPairingSession`/`LibControlSession`
/// are the production implementations, fakes live in the test target. Public
/// because rc-probe (Task 7) and the app's public session-factory init
/// (Task 8) are second consumers outside this module.
@MainActor
public protocol PairingSessioning: AnyObject {
    var onEvent: ((PairingEvent) -> Void)? { get set }
    func start(host: String)
    func sendCode(_ code: String)
    func cancel()
}

@MainActor
public protocol ControlSessioning: AnyObject {
    var onEvent: ((ControlEvent) -> Void)? { get set }
    /// Decoded IME traffic (fields 20/21/22), one call per message. In the
    /// seam rather than behind a downcast because the whole text feature is
    /// built on it: the controller's `ImeChannel` is driven entirely by these
    /// messages, so a fake session is all a test needs to exercise it.
    var onImeMessage: ((ImeMessage) -> Void)? { get set }
    func connect(host: String)
    func sendKey(_ key: KeyCommand)
    /// Presses `key` and leaves it DOWN until `releaseKey(_:)`. Android
    /// auto-repeats a held D-pad key, and that repeat is what makes the TV
    /// browser's cursor glide continuously instead of nudging a few pixels
    /// per tap (real-TV finding, docs/phase2-notes.md).
    ///
    /// Modelled as explicit down/up rather than "hold for N ms" so the
    /// session layer stays dumb: it has no idea what is held or for how long.
    /// Owning that state is `AndroidTVController.setHeldDirection(_:)`'s job,
    /// precisely because a hold that is never released leaves the TV
    /// scrolling by itself with no way for the user to stop it.
    func holdKey(_ key: KeyCommand)
    /// Ends a `holdKey(_:)`. Safe to call for a key that is not down — the
    /// TV ignores an unmatched release — which is what lets every teardown
    /// path fire it unconditionally.
    func releaseKey(_ key: KeyCommand)
    func sendText(_ text: String)
    /// Pre-encoded RemoteMessage bytes (the session adds the length frame).
    /// The IME handshake's only outbound path — the library models none of
    /// those messages, so they are built by `ImeEncoder` and posted raw.
    func sendRaw(_ data: Data)
    /// The protocol's app-link launch (arbitrary URI). CAUTION: an
    /// unsupported URI drops the control session — real-TV-verified URIs only.
    func sendDeepLink(_ uri: String)
    func disconnect()
}

/// Pure state→event mapping (unit-tested; returns nil for intermediate states).
func pairingEvent(from state: PairingManager.PairingState) -> PairingEvent? {
    switch state {
    case .waitingCode: .codeDisplayed
    case .successPaired: .paired
    case .error(.wrongCode), .error(.secretNotSuccess): .failed(.wrongCode)
    case .error(let error): .failed(.pairingFailed(String(describing: error)))
    default: nil
    }
}

func controlEvent(from state: RemoteManager.RemoteState) -> ControlEvent? {
    switch state {
    case .paired: .connected
    case .idle: .dropped(nil)
    case .error(let error): .dropped(.connectionFailed(String(describing: error)))
    default: nil
    }
}
