import RemoteCore
import SwiftUI
import UIKit

struct ConnectView: View {
    let controller: any TVController
    /// Non-nil only when a previously paired TV is still saved, i.e. when this
    /// screen was opened from Settings to change TVs rather than on a first
    /// launch. It is what makes the back button below possible: there is no
    /// way out of a screen whose only exit is a successful pairing, and the TV
    /// the user came looking for may simply not be findable.
    var onCancel: (() -> Void)?
    var onPaired: (PairedDevice) -> Void

    private enum Phase: Equatable {
        case browsing, requesting, codeEntry, submitting
    }

    @State private var phase: Phase = .browsing
    @State private var selected: DiscoveredDevice?
    @State private var code = ""
    @State private var errorText: String?
    @FocusState private var codeFocused: Bool
    /// Identifies the in-flight `select(_:)` attempt. A superseded attempt's
    /// completion (delivered after the user has already tapped a different
    /// device) must not write `phase`, `selected`, or `errorText` — those
    /// belong to whichever attempt is current.
    @State private var currentAttempt = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onCancel {
                Button(action: onCancel) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Remote")
                            .font(.system(size: 16))
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: 44)
                    // The volume-down lesson: an HStack of a glyph and a short
                    // word only takes taps on the glyph and the word without
                    // this. The 44pt frame is not a hit target on its own.
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Back to remote")
                .padding(.bottom, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Connect your TV")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Your iPhone and TV need to be on the same Wi-Fi network.")
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 8)

                    if controller.discoveryPermissionDenied {
                        permissionCard.padding(.top, 28)
                    } else {
                        searchStatus.padding(.top, 28)
                        if phase == .browsing, let errorText {
                            Text(errorText)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.accent)
                                .padding(.top, 8)
                        }
                        sectionHeader.padding(.top, 24)
                        deviceList.padding(.top, 8)
                        if phase == .requesting {
                            lookAtTVCard.padding(.top, 24)
                        }
                        if phase == .codeEntry || phase == .submitting {
                            pairingCard.padding(.top, 24)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            if phase == .codeEntry || phase == .submitting {
                pairButton.padding(.top, 12)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(Theme.background.ignoresSafeArea())
        .task { controller.startDiscovery() }
        .onDisappear {
            controller.stopDiscovery()
            controller.cancelPairing()
        }
    }

    // MARK: Actions

    /// `.requesting` is allowed through: the pairing handshake can take many
    /// seconds, and leaving every row inert with no way out is a dead end.
    /// `beginPairing` calls `cancelPairing()` first, so re-selecting is safe.
    private func select(_ device: DiscoveredDevice) {
        guard phase == .browsing || phase == .requesting || phase == .codeEntry else { return }
        let attempt = UUID()
        currentAttempt = attempt
        selected = device
        errorText = nil
        code = ""
        phase = .requesting
        Task {
            do {
                try await controller.beginPairing(with: device)
                // `catch TVControllerError.cancelled` closes the common
                // supersede path, but two windows remain where a superseded
                // attempt's completion arrives after a newer one is already
                // in flight: (a) success delivered just as the user taps a
                // different device, before that device's `beginPairing` has
                // run its `cancelPairing()`, and (b) a `.failed` completion
                // queued on the main actor racing a fresh tap. Guarding on
                // `currentAttempt` (an identity token minted per attempt)
                // rather than on `phase` closes both: only the attempt that
                // is still current may write phase/selected/errorText.
                guard currentAttempt == attempt else { return }
                phase = .codeEntry
                // The code TextField only exists once SwiftUI has rendered the
                // .codeEntry phase; focusing in the same update targets a field
                // that isn't there yet and the keyboard may not present.
                try? await Task.sleep(for: .milliseconds(50))
                guard currentAttempt == attempt, phase == .codeEntry else { return }
                codeFocused = true
            } catch TVControllerError.cancelled {
                // We were superseded — by the Cancel button, or by a newer
                // beginPairing that cancelled us on its way in. Whoever
                // cancelled us owns the phase now; don't stomp on it.
            } catch {
                guard currentAttempt == attempt else { return }
                phase = .browsing
                selected = nil
                errorText = "Couldn't reach the TV. Make sure it's on and try again."
            }
        }
    }

    private func cancelRequesting() {
        // Mint a fresh token so a cancelled attempt's late completion (its
        // `catch` clause, or a success that raced the cancel) cannot write
        // phase/selected/errorText out from under this reset.
        currentAttempt = UUID()
        controller.cancelPairing()
        selected = nil
        code = ""
        phase = .browsing
    }

    private func submit() {
        guard code.count == 6 else { return }
        phase = .submitting
        errorText = nil
        Task {
            do {
                let device = try await controller.submitPairingCode(code)
                onPaired(device)
            } catch TVControllerError.wrongCode {
                // The TV closes the pairing socket the moment it rejects a
                // code — the round is over, so resubmitting on this session
                // would just throw `.cancelled`. A retry has to go back
                // through `beginPairing`, which is what re-selecting the
                // device from the list does (and makes the TV show a fresh
                // code, since we can't assume the old one is still on screen).
                phase = .browsing
                selected = nil
                code = ""
                errorText = "That code didn't match. Select your TV again for a new code."
            } catch {
                phase = .browsing
                selected = nil
                code = ""
                errorText = "Pairing failed. Select your TV to try again."
            }
        }
    }

    // MARK: Subviews

    private var searchStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi").font(.system(size: 14))
            Text(controller.discoveredDevices.isEmpty ? "Searching on your Wi-Fi…" : "Found on your Wi-Fi")
                .font(.system(size: 13))
        }
        .foregroundStyle(Theme.textSecondary)
    }

    private var sectionHeader: some View {
        Text("ON YOUR NETWORK")
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 4)
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local network access is off")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("RemoteControl needs local network access to find your TV. Enable it in Settings.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var lookAtTVCard: some View {
        HStack(spacing: 12) {
            ProgressView().tint(Theme.accent)
            Text("Look at your TV — asking it to show a pairing code…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 4)
            Button(action: cancelRequesting) {
                Text("Cancel")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Cancel pairing")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var deviceList: some View {
        VStack(spacing: 0) {
            ForEach(Array(controller.discoveredDevices.enumerated()), id: \.element.id) { index, device in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1)
                        .padding(.leading, 66)
                }
                Button {
                    select(device)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "tv")
                            .font(.system(size: 16))
                            .foregroundStyle(selected?.id == device.id ? Theme.accent : Theme.textTertiary)
                            .frame(width: 38, height: 38)
                            .background(Theme.controlHigh, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(device.host)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: selected?.id == device.id ? "checkmark" : "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(selected?.id == device.id ? Theme.accent : Theme.chevron)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 64)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Pair with \(device.name)")
            }
            if controller.discoveredDevices.isEmpty {
                HStack {
                    ProgressView().tint(Theme.textSecondary)
                    Spacer()
                }
                .padding(16)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Enter the pairing code")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Your TV is showing a 6-character code")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    let digits = Array(code)
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.controlHigh)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(index == code.count ? Theme.accent : .clear, lineWidth: 1.5)
                        )
                        .overlay(
                            Text(index < digits.count ? String(digits[index]) : "")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        )
                        .frame(height: 54)
                }
            }
            .padding(.top, 14)
            .background(
                TextField("", text: $code)
                    .keyboardType(.asciiCapable)          // hex codes: letters happen
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($codeFocused)
                    .disabled(phase == .submitting)
                    .opacity(0.01)
                    .accessibilityLabel("Pairing code")
            )
            .onTapGesture { codeFocused = true }
            .onChange(of: code) { _, newValue in
                code = String(newValue.uppercased().filter(\.isHexDigit).prefix(6))
            }
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var pairButton: some View {
        Button(action: submit) {
            Text(phase == .submitting ? "Pairing…" : "Pair")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.background)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    Theme.accent.opacity(code.count == 6 && phase == .codeEntry ? 1 : 0.35),
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        .buttonStyle(PressableStyle())
        .disabled(code.count != 6 || phase != .codeEntry)
    }
}
