import Network
import Testing
@testable import RemoteCore

// The port matters here in a way it never did for the remote: the TV browser's
// server advertises its port over Bonjour and it appears in NO source file
// (which is why grepping the APK for 8335 found nothing). Dropping it and
// hardcoding a guess would work today and break silently later.

@Test func hostPortKeepsBothHalves() {
    let endpoint = NWEndpoint.hostPort(host: .ipv4(.init("192.168.0.108")!), port: 8335)
    let resolved = hostPort(from: endpoint)
    #expect(resolved?.host == "192.168.0.108")
    #expect(resolved?.port == 8335)
}

@Test func hostPortStripsTheInterfaceScope() {
    // Same trap as PairedDevice.host: "192.168.0.108%en0" is not connectable.
    let endpoint = NWEndpoint.hostPort(host: .ipv4(.init("192.168.0.108%en0")!), port: 8335)
    #expect(hostPort(from: endpoint)?.host == "192.168.0.108")
}

@Test func hostPortRejectsAnUnresolvedServiceEndpoint() {
    let endpoint = NWEndpoint.service(name: "desktop", type: "_zeusremote._tcp", domain: "local.", interface: nil)
    #expect(hostPort(from: endpoint) == nil)
}

@MainActor
@Test func discoveryStartsEmptyAndSurvivesStopWithoutStart() {
    let discovery = BrowserCursorDiscovery()
    #expect(discovery.services.isEmpty)
    discovery.stop()   // must not crash or assert
    #expect(discovery.services.isEmpty)
}

@Test func servicesCompareByAllThreeFields() {
    let a = BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 8335)
    let b = BrowserCursorService(name: "desktop", host: "192.168.0.108", port: 9000)
    #expect(a != b)
}

// MARK: - Self-heal: identity guard (FIX 5)

@MainActor
@Test func aStaleBrowsersFailureCannotDisturbAHealthyReplacement() {
    // The race the reviewer described: browser A's `.failed` was queued for
    // the MainActor hop before a stop()/start() pair replaced it with a
    // healthy browser B. Neither NWBrowser here is ever `.start()`ed —
    // constructing one does not begin a real Bonjour browse, only
    // `.start(queue:)` does — so this test never touches the network.
    // `browser` is assigned directly (a test seam; see its declaration) to
    // install known tokens without going through `start()`.
    let discovery = BrowserCursorDiscovery()
    let browserA = NWBrowser(for: .bonjour(type: "_zeusremote._tcp", domain: nil), using: .tcp)
    let browserB = NWBrowser(for: .bonjour(type: "_zeusremote._tcp", domain: nil), using: .tcp)

    discovery.browser = browserA
    discovery.browser = browserB // the stop()/start() pair that raced ahead

    // A's now-stale `.failed` must be ignored: it is no longer the installed
    // browser, so it must not schedule a restart that would tear down B.
    discovery.handleBrowserState(.failed(.posix(.ECONNREFUSED)), from: browserA)
    #expect(discovery.restartTask == nil)
    #expect(discovery.browser === browserB)
}

// MARK: - Self-heal: restart/backoff (FIX 6, FIX 7)
//
// `handleBrowseFailure()`/`handleBrowseReady()` are internal test seams —
// see their declarations — so these never need a real NWBrowser failure or
// a real Bonjour browse.

@MainActor
@Test func stopDuringTheBackoffProducesNoRestart() {
    let discovery = BrowserCursorDiscovery(restartBackoffBase: .seconds(2))
    discovery.handleBrowseFailure()
    #expect(discovery.restartTask != nil)
    discovery.stop()
    #expect(discovery.restartTask == nil)
}

@MainActor
@Test func tenFailuresInARowLeaveExactlyOnePendingRestart() {
    let discovery = BrowserCursorDiscovery(restartBackoffBase: .seconds(2))
    for _ in 0..<10 {
        discovery.handleBrowseFailure()
    }
    // `restartTask` can only ever hold one Task — scheduleRestart() cancels
    // and replaces it rather than stacking a new one alongside the old.
    #expect(discovery.restartTask != nil)
    // Cancel the pending restart so it never fires and reaches the network,
    // even after this test function returns.
    discovery.stop()
}

@MainActor
@Test func aFailureAfterStopNeverRestarts() {
    let discovery = BrowserCursorDiscovery(restartBackoffBase: .seconds(2))
    discovery.stop()
    discovery.handleBrowseFailure()
    #expect(discovery.restartTask == nil)
}

@MainActor
@Test func repeatedFailuresEscalateBackoffThenReadyResetsIt() {
    let discovery = BrowserCursorDiscovery(restartBackoffBase: .seconds(2))
    #expect(discovery.nextRestartBackoff == .seconds(2))
    discovery.handleBrowseFailure()
    #expect(discovery.nextRestartBackoff == .seconds(4))
    discovery.handleBrowseFailure()
    #expect(discovery.nextRestartBackoff == .seconds(8))
    discovery.handleBrowseFailure()
    #expect(discovery.nextRestartBackoff == .seconds(16))
    discovery.handleBrowseFailure()
    #expect(discovery.nextRestartBackoff == .seconds(32))
    discovery.handleBrowseFailure()
    #expect(discovery.nextRestartBackoff == .seconds(60)) // 32 * 2 = 64, capped at 60
    discovery.handleBrowseFailure()
    #expect(discovery.nextRestartBackoff == .seconds(60)) // stays capped

    // The browse recovering resets the escalation — a future `.failed`
    // should retry promptly, not inherit the accumulated 60s backoff.
    discovery.handleBrowseReady()
    #expect(discovery.nextRestartBackoff == .seconds(2))

    discovery.stop()
}

// MARK: `.waiting` — local network permission not yet granted

@MainActor
@Test func aWaitingBrowseSchedulesARestartLikeAFailedOne() {
    // Reproduced on a real device: on a fresh install the browse starts before
    // the user answers the local-network prompt, NWBrowser parks in `.waiting`,
    // and it stays there after permission is granted. Without a restart the
    // cursor is dead until the app is force-quit — which is exactly what
    // happened, twice, before this was understood.
    let discovery = BrowserCursorDiscovery(restartBackoffBase: .seconds(2))
    let browser = NWBrowser(for: .bonjour(type: "_zeusremote._tcp", domain: nil), using: .tcp)
    discovery.browser = browser

    discovery.handleBrowserState(.waiting(.posix(.EPERM)), from: browser)

    #expect(discovery.restartTask != nil)
    #expect(discovery.nextRestartBackoff == .seconds(4), "escalates like any other restart")
    discovery.stop()
}

@MainActor
@Test func aWaitingReportFromAReplacedBrowserIsIgnored() {
    // The identity guard must cover `.waiting` too: a browse we already
    // replaced must not schedule restarts against the live one.
    let discovery = BrowserCursorDiscovery(restartBackoffBase: .seconds(2))
    let stale = NWBrowser(for: .bonjour(type: "_zeusremote._tcp", domain: nil), using: .tcp)
    let live = NWBrowser(for: .bonjour(type: "_zeusremote._tcp", domain: nil), using: .tcp)
    discovery.browser = live

    discovery.handleBrowserState(.waiting(.posix(.EPERM)), from: stale)

    #expect(discovery.restartTask == nil)
    #expect(discovery.nextRestartBackoff == .seconds(2))
}
