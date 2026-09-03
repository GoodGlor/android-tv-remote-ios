import Foundation
import Network
import Observation
import os

/// One TV browser instance offering the cursor protocol.
public struct BrowserCursorService: Equatable, Sendable {
    public let name: String
    public let host: String
    /// Advertised, never assumed — see `hostPort(from:)`.
    public let port: UInt16

    public init(name: String, host: String, port: UInt16) {
        self.name = name
        self.host = host
        self.port = port
    }
}

/// Browses `_zeusremote._tcp` — the Bonjour type the TV browser's embedded
/// server advertises (instance name = the TV's name, e.g. "desktop").
///
/// Structurally a twin of `DeviceDiscovery` and deliberately a SEPARATE type
/// rather than a parameter on it: this one serves a private third-party
/// protocol that can vanish in a browser update, and nothing about the remote's
/// own discovery should have to change when it does.
///
/// Note for anyone adding another Bonjour type later: iOS silently refuses to
/// browse a type that is not listed in `NSBonjourServices` in Info.plist.
/// There is no error — the browse just never reports anything.
@MainActor
@Observable
public final class BrowserCursorDiscovery {
    public private(set) var services: [BrowserCursorService] = []

    /// Internal (not private): the identity-guard tests install a known
    /// `NWBrowser` token directly (never `.start()`ed, so no real Bonjour
    /// browse ever begins) to exercise `handleBrowserState`'s stale-browser
    /// check without racing a real callback. See BrowserCursorDiscoveryTests.
    var browser: NWBrowser?
    // Same generation guard as DeviceDiscovery: a slow resolve pass must not
    // overwrite `services` after a newer pass or a stop() superseded it.
    private var resolveGeneration = 0
    private var activeResolveTasks: [Task<Void, Never>] = []

    /// The backoff before restarting a `.failed` browse, escalated by
    /// `scheduleRestart()` and reset by `handleBrowseReady()`. Starts at
    /// `restartBackoffBase` (2s by default, not instant: a `.failed` can be
    /// the network flapping — Wi-Fi handoff, router reboot — and hammering
    /// `NWBrowser.start()` in a tight loop while that settles would just
    /// fail again immediately), doubles on every successive restart, and
    /// caps at `maxRestartBackoff` so a persistently failing browse (e.g. a
    /// Local Network policy denial surfacing as `.failed`) does not recreate
    /// an `NWBrowser` every 2s for the app's whole foreground lifetime.
    /// Internal (not private) so the escalation is directly testable without
    /// waiting out real timers. See BrowserCursorDiscoveryTests.
    private(set) var nextRestartBackoff: Duration
    private let restartBackoffBase: Duration
    private static let maxRestartBackoff: Duration = .seconds(60)

    /// Set at the top of `stop()` and cleared at the top of `start()`.
    /// `NWBrowser.cancel()` (which `stop()` calls) eventually delivers
    /// `.cancelled` to `stateUpdateHandler` asynchronously, on the browser's
    /// own queue — this flag is how that handler tells "we did this on
    /// purpose" apart from an unrequested failure, so our own `stop()` can
    /// never itself trigger a restart, and a `stop()` that lands during the
    /// backoff window cancels the pending restart outright.
    private var stopRequested = false
    /// Internal (not private) so tests can observe whether a restart is
    /// currently pending without waiting out real backoff timers. See
    /// BrowserCursorDiscoveryTests.
    private(set) var restartTask: Task<Void, Never>?

    public init(restartBackoffBase: Duration = .seconds(2)) {
        self.restartBackoffBase = restartBackoffBase
        self.nextRestartBackoff = restartBackoffBase
    }

    public func start() {
        stop()
        stopRequested = false
        nextRestartBackoff = restartBackoffBase
        let browser = NWBrowser(for: .bonjour(type: "_zeusremote._tcp", domain: nil), using: .tcp)
        self.browser = browser
        // Nothing installed this before: a browse that silently enters
        // `.failed` (or stalls there after a network change) just sits,
        // advertised-looking but never resolving anything, with no error and
        // nothing to notice it — on hardware the app sat for minutes with
        // the cursor never connecting, and this gap is the most likely
        // explanation, though it was not possible to reproduce deterministically
        // to confirm it as the proven cause. Restarting on `.failed` is cheap
        // insurance either way: a browse that dies silently makes the whole
        // feature look broken with nothing to debug.
        //
        // Identity-guarded: `NWBrowser.cancel()` delivers `.cancelled`/late
        // `.failed` asynchronously, on the browser's own queue. Without
        // checking that `browser` is still the CURRENTLY installed one, a
        // stale report queued for the MainActor hop before a stop()+start()
        // pair replaced it can land afterwards and act on the replacement —
        // e.g. scheduling a restart that tears a healthy new browser down.
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let browser else { return }
            Task { @MainActor [weak self] in
                self?.handleBrowserState(state, from: browser)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints: [(name: String, endpoint: NWEndpoint)] = results.compactMap {
                guard case .service(let name, _, _, _) = $0.endpoint else { return nil }
                return (name, $0.endpoint)
            }
            Task { @MainActor [weak self] in self?.spawnResolve(endpoints) }
        }
        browser.start(queue: .global(qos: .userInitiated))
    }

    public func stop() {
        stopRequested = true
        restartTask?.cancel()
        restartTask = nil
        browser?.cancel()
        browser = nil
        resolveGeneration += 1
        for task in activeResolveTasks { task.cancel() }
        activeResolveTasks.removeAll()
        services = []
    }

    /// Ignores any state reported by a browser that is no longer the
    /// installed one — see the identity-guard comment on `stateUpdateHandler`
    /// in `start()`. Internal (not private) so the guard itself is directly
    /// testable by installing known `NWBrowser` tokens and calling this
    /// directly, without racing a real callback. See
    /// BrowserCursorDiscoveryTests.
    func handleBrowserState(_ state: NWBrowser.State, from source: NWBrowser) {
        guard browser === source else { return }
        switch state {
        // `.waiting` is NOT a lesser `.failed` that resolves itself — it is
        // where an NWBrowser parks when local network permission has not been
        // granted, and it STAYS there after the user grants it. Reproduced on
        // a real device (2026-08-23): on a fresh install the browse starts,
        // iOS shows the permission prompt, and this browse never recovers even
        // though the TV is advertising and the remote's own browse works. The
        // cursor was dead until the app was force-quit and relaunched.
        //
        // Restarting on the same backoff as `.failed` is what makes granting
        // permission take effect without a relaunch. A permanently denied
        // permission just means a slow poll at the 60s cap, which is the right
        // cost for the alternative being a silently dead feature.
        case .failed, .waiting:
            handleBrowseFailure()
        case .ready:
            handleBrowseReady()
        default:
            break
        }
    }

    /// The `.failed` entry point, reached only once `handleBrowserState` has
    /// confirmed the report is from the still-installed browser. Internal
    /// (not private) so the restart/backoff behaviour is directly testable
    /// without a real NWBrowser failure. See BrowserCursorDiscoveryTests.
    func handleBrowseFailure() {
        scheduleRestart()
    }

    /// The `.ready` entry point: the browse recovered, so a future `.failed`
    /// should retry promptly rather than inheriting a long backoff
    /// accumulated from before it recovered. Internal (not private) — see
    /// `handleBrowseFailure`.
    func handleBrowseReady() {
        nextRestartBackoff = restartBackoffBase
    }

    /// Restarts the browse after the current `nextRestartBackoff`, unless a
    /// `stop()` (this one, or one that raced in during the wait) means
    /// nobody wants it running any more. Replacing rather than stacking
    /// `restartTask` keeps this to at most one pending restart at a time —
    /// repeated `.failed` states cannot pile up concurrent restarts into a
    /// storm. Escalates `nextRestartBackoff` (doubled, capped at
    /// `maxRestartBackoff`) for whichever restart comes after this one.
    private func scheduleRestart() {
        guard !stopRequested else { return }
        restartTask?.cancel()
        let backoff = nextRestartBackoff
        nextRestartBackoff = min(nextRestartBackoff * 2, Self.maxRestartBackoff)
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: backoff)
            guard !Task.isCancelled, let self, !self.stopRequested else { return }
            self.start()
        }
    }

    private func spawnResolve(_ found: [(name: String, endpoint: NWEndpoint)]) {
        resolveGeneration += 1
        let generation = resolveGeneration
        // Unlike `DeviceDiscovery`, this browser runs for the whole
        // foreground lifetime of the app, not just while a screen is open —
        // so a superseded pass must be cancelled and dropped here, or
        // `activeResolveTasks` accumulates one never-removed Task per
        // browse-results change for the entire session. A superseded pass's
        // results are already discarded by the generation guard below, so
        // cancelling it early costs nothing.
        for task in activeResolveTasks { task.cancel() }
        activeResolveTasks.removeAll()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.resolveAll(found, generation: generation)
        }
        activeResolveTasks.append(task)
    }

    private func resolveAll(_ found: [(name: String, endpoint: NWEndpoint)], generation: Int) async {
        var resolved: [BrowserCursorService] = []
        for entry in found {
            // Checked every iteration (not just at the top of the function):
            // this loop can span up to 5s per endpoint, and `stop()` on
            // scenePhase == .background must actually stop in-flight
            // NWConnections rather than let them keep running after
            // backgrounding.
            if Task.isCancelled { return }
            if let endpoint = await Self.resolve(endpoint: entry.endpoint) {
                resolved.append(
                    BrowserCursorService(name: entry.name, host: endpoint.host, port: endpoint.port)
                )
            }
        }
        guard generation == resolveGeneration else { return }
        services = resolved.sorted { $0.name < $1.name }
    }

    /// IPv4-pinned for the same reason as `DeviceDiscovery`: resolving on a
    /// real LAN otherwise yields a link-local IPv6 address whose scope is
    /// stripped, leaving something nothing can connect to.
    private static var resolveParameters: NWParameters {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        return parameters
    }

    private static func resolve(endpoint: NWEndpoint) async -> (host: String, port: UInt16)? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: resolveParameters)
            // Guard against double-resume: the state handler can fire repeatedly.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ value: (host: String, port: UInt16)?) {
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let inner = connection.currentPath?.remoteEndpoint {
                        finish(hostPort(from: inner))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
    }
}
