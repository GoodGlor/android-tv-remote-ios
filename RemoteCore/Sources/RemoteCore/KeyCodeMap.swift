@preconcurrency import AndroidTVRemoteControl

/// Pure mapping from the UI's command vocabulary to Android TV keycodes and
/// app deep links. No state, no networking.
enum KeyCodeMap {
    static func key(for command: KeyCommand) -> Key? {
        switch command {
        case .power: .KEYCODE_POWER
        case .up: .KEYCODE_DPAD_UP
        case .down: .KEYCODE_DPAD_DOWN
        case .left: .KEYCODE_DPAD_LEFT
        case .right: .KEYCODE_DPAD_RIGHT
        case .ok: .KEYCODE_DPAD_CENTER
        case .back: .KEYCODE_BACK
        case .home: .KEYCODE_HOME
        // KEYCODE_MENU is vestigial on Android TV — verified against a Xiaomi
        // TV P1e 32, where 82 (MENU), 176 (SETTINGS), 187 (APP_SWITCH) and
        // 284 (ALL_APPS) were all accepted and silently ignored. A long press
        // of OK is what actually opens a context menu, and it is what the
        // button does on real Android TV remotes. See `usesLongPress`.
        case .menu: .KEYCODE_DPAD_CENTER
        case .volumeUp: .KEYCODE_VOLUME_UP
        case .volumeDown: .KEYCODE_VOLUME_DOWN
        case .mute: .KEYCODE_VOLUME_MUTE   // NOT KEYCODE_MUTE (91) — that's mic mute
        case .channelUp: .KEYCODE_CHANNEL_UP
        case .channelDown: .KEYCODE_CHANNEL_DOWN
        case .rewind: .KEYCODE_MEDIA_REWIND
        case .playPause: .KEYCODE_MEDIA_PLAY_PAUSE
        case .fastForward: .KEYCODE_MEDIA_FAST_FORWARD
        case .input: .KEYCODE_TV_INPUT
        case .launchApp: nil
        }
    }

    /// Commands whose keycode must be sent as a long press rather than a tap.
    /// Only the menu button: it maps to OK, and OK-held is the context menu.
    static func usesLongPress(_ command: KeyCommand) -> Bool {
        if case .menu = command { return true }
        return false
    }

    /// Deep links sent via the library's DeepLink message. All three are
    /// verified working against a Xiaomi MiTV-MOSR1. Note that an unsupported
    /// URI is not a silent no-op — the TV drops the control session — so only
    /// add links that have been tried against real hardware.
    static func appLink(for app: AppShortcut) -> String {
        switch app {
        case .netflix: "https://www.netflix.com/title"   // pattern proven in the library's demo
        case .youtube: "https://www.youtube.com"
        // "about:blank" opens the browser itself on an empty page rather than
        // dropping the user onto a website — verified working. The protocol
        // has no "launch this app" message: the app-link message carries a
        // URI, so some destination is unavoidable, and the two mechanisms
        // that launch by identity instead (`intent:` and `android-app://`)
        // make the TV drop the control session. Android TV ships no browser
        // by default, so this tile does nothing on a TV without one.
        case .browser: "about:blank"
        }
    }

    /// ASCII-only fallback for text entry: the v2 library has no IME message.
    /// Unsupported characters (including Cyrillic) are skipped by design —
    /// the keyboard task (Task 12) decides the final text strategy.
    static func asciiKeys(for text: String) -> [Key] {
        text.lowercased().compactMap { char in
            switch char {
            case "a"..."z":
                Key(rawValue: UInt(Key.KEYCODE_A.rawValue) + UInt(char.asciiValue! - Character("a").asciiValue!))
            case "0"..."9":
                Key(rawValue: UInt(Key.KEYCODE_0.rawValue) + UInt(char.asciiValue! - Character("0").asciiValue!))
            case " ": .KEYCODE_SPACE
            case ".": .KEYCODE_PERIOD
            case ",": .KEYCODE_COMMA
            default: nil
            }
        }
    }
}
