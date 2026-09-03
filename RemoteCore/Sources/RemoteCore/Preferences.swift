import Foundation

/// The two navigation input modes. `dpad` holds a direction key and lets the
/// TV auto-repeat-glide it; `pointer` drags a real 2D cursor over the TV
/// browser's cursor service. `pointer` is offered only while that service is
/// live — see `effectiveControlMode` below — so it never falls back to
/// holding a key the way it once did. A raw stored value naming the removed
/// one-swipe-one-step surface that used to sit between them is handled by
/// `Preferences.controlMode`.
public enum ControlMode: String, CaseIterable, Sendable {
    case dpad, pointer
}

/// How the D-pad block is drawn and driven. Independent of `ControlMode`:
/// this chooses what `.dpad` LOOKS like, while `ControlMode` chooses between
/// D-pad navigation and the browser's free cursor.
///
/// - `buttons` — four arrows, each holding its key so the TV auto-repeats.
/// - `trackpad` — an Apple TV-style surface: one arrow per swipe threshold,
///   tap to select. Moves FOCUS, so it works in every TV app; inside the TV
///   browser use Pointer mode instead, where a real cursor is available.
///   See `SwipePadEngine` for why discrete steps suit focus but not a cursor.
public enum DpadStyle: String, CaseIterable, Sendable {
    case buttons, trackpad
}

/// The mode actually usable right now, given a candidate mode — the
/// persisted preference, or the mode already on screen — and whether the
/// TV browser's cursor service is live.
///
/// Pointer is never offered without a live cursor: a pad that draws but
/// cannot move anything is worse than no pad at all, so any request for
/// `.pointer` while unavailable resolves to `.dpad`. `.dpad` never depends
/// on the cursor and always resolves to itself.
///
/// One function serves two call sites in `RemoteView`: resolving the
/// persisted preference at launch (a stored `.pointer` is a preference, not
/// a promise — the cursor may not be reachable this session), and reacting
/// when availability drops mid-session while the user is already in
/// `.pointer`. Both are "what mode, given this candidate and this
/// availability" — the same question.
public func effectiveControlMode(_ mode: ControlMode, cursorAvailable: Bool) -> ControlMode {
    mode == .pointer && !cursorAvailable ? .dpad : mode
}

/// User-facing app preferences.
public struct Preferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Defaults to true — haptics on out of the box.
    public var hapticsEnabled: Bool {
        get { defaults.object(forKey: "hapticsEnabled") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "hapticsEnabled") }
    }

    /// D-pad presentation. Defaults to `.buttons` — the surface every
    /// existing user already has, so an upgrade changes nothing until they
    /// ask. An unknown stored value falls through to `.buttons` for the same
    /// reason `controlMode` falls through to `.dpad`: land on the familiar
    /// thing rather than on nothing.
    public var dpadStyle: DpadStyle {
        get {
            if let raw = defaults.string(forKey: "dpadStyle"),
               let style = DpadStyle(rawValue: raw) {
                return style
            }
            return .buttons
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "dpadStyle") }
    }

    /// Whether one trackpad swipe may move more than one step. Defaults to
    /// false: distance-proportional stepping overshoots — a natural swipe
    /// across the pad crosses about five thresholds and skips five tiles.
    /// Surfaced as "Acceleration"; see `SwipePadEngine.multiStep`.
    ///
    /// Only meaningful while `dpadStyle == .trackpad`, but stored
    /// unconditionally so switching styles back and forth does not lose it.
    public var trackpadAcceleration: Bool {
        get { defaults.object(forKey: "trackpadAcceleration") as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: "trackpadAcceleration") }
    }

    /// Navigation mode; an explicit set writes the new key and wins thereafter.
    ///
    /// Two kinds of stale value have to land somewhere sane rather than
    /// crashing or resetting to nothing:
    ///
    /// - a `"controlMode"` string naming the removed swipe mode — the
    ///   `rawValue` lookup fails and falls through to `.dpad`;
    /// - the Phase 1 Bool flag this property used to migrate from, whose
    ///   `true` selected that same removed mode — it is no longer read at
    ///   all, so those users also land on `.dpad`. (Its exact key is pinned
    ///   by `controlModeIgnoresTheLegacySwipeModeBool` in PersistenceTests.)
    ///
    /// `.dpad` is the right landing place for both: it is the spec default,
    /// and it is now the mode that behaves most like the surface they lost
    /// (hold a direction, the cursor glides).
    public var controlMode: ControlMode {
        get {
            if let raw = defaults.string(forKey: "controlMode"),
               let mode = ControlMode(rawValue: raw) {
                return mode
            }
            return .dpad
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "controlMode") }
    }
}
