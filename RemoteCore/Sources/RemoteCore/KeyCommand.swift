public enum AppShortcut: String, CaseIterable, Sendable, Codable {
    case netflix, youtube, browser

    public var label: String {
        switch self {
        case .netflix: "NETFLIX"
        case .youtube: "YOUTUBE"
        case .browser: "BROWSER"
        }
    }
}

/// Every button the remote can send. The Phase-2 controller maps these to
/// Android TV keycodes; Phase 1 only logs them.
public enum KeyCommand: Hashable, Sendable {
    case power, up, down, left, right, ok, back, home, menu
    case volumeUp, volumeDown, mute, channelUp, channelDown
    case rewind, playPause, fastForward, input
    case launchApp(AppShortcut)

    /// The four D-pad directions — the only keys a pointer drag may HOLD.
    /// Holding anything else is meaningless at best (a held HOME does not
    /// glide anything) and destructive at worst, so `setHeldDirection` uses
    /// this to reject non-directional keys outright.
    public var isDirectional: Bool {
        switch self {
        case .up, .down, .left, .right: true
        default: false
        }
    }
}

/// One end of a key hold. Exists so the mock and the test fakes can record a
/// hold/release stream in ORDER: the pointer's whole safety story is "the old
/// direction is released BEFORE the new one is held, and every hold is ended",
/// and only an ordered log can assert that.
public enum KeyHoldEvent: Hashable, Sendable {
    case hold(KeyCommand)
    case release(KeyCommand)
}
