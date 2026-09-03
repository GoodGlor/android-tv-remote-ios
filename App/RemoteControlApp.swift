import RemoteCore
import SwiftUI

@main
struct RemoteControlApp: App {
    @State private var controller = AndroidTVController(identity: IdentityProvider.bundled()!)
    @State private var cursor = BrowserCursorClient()
    private let store = DeviceStore()

    var body: some Scene {
        WindowGroup {
            RootView(controller: controller, store: store, cursor: cursor)
        }
    }
}

struct RootView: View {
    let controller: AndroidTVController
    let store: DeviceStore
    let cursor: BrowserCursorClient
    @State private var pairedDevice: PairedDevice?
    /// The connect screen is also reachable from Settings on an already-paired
    /// app ("Change TV…"). Getting there must not destroy the pairing we still
    /// have: the TV being looked for may not be found (wrong network, or not an
    /// Android TV at all), and the user has to be able to back out onto a
    /// working remote. So the saved device is replaced only when a *new*
    /// pairing succeeds; until then this flag, not `store.clear()`, is what
    /// puts ConnectView on screen.
    @State private var isChangingTV = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let device = pairedDevice, !isChangingTV {
                RemoteView(controller: controller, device: device, cursor: cursor) {
                    // Not an unpair. Drop the live session and the cursor
                    // browse — the pairing handshake wants the radio, and a
                    // session on the old TV is no use on the connect screen —
                    // but leave `store` and `pairedDevice` untouched so Cancel
                    // has something to come back to.
                    controller.disconnect()
                    cursor.stop()
                    isChangingTV = true
                }
            } else {
                ConnectView(
                    controller: controller,
                    // Offered only when there is somewhere to go back to. On a
                    // first launch nothing is paired, and a Cancel that led
                    // nowhere would be worse than no Cancel at all.
                    onCancel: pairedDevice.map { device in { returnToRemote(device) } }
                ) { device in
                    store.save(device)
                    pairedDevice = device
                    isChangingTV = false
                    // Pairing does not connect: the real transport finishes the
                    // pairing round and drops the socket. Nothing else would
                    // connect us here either — `.task` below fired once when
                    // RootView appeared (with no paired device) and does not
                    // re-run, and the scenePhase branch needs a background
                    // round-trip. Without this the remote is dead on arrival.
                    Task { try? await controller.connect(to: device) }
                    cursor.start(matchingServiceName: device.serviceName)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { pairedDevice = store.pairedDevice }
        .onChange(of: scenePhase) { _, phase in
            // iOS kills LAN sockets in background: disconnect cleanly, then
            // reconnect on return.
            switch phase {
            case .background:
                controller.disconnect()
                // iOS kills LAN sockets in the background, and the browse would
                // keep the radio busy for a cursor nobody can see.
                cursor.stop()
            case .active:
                // Not while changing TV: the connect screen is showing, a
                // pairing round may be in flight, and silently reviving the
                // session to the *old* TV would fight it for the radio.
                guard !isChangingTV else { break }
                if let device = pairedDevice, controller.connectionState == .disconnected {
                    Task { try? await controller.connect(to: device) }
                }
                if let device = pairedDevice { cursor.start(matchingServiceName: device.serviceName) }
            default:
                break
            }
        }
        .task {
            if let device = store.pairedDevice {
                // Cursor discovery is not gated on the TV control session —
                // start it first so it is not held up by (or lost to a race
                // with) the connect below. This is now the single launch-time
                // start site; `start(matchingServiceName:)` is idempotent, so
                // the other lifecycle sites (pairing success, scenePhase.active)
                // calling it again is harmless.
                cursor.start(matchingServiceName: device.serviceName)
                try? await controller.connect(to: device)
            }
        }
    }

    /// Leaves the connect screen with the previous pairing intact — the path
    /// out that used to not exist. Mirrors the pairing-success path (and the
    /// scenePhase one): the connect screen left us disconnected with the
    /// cursor browse stopped, so both have to be restarted by hand.
    private func returnToRemote(_ device: PairedDevice) {
        isChangingTV = false
        cursor.start(matchingServiceName: device.serviceName)
        Task { try? await controller.connect(to: device) }
    }
}
