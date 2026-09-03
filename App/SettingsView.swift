import RemoteCore
import SwiftUI

struct SettingsView: View {
    let controller: any TVController
    let device: PairedDevice
    var onChangeTV: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hapticsEnabled = Preferences().hapticsEnabled
    @State private var dpadStyle = Preferences().dpadStyle
    @State private var trackpadAcceleration = Preferences().trackpadAcceleration

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Remote")
                        .font(.system(size: 16))
                }
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())

            Text("Settings")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 10)

            group("TV") {
                HStack {
                    HStack(spacing: 12) {
                        Image(systemName: "tv")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.iconSubtle)
                        Text(device.name)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(controller.connectionState == .connected ? Theme.connected : Theme.textTertiary)
                            .frame(width: 6, height: 6)
                        Text(controller.connectionState == .connected ? "Connected" : "Not connected")
                            .font(.system(size: 13))
                            .foregroundStyle(controller.connectionState == .connected ? Theme.textSecondary : Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 56)

                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 48)

                // "Add a TV…" was a lie: DeviceStore holds exactly one
                // device, so this replaces the TV above rather than adding to
                // it. It no longer unpairs on the way in, but it is still a
                // swap, and the label has to say so.
                Button(action: onChangeTV) {
                    HStack {
                        Text("Change TV…")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.accent)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 56)
                }
                .buttonStyle(PressableStyle())
            }

            group("REMOTE") {
                Toggle(isOn: $hapticsEnabled) {
                    Text("Haptic feedback")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                }
                .tint(Theme.accent)
                .padding(.horizontal, 16)
                .frame(height: 56)
                .onChange(of: hapticsEnabled) { _, newValue in
                    Preferences().hapticsEnabled = newValue
                }

                Divider().overlay(Color.white.opacity(0.06))

                VStack(alignment: .leading, spacing: 8) {
                    Text("D-pad style")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                    Picker("D-pad style", selection: $dpadStyle) {
                        Text("Buttons").tag(DpadStyle.buttons)
                        Text("Trackpad").tag(DpadStyle.trackpad)
                    }
                    .pickerStyle(.segmented)
                    // Says what changes rather than naming the two surfaces
                    // again: "Trackpad" alone reads like the browser cursor,
                    // which is a different thing on the same screen.
                    Text(dpadStyle == .buttons
                         ? "Four arrows. Hold one to keep moving."
                         : "Swipe to move, tap to select. Inside the TV browser, use Pointer mode for a free cursor.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .onChange(of: dpadStyle) { _, newValue in
                    Preferences().dpadStyle = newValue
                }

                // Only shown for the trackpad: a switch that visibly does
                // nothing is worse than one that is absent. The value itself
                // is kept either way, so switching styles does not lose it.
                if dpadStyle == .trackpad {
                    Divider().overlay(Color.white.opacity(0.06))

                    Toggle(isOn: $trackpadAcceleration) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Acceleration")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textPrimary)
                            Text("One long swipe moves several items. Off, each swipe moves one.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .onChange(of: trackpadAcceleration) { _, newValue in
                        Preferences().trackpadAcceleration = newValue
                    }
                }
            }

            group("ABOUT") {
                HStack {
                    Text("Version")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(version)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 56)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func group(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.top, 24)
    }
}
