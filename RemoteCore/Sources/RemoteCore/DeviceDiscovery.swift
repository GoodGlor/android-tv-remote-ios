import Foundation
import Network
import Observation
import os

/// Extracts a plain host string from a resolved endpoint (strips IPv6 scope).
func hostString(from endpoint: NWEndpoint) -> String? {
    guard case .hostPort(let host, _) = endpoint else { return nil }
    switch host {
    // Network.framework appends an interface scope to a resolved address
    // ("192.168.0.103%en0"). IPv4 never needs it, and carrying it into
    // PairedDevice would persist an interface name that changes with the
    // network.
    case .ipv4(let address): return "\(address)".components(separatedBy: "%").first
    // IPv6 is the opposite: a link-local address is meaningless without its
    // scope, so keep it there and strip it only from routable addresses.
    case .ipv6(let address):
        let text = "\(address)"
        return text.lowercased().hasPrefix("fe80")
            ? text
            : text.components(separatedBy: "%").first
    case .name(let name, _): return name
    @unknown default: return nil
    }
}

/// Like `hostString(from:)` but keeps the port.
///
/// The remote's port is a constant (6466) so `hostString` throws it away. The
/// TV browser's is NOT: it is advertised in the SRV record and appears nowhere
/// in that app's code, so it must be carried from discovery to connection.
func hostPort(from endpoint: NWEndpoint) -> (host: String, port: UInt16)? {
    guard case .hostPort(_, let port) = endpoint,
          let host = hostString(from: endpoint) else { return nil }
    return (host, port.rawValue)
}

/// Browses `_androidtvremote2._tcp` and publishes devices as they appear.
/// Each found service is resolved to an IP by opening a short-lived TCP
/// connection to its control port and reading the remote endpoint.
@MainActor
@Observable
public final class DeviceDiscovery {
    public private(set) var devices: [DiscoveredDevice] = []
    public private(set) var permissionDenied = false

    private var browser: NWBrowser?
    // Generation counter + task list guard against a slower, older resolve
    // pass overwriting `devices` after a newer pass (or a stop()) has
    // already superseded it.
    private var resolveGeneration = 0
    private var activeResolveTasks: [Task<Void, Never>] = []

    public init() {}

    public func start() {
        stop()
        permissionDenied = false
        let browser = NWBrowser(
            for: .bonjour(type: "_androidtvremote2._tcp", domain: nil),
            using: .tcp
        )
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            // Local-network permission denial surfaces as a DNS policy error.
            if case .waiting(let error) = state, case .dns = error {
                Task { @MainActor [weak self] in self?.permissionDenied = true }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints: [(name: String, endpoint: NWEndpoint)] = results.compactMap {
                guard case .service(let name, _, _, _) = $0.endpoint else { return nil }
                return (name, $0.endpoint)
            }
            Task { @MainActor [weak self] in
                self?.spawnResolve(endpoints)
            }
        }
        browser.start(queue: .global(qos: .userInitiated))
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        // Invalidate any in-flight resolve passes (their eventual writes to
        // `devices` are now discarded) and cancel the tasks driving them.
        resolveGeneration += 1
        for task in activeResolveTasks { task.cancel() }
        activeResolveTasks.removeAll()
    }

    /// Starts (and tracks) a resolve pass for one browse-results snapshot,
    /// tagging it with the generation current at spawn time.
    private func spawnResolve(_ found: [(name: String, endpoint: NWEndpoint)]) {
        resolveGeneration += 1
        let generation = resolveGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.resolveAll(found, generation: generation)
        }
        activeResolveTasks.append(task)
    }

    private func resolveAll(_ found: [(name: String, endpoint: NWEndpoint)], generation: Int) async {
        var resolved: [DiscoveredDevice] = []
        for entry in found {
            if let host = await Self.resolve(endpoint: entry.endpoint) {
                resolved.append(DiscoveredDevice(name: entry.name, host: host, serviceName: entry.name))
            }
        }
        // A newer browse result (or a stop()) superseded this pass while it
        // was resolving — discard rather than clobber fresher data.
        guard generation == resolveGeneration else { return }
        // Keep a stable order for the UI.
        devices = resolved.sorted { $0.name < $1.name }
    }

    /// Re-resolve a known service to its current IP (router reassigned it).
    public static func resolveHost(serviceName: String) async -> String? {
        let endpoint = NWEndpoint.service(
            name: serviceName, type: "_androidtvremote2._tcp", domain: "local.", interface: nil
        )
        return await resolve(endpoint: endpoint)
    }

    /// TCP parameters pinned to IPv4.
    ///
    /// Without this, resolving a Bonjour service on a real LAN yields the TV's
    /// link-local IPv6 address (`fe80::…`), whose interface scope `hostString`
    /// strips — leaving an address nothing can connect to. IPv4 is also the
    /// better thing to persist in `PairedDevice`: a DHCP lease outlives an
    /// interface scope, which changes with the network interface.
    private static var resolveParameters: NWParameters {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        return parameters
    }

    private static func resolve(endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: resolveParameters)
            // Guard against double-resume: state handler can fire repeatedly.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ value: String?) {
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                // Break the connection -> handler -> connection retain cycle
                // before cancelling, so the NWConnection can deinit.
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let inner = connection.currentPath?.remoteEndpoint {
                        finish(hostString(from: inner))
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
