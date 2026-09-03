import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Color tokens from the locked design (spec: "Visual design").
enum Theme {
    static let background = Color(hex: 0x0C0D11)
    static let surface = Color(hex: 0x14151A)       // cards, D-pad body
    static let control = Color(hex: 0x16171C)       // buttons, rockers, tiles
    static let controlHigh = Color(hex: 0x1D1E24)   // elevated (play/pause, icon wells)
    static let sheet = Color(hex: 0x1B1C22)
    static let textPrimary = Color(hex: 0xF2F2F5)
    static let textSecondary = Color(hex: 0x8E8E96)
    static let textTertiary = Color(hex: 0x6E6E78)
    static let iconMuted = Color(hex: 0xC9C9D1)
    static let accent = Color(hex: 0xFF8B3D)
    static let connected = Color(hex: 0x34C759)
    static let power = Color(hex: 0xFF6B61)
    static let powerBackground = Color(hex: 0xFF453A, opacity: 0.14)
    static let hairline = Color.white.opacity(0.06)
    static let chevron = Color(hex: 0x5C5C66)
    static let sheetBackground = Color(hex: 0x111218)
    static let sheetPlaceholder = Color(hex: 0x7C7C86)
    // NOTE: named `iconSubtle` (not `iconMuted`) because `iconMuted` already exists
    // above at 0xC9C9D1 and is used by CircleControlButton's default tint,
    // DPadView's direction chevrons, and the keyboard tile icon. Reusing the name
    // for this different hex value would have silently recolored all of those.
    static let iconSubtle = Color(hex: 0xA9A9B2)
}
