import SwiftUI

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CircleControlButton: View {
    let icon: String
    var size: CGFloat = 54
    var iconSize: CGFloat = 20
    var tint: Color = Theme.iconMuted
    var background: Color = Theme.control
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(background, in: Circle())
                .frame(width: max(size, 44), height: max(size, 44))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct RockerControl: View {
    let label: String
    let topIcon: String
    let bottomIcon: String
    let topLabel: String
    let bottomLabel: String
    let topAction: () -> Void
    let bottomAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: topAction) {
                Image(systemName: topIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 60, height: 46)
                    // See the note on `bottomIcon` below — the same fix, for
                    // the same reason.
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(topLabel)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.textTertiary)
                .frame(height: 36)
            Button(action: bottomAction) {
                Image(systemName: bottomIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 60, height: 46)
                    // MANDATORY, not decoration. Without an explicit content
                    // shape a Button whose label is a bare Image hit-tests
                    // against the RENDERED GLYPH, not this 60x46 frame — and
                    // the glyphs are not equally hittable:
                    //
                    //   plus          a full cross            easy to hit
                    //   minus         ONE HAIRLINE BAR        nearly unhittable
                    //   chevron.up/down                       both fine
                    //
                    // Shipped that way, and it read as a protocol bug: volume
                    // up worked 5 presses out of 5 while volume down took ~10
                    // taps to register one, with no press animation and no
                    // haptic — because the tap never reached the button. The
                    // TV and the wire were both innocent (4 rapid VOLUME_DOWN
                    // over the protocol moved the TV 6 -> 2 every time).
                    //
                    // Every other tappable surface in this app already sets a
                    // content shape; this was the one that did not.
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(bottomLabel)
        }
        .frame(width: 60, height: 128)
        .background(Theme.control, in: Capsule())
    }
}
