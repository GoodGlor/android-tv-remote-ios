import RemoteCore
import SwiftUI

struct RemoteView: View {
    let controller: any TVController
    let device: PairedDevice
    let cursor: any BrowserCursorControlling
    var onChangeTV: () -> Void

    @State private var mode = Preferences().controlMode
    /// Mirrored into state rather than read inline so the switch below stays
    /// a pure view read; refreshed when Settings closes (see `showSettings`).
    @State private var dpadStyle = Preferences().dpadStyle
    @State private var trackpadAcceleration = Preferences().trackpadAcceleration
    @State private var showKeyboard = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                powerRow
                Spacer(minLength: 12)
                // The toggle itself — not just the pointer segment — is
                // hidden while the cursor is unreachable. A single mode is
                // not a choice, and a two-segment control rendering one live
                // segment is clutter. The D-pad takes the space as normal.
                if cursor.isAvailable {
                    modeToggle
                    Spacer(minLength: 14)
                }
                switch mode {
                case .dpad:
                    switch dpadStyle {
                    case .buttons: DPadView(press: press, hold: hold)
                    case .trackpad:
                        SwipePadView(press: press, acceleration: trackpadAcceleration)
                            // Rebuild the pad when the setting changes: the
                            // engine is seeded once per view identity.
                            .id(trackpadAcceleration)
                    }
                case .pointer: PointerView(cursor: cursor)
                }
                Spacer(minLength: 14)
                navRow
                Spacer(minLength: 12)
                rockerRow
                Spacer(minLength: 12)
                mediaRow
                Spacer(minLength: 14)
                appRow
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .background(Theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showSettings) {
                SettingsView(controller: controller, device: device, onChangeTV: onChangeTV)
            }
        }
        .sheet(isPresented: $showKeyboard) {
            KeyboardSheet(controller: controller, isPresented: $showKeyboard)
        }
        .onChange(of: mode) { _, newValue in
            Preferences().controlMode = newValue
        }
        .onChange(of: cursor.isAvailable) { _, available in
            // A mode that is present but inert is worse than absent. The
            // instant the cursor service drops out from under a user who is
            // already in Pointer mode, force them back to the D-pad — never
            // leave them on a pad that cannot do anything.
            mode = effectiveControlMode(mode, cursorAvailable: available)
        }
        .onAppear {
            // A stored `controlMode == .pointer` is a preference, not a
            // promise: the cursor service may not be reachable this
            // session (browser closed, TV just booted). Re-check against
            // live availability rather than trusting the persisted value.
            mode = effectiveControlMode(mode, cursorAvailable: cursor.isAvailable)
        }
        .onChange(of: showKeyboard) { _, shown in
            // The one teardown the glide views cannot see: a sheet covers
            // them without ever removing them, so no `onDisappear` fires. A
            // second finger CAN reach the keyboard tile while a first is
            // holding an arrow (or the pointer surface), and iOS may cancel
            // that drag without an `onEnded`. Releasing here is free —
            // `setHeldDirection(nil)` no-ops when nothing is held.
            if shown { hold(nil) }
        }
        .onChange(of: showSettings) { _, shown in
            // Mirrors the keyboard-sheet guard above for the same
            // second-finger reason: the settings gear is reachable by a
            // second finger while a first holds an arrow, and this relies on
            // `NavigationStack` firing `onDisappear` on the source content to
            // release it — not guaranteed, so release explicitly here too.
            if shown {
                hold(nil)
            } else {
                // Settings is a navigation push, not a sheet, so this view is
                // still alive underneath and keeps its @State. Re-read on the
                // way back or a style change would not appear until relaunch.
                dpadStyle = Preferences().dpadStyle
                trackpadAcceleration = Preferences().trackpadAcceleration
            }
        }
    }

    private func press(_ key: KeyCommand) {
        Haptics.tap()
        controller.sendKey(key)
    }

    /// The glide, shared by both modes: Pointer's drag surface and the D-pad's
    /// four arrows. No haptic here — this fires on every update of a
    /// continuous drag, and buzzing through a glide would be unusable. The
    /// callers own their own one-shot buzz at the moment the hold starts,
    /// which is what keeps a D-pad arrow feeling like `press`'s single tap.
    private func hold(_ key: KeyCommand?) {
        controller.setHeldDirection(key)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 6) {
                    Circle()
                        .fill(controller.connectionState == .connected
                              ? Theme.connected : Theme.textTertiary)
                        .frame(width: 6, height: 6)
                    Text(controller.connectionState == .connected ? "Connected" : "Not connected")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                // Always present, only faded: an `if` here removed the row
                // outright, so the header changed height and everything below
                // it jumped whenever the cursor came or went — which is often,
                // since it follows what the TV browser is showing.
                HStack(spacing: 5) {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Free cursor")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Theme.accent)
                .opacity(cursor.isAvailable ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: cursor.isAvailable)
                // Invisible is not absent: without this VoiceOver would still
                // announce a cursor that is not there.
                .accessibilityHidden(!cursor.isAvailable)
            }
            Spacer()
            CircleControlButton(icon: "gearshape", size: 40, iconSize: 17) {
                showSettings = true
            }
            .accessibilityLabel("Settings")
        }
    }

    private var powerRow: some View {
        HStack {
            CircleControlButton(icon: "power", size: 58, iconSize: 22,
                                tint: Theme.power, background: Theme.powerBackground) {
                press(.power)
            }
            .accessibilityLabel("Power")
            Spacer()
            // A voice-search button sat to the right of this one and did
            // nothing but buzz — a Phase 2 placeholder that never got a
            // transport. Removed rather than left pretending. With two
            // buttons the row takes ONE spacer: keeping both left the right
            // third empty and the pair off-centre.
            CircleControlButton(icon: "tv", size: 58, iconSize: 22) { press(.input) }
                .accessibilityLabel("Input source")
        }
        .padding(.horizontal, 26)
    }

    private var modeToggle: some View {
        HStack(spacing: 2) {
            modeSegment(icon: "dpad", isActive: mode == .dpad, label: "D-pad mode") { mode = .dpad }
            modeSegment(icon: "cursorarrow.motionlines", isActive: mode == .pointer, label: "Pointer mode") { mode = .pointer }
        }
        .padding(3)
        .background(Theme.control, in: Capsule())
    }

    private func modeSegment(icon: String, isActive: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isActive ? Theme.accent : Theme.textTertiary)
                .frame(width: 74, height: 30)
                .background(isActive ? Theme.accent.opacity(0.12) : .clear, in: Capsule())
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }

    private var navRow: some View {
        HStack(spacing: 36) {
            CircleControlButton(icon: "chevron.backward", size: 54) { press(.back) }
                .accessibilityLabel("Back")
            CircleControlButton(icon: "house", size: 54) { press(.home) }
                .accessibilityLabel("Home")
            // The menu (≡) button was removed after testing against a real
            // Xiaomi TV P1e 32. Its intended action — opening the TV's
            // Settings — is not reachable over this protocol: every Android
            // keycode from 1 to 304 was sent (minus the destructive ones) and
            // the TV acted on none of them, and both `intent:` and
            // `android-app://` deep links made it drop the connection. The
            // physical remote's Settings button evidently reaches a system
            // app by a vendor-private Bluetooth path that key injection
            // cannot reproduce. `KeyCommand.menu` is retained and still maps
            // correctly (a long press of OK opens a context menu, verified
            // working) should a future UI want it.
        }
    }

    private var rockerRow: some View {
        HStack {
            RockerControl(label: "VOL", topIcon: "plus", bottomIcon: "minus",
                          topLabel: "Volume up", bottomLabel: "Volume down",
                          topAction: { press(.volumeUp) },
                          bottomAction: { press(.volumeDown) })
            Spacer()
            CircleControlButton(icon: "speaker.slash", size: 52, iconSize: 19) { press(.mute) }
                .accessibilityLabel("Mute")
            Spacer()
            RockerControl(label: "CH", topIcon: "chevron.up", bottomIcon: "chevron.down",
                          topLabel: "Channel up", bottomLabel: "Channel down",
                          topAction: { press(.channelUp) },
                          bottomAction: { press(.channelDown) })
        }
        .padding(.horizontal, 30)
    }

    private var mediaRow: some View {
        HStack(spacing: 28) {
            CircleControlButton(icon: "backward", size: 46, iconSize: 17) { press(.rewind) }
                .accessibilityLabel("Rewind")
            CircleControlButton(icon: "playpause", size: 52, iconSize: 19,
                                tint: Theme.textPrimary, background: Theme.controlHigh) {
                press(.playPause)
            }
            .accessibilityLabel("Play pause")
            CircleControlButton(icon: "forward", size: 46, iconSize: 17) { press(.fastForward) }
                .accessibilityLabel("Fast forward")
        }
    }

    private var appRow: some View {
        HStack(spacing: 10) {
            ForEach(AppShortcut.allCases, id: \.self) { app in
                Button {
                    press(.launchApp(app))
                } label: {
                    Text(app.label)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Color(hex: 0xB9B9C1))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(PressableStyle())
            }
            // Live IME: the icon lights up while the TV reports a focused
            // text field (writes are possible), stays muted otherwise. The
            // sheet is always reachable — it also hosts search, which needs
            // no TV-side field.
            Button {
                showKeyboard = true
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(controller.focusedTextField != nil ? Theme.accent : Theme.iconMuted)
                    .frame(width: 50, height: 50)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(controller.focusedTextField != nil
                ? "Keyboard — TV text field is live"
                : "Keyboard and search")
        }
    }
}
