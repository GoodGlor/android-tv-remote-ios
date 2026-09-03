import Foundation
import Observation

/// What the UI needs from a cursor transport. A seam, so `PointerView` can be
/// driven by a mock and the real client's socket faked in tests.
@MainActor
public protocol BrowserCursorControlling: AnyObject {
    /// True only while the cursor is genuinely usable: the socket is open
    /// AND the TV browser's own `app_state` push has told us it is
    /// foregrounded on a loaded page. A socket being open is NOT enough by
    /// itself — the TV browser's server keeps accepting connections while
    /// merely backgrounded, or while sitting on its own start screen with no
    /// page loaded, and in neither state is there anything for the cursor to
    /// move. Drives the UI indicator AND the choice of input mechanism, so it
    /// must never be optimistic. See `BrowserCursorClient.cursorUsableScreen`.
    var isAvailable: Bool { get }
    func move(dx: Float, dy: Float)
    func click()
}

/// The socket, abstracted so the client's matching and gating logic is
/// testable without a TV. Only the conforming WebSocket needs hardware.
@MainActor
protocol CursorSocketing: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    /// Fired for every binary frame the server pushes on its TV→phone
    /// channel — including, but not limited to, the `app_state` frames
    /// `BrowserCursorClient` decodes for availability. Not fired for text
    /// frames; the server only ever sends binary.
    var onMessage: ((Data) -> Void)? { get set }
    /// One `connect` per instance is expected. `disconnect()` must precede
    /// any reuse — a re-entrant `connect` on the same instance is not
    /// supported by every conformer.
    func connect(host: String, port: UInt16)
    func send(_ data: Data)
    func disconnect()
}

/// Talks the TV browser's private cursor protocol.
///
/// Deliberately NOT part of `TVController`. That protocol is the app's stable
/// remote; this one is a third-party, undocumented channel that a browser
/// update can break without warning. Keeping them apart means such a break
/// costs one file and degrades Pointer mode to its key glide, rather than
/// destabilising the remote.
@MainActor
@Observable
public final class BrowserCursorClient: BrowserCursorControlling {
    public private(set) var isAvailable = false

    /// The `app_state.screen` value that means a page is actually loaded and
    /// the cursor can move. Observed on hardware (TV `desktop`, 2026-08-22):
    ///   - "browser" — a page is open in BrowserActivity. Cursor usable.
    ///   - "home"    — the app's own start screen (MainActivity). Socket
    ///                 stays open and `foreground` can still be true, but
    ///                 there is nothing on screen for the cursor to move.
    /// Any other value — including one never observed — is treated as NOT
    /// usable. See `docs/tvbrowser-remote-protocol.md`.
    private static let cursorUsableScreen = "browser"

    private let discovery: BrowserCursorDiscovery
    private let makeSocket: @MainActor () -> CursorSocketing
    private var socket: CursorSocketing?
    private var targetServiceName: String?
    /// `nonisolated(unsafe)` for `deinit` alone, which is nonisolated and
    /// holds exclusive access by definition. `Task` is `Sendable`, and every
    /// other accessor is MainActor-isolated.
    private nonisolated(unsafe) var observation: Task<Void, Never>?

    /// Whether the currently-installed socket's `onOpen` has fired. Kept
    /// apart from `isAvailable`, which additionally requires a fresh
    /// `app_state` frame reporting a usable screen — see
    /// `refreshAvailability()`.
    private var socketOpen = false
    /// The most recent `app_state` decoded from the server's push channel.
    /// `nil` until the first such frame arrives on the current connection —
    /// which is exactly why availability starts false and stays false until
    /// one does, rather than assuming an open socket means a page is loaded.
    private var lastAppState: (foreground: Bool, screen: String)?

    public convenience init(discovery: BrowserCursorDiscovery = BrowserCursorDiscovery()) {
        self.init(discovery: discovery, makeSocket: { WebSocketCursorSocket() })
    }

    init(
        discovery: BrowserCursorDiscovery = BrowserCursorDiscovery(),
        makeSocket: @escaping @MainActor () -> CursorSocketing
    ) {
        self.discovery = discovery
        self.makeSocket = makeSocket
    }

    /// Set the TV we are matching against, without touching discovery or the
    /// poll loop. Split out of `start(matchingServiceName:)` so the
    /// name-matching rule is testable without opening a real `NWBrowser` in a
    /// unit test.
    func beginMatching(serviceName: String) {
        targetServiceName = serviceName
    }

    /// Begin looking for the cursor service advertised as `matchingServiceName`
    /// — the Bonjour service instance name of the TV we are actually paired
    /// to, and only that one.
    ///
    /// Matching is on the instance name, not the IP. An IP is a DHCP lease
    /// and goes stale the moment the router hands the TV a new one; the
    /// service's advertised `host` on the next poll is simply wherever it
    /// currently lives, and we connect to that. The instance name is stable
    /// across such moves, so it is the only safe matching key — this is the
    /// same pattern `AndroidTVController.attemptReconnect` already uses to
    /// recover a moved TV via `DeviceDiscovery.resolveHost(serviceName:)`,
    /// not a new invention.
    ///
    /// Idempotent when already running against the same service name. The
    /// app's lifecycle sites (launch, every scene-active transition, a
    /// pairing success) call this repeatedly and legitimately — Control
    /// Centre and the app switcher fire `.active` without ever visiting
    /// `.background`. Without this guard, each of those calls would `stop()`
    /// a healthy socket and force a fresh discovery poll + handshake, and the
    /// user would watch "Free cursor" flap off and Pointer mode fall back to
    /// the glide for no reason. `stop()` already clears `targetServiceName`,
    /// so an explicit `stop()` followed by `start()` on the same service name
    /// restarts naturally without any help from this condition — the
    /// `observation == nil` disjunct is defence in depth against a future
    /// `stop()` that stops clearing `targetServiceName`, and it is also what
    /// makes the test-only `beginMatching(serviceName:)` seam (which sets
    /// `targetServiceName` without touching `observation`) behave sanely
    /// rather than getting stuck idempotent.
    public func start(matchingServiceName: String) {
        guard targetServiceName != matchingServiceName || observation == nil else { return }
        stop()
        beginMatching(serviceName: matchingServiceName)
        discovery.start()
        beginObserving()
    }

    /// The poll loop, split out for the same reason as `beginMatching`: it
    /// lets a test reach the "already observing" state that `start`'s
    /// idempotency guard checks without opening a real `NWBrowser`.
    func beginObserving() {
        observation = Task { @MainActor [weak self] in
            // Poll rather than observe: `services` is @Observable, but a
            // withObservationTracking loop would need re-arming on every
            // change and this runs twice a second at most. The same loop
            // provides the reconnect — a dropped socket is picked up on the
            // next tick while the service is still advertised.
            while !Task.isCancelled {
                guard let self else { return }
                self.considerServices(self.discovery.services)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Backstop for an owner that drops the client without `stop()`. Cancels
    /// the poll loop; the socket tears itself down in its own `deinit` once
    /// this releases the last reference to it.
    deinit { observation?.cancel() }

    public func stop() {
        observation?.cancel()
        observation = nil
        discovery.stop()
        targetServiceName = nil
        closeSocket()
    }

    /// Connect if one of `services` is our TV and we are not already up.
    /// Internal rather than private so the name-matching rule — the one that
    /// keeps this phone's cursor off a neighbour's TV, and the one that
    /// survives our own TV's IP changing — is directly testable.
    func considerServices(_ services: [BrowserCursorService]) {
        guard socket == nil, let targetServiceName else { return }
        guard let match = services.first(where: { $0.name == targetServiceName }) else { return }
        connect(to: match)
    }

    func connect(to service: BrowserCursorService) {
        closeSocket()
        let socket = makeSocket()
        self.socket = socket
        socket.onOpen = { [weak self, weak socket] in
            guard let self, let socket, self.socket === socket else { return }
            self.socketOpen = true
            self.refreshAvailability()
        }
        socket.onClose = { [weak self, weak socket] in
            guard let self, let socket, self.socket === socket else { return }
            self.socketOpen = false
            // Clear the remembered state: a reconnect must not inherit
            // availability from a previous connection's last-known screen.
            self.lastAppState = nil
            self.isAvailable = false
            self.socket = nil
        }
        socket.onMessage = { [weak self, weak socket] data in
            guard let self, let socket, self.socket === socket else { return }
            self.handleMessage(data)
        }
        socket.connect(host: service.host, port: service.port)
    }

    /// Folds one raw frame into `lastAppState`, if it carries an `app_state`
    /// (top-level field 5). Frames without field 5 — the server sends several
    /// unrelated frames per burst — and frames whose field 5 is truncated or
    /// otherwise unparseable leave the last known state UNTOUCHED: staying on
    /// stale-but-real state is safer than flipping availability off a
    /// garbage byte.
    private func handleMessage(_ data: Data) {
        guard let decoded = Self.decodeAppState([UInt8](data)) else { return }
        lastAppState = decoded
        refreshAvailability()
    }

    /// Decodes top-level field 5 (`app_state`), then within its payload field
    /// 1 (varint → `foreground`; absent means false, the proto3 default) and
    /// field 2 (bytes → UTF-8 `screen`). Uses `Wire.fields`, which already
    /// handles varints, length-delimited fields and truncation safely — no
    /// hand-rolled parsing here. Returns `nil` (leave state untouched) when
    /// field 5 is absent, or present but no `screen` could be recovered.
    private static func decodeAppState(_ bytes: [UInt8]) -> (foreground: Bool, screen: String)? {
        guard let appState = Wire.fields(bytes).first(where: { $0.number == 5 && $0.wireType == 2 })
        else { return nil }
        var foreground = false
        var screen: String?
        for field in Wire.fields(appState.payload) {
            switch (field.number, field.wireType) {
            case (1, 0):
                foreground = field.varint != 0
            case (2, 2):
                screen = String(decoding: field.payload, as: UTF8.self)
            default:
                break
            }
        }
        guard let screen else { return nil }
        return (foreground, screen)
    }

    /// The single place `isAvailable` is derived: the socket must be open,
    /// at least one `app_state` frame must have arrived, it must report
    /// `foreground == true`, and its `screen` must be exactly
    /// `cursorUsableScreen`. Missing any of these — including simply not
    /// having heard from the server yet — means NOT available.
    private func refreshAvailability() {
        isAvailable = socketOpen
            && lastAppState?.foreground == true
            && lastAppState?.screen == Self.cursorUsableScreen
    }

    public func move(dx: Float, dy: Float) {
        send(CursorMessages.move(dx: dx, dy: dy))
    }

    public func click() {
        send(CursorMessages.click())
    }

    /// No pacing floor here. The 80ms gate belongs to Remote v2, where
    /// back-to-back key events close the control session; this socket took
    /// 20ms intervals without complaint during the spike. Copying the gate
    /// across would make the cursor stutter for no reason.
    private func send(_ data: Data) {
        guard isAvailable, let socket else { return }
        socket.send(data)
    }

    private func closeSocket() {
        isAvailable = false
        socketOpen = false
        lastAppState = nil
        guard let socket else { return }
        socket.onOpen = nil
        socket.onClose = nil
        socket.onMessage = nil
        socket.disconnect()
        self.socket = nil
    }
}

/// `URLSessionWebSocketTask` behind `CursorSocketing`.
///
/// Two things this must do that are easy to omit:
/// - keep a `receive()` call outstanding at all times, or a close frame is
///   never noticed and the client believes a dead socket is alive;
/// - report open from the delegate callback, not from `resume()`, which
///   returns before the handshake and cannot tell a live host from a dead one.
@MainActor
final class WebSocketCursorSocket: NSObject, CursorSocketing {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onMessage: ((Data) -> Void)?

    /// All three are `nonisolated(unsafe)` for `deinit` alone, which is
    /// nonisolated and holds exclusive access by definition. `URLSession` and
    /// `URLSessionWebSocketTask` are thread-safe and `Task` is `Sendable`;
    /// every other accessor is MainActor-isolated.
    private nonisolated(unsafe) var task: URLSessionWebSocketTask?
    private nonisolated(unsafe) var session: URLSession?
    fileprivate nonisolated(unsafe) var handshakeWatchdog: Task<Void, Never>?
    /// `URLSession` retains its delegate until it is invalidated. With the
    /// socket as its own delegate, an owner that dropped this object without
    /// calling `disconnect()` left the session holding the last reference —
    /// so `deinit` never ran, and the WebSocket stayed open for the life of
    /// the process. The session retains this proxy instead, which points back
    /// weakly, letting `deinit` run and invalidate the session from there.
    private let delegateProxy = CursorSocketDelegate()

    /// Bounds the HANDSHAKE only — not `URLSessionConfiguration`'s idle-data
    /// timeout, which resets on any transfer and would trip on a healthy,
    /// merely quiescent connection (a user holding the cursor still). Without
    /// this, `considerServices` won't retry a wedged handshake — it gates on
    /// `socket == nil` — so a dead TV would leave the user with no cursor and
    /// no fallback until `URLSession`'s 60s default finally gives up.
    private static let handshakeTimeout: Duration = .seconds(5)

    func connect(host: String, port: UInt16) {
        // Re-entrant guard: a second connect() on the same instance must not
        // leave a prior watchdog/task/session alive underneath the new one.
        disconnect()
        guard let url = URL(string: "ws://\(host):\(port)/ws") else { return }
        let configuration = URLSessionConfiguration.ephemeral
        // The handshake is bounded separately by `handshakeTimeout` below;
        // this disables `URLSessionConfiguration`'s 60s idle-data timeout so
        // a quiescent-but-healthy cursor socket (a user holding the cursor
        // still) is not torn down while genuinely connected.
        configuration.timeoutIntervalForRequest = 3600
        delegateProxy.owner = self
        let session = URLSession(configuration: configuration, delegate: delegateProxy, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        listen()
        handshakeWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.handshakeTimeout)
            guard !Task.isCancelled else { return }
            self?.fail() // handshake never completed
        }
    }

    func send(_ data: Data) {
        task?.send(.data(data)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in self?.fail() }
        }
    }

    func disconnect() {
        handshakeWatchdog?.cancel()
        handshakeWatchdog = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func listen() {
        task?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    // The server pushes app_state (and other) frames on this
                    // same channel; BrowserCursorClient decodes them for
                    // availability. Only .data is ever sent by the server —
                    // .string is ignored rather than converted.
                    if case .data(let data) = message {
                        self.onMessage?(data)
                    }
                    // Re-arm EXACTLY as before, regardless of message kind:
                    // a socket with no outstanding receive() never notices a
                    // close.
                    self.listen()
                case .failure:
                    self.fail()
                }
            }
        }
    }

    /// Backstop only — `disconnect()` remains the supported teardown. Reached
    /// when an owner drops this object without it, which is exactly the case
    /// that used to leave the socket open. Touches only the OS handles, all of
    /// which are safe to cancel from any thread.
    deinit {
        handshakeWatchdog?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    fileprivate func fail() {
        handshakeWatchdog?.cancel()
        handshakeWatchdog = nil
        guard task != nil else { return }
        task = nil
        session?.invalidateAndCancel()
        session = nil
        onClose?()
    }
}

/// Holds its socket weakly so `URLSession` cannot keep a dropped socket — and
/// its open WebSocket — alive. See `WebSocketCursorSocket.delegateProxy`.
private final class CursorSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    /// Weak by design; the socket owns this proxy, never the other way round.
    @MainActor weak var owner: WebSocketCursorSocket?

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor [weak self] in
            guard let owner = self?.owner else { return }
            owner.handshakeWatchdog?.cancel()
            owner.handshakeWatchdog = nil
            owner.onOpen?()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor [weak self] in self?.owner?.fail() }
    }
}
