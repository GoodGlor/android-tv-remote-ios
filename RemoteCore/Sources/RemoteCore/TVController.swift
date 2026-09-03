public struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    public let name: String
    public let host: String
    /// Bonjour service instance name — the stable identity used to re-resolve
    /// the host when the router hands the TV a new IP.
    public let serviceName: String
    public var id: String { host }

    public init(name: String, host: String, serviceName: String) {
        self.name = name
        self.host = host
        self.serviceName = serviceName
    }
}

public struct PairedDevice: Codable, Equatable, Sendable {
    public let name: String
    public let host: String
    public let serviceName: String

    public init(name: String, host: String, serviceName: String) {
        self.name = name
        self.host = host
        self.serviceName = serviceName
    }
}

/// Where a phone-composed query is sent. Two targets, because the TV offers
/// exactly two routes that work — and which apps each one reaches was settled
/// against real hardware, not guessed. Both are deep links: the third route
/// once tried (Android TV global search, katniss, written into via IME) was
/// removed after capture showed katniss opens VOICE-FIRST and reports app
/// info only — it never exposes the text field the injection needed, so the
/// query was always dropped. Do not re-attempt it.
public enum SearchTarget: Equatable, Sendable {
    /// Opens YouTube directly on the results page via its search deep link
    /// (real-TV-verified, Cyrillic included). Needs no TV-side text field —
    /// which is the point: YouTube draws a PRIVATE on-screen keyboard and
    /// emits zero IME traffic, so its search box cannot be written into.
    case youtube
    /// Opens the TV's browser straight on a Google results page via
    /// `https://www.google.com/search?q=...` (real-TV-verified). Exists
    /// because submitting the TV's own text field from the phone is not
    /// possible over this protocol — the on-screen keyboard's ✓ key is
    /// handled entirely inside the TV's IME with no message that identifies
    /// or triggers it (KEYCODE_ENTER, NUMPAD_ENTER, KEYCODE_SEARCH, and
    /// driving the D-pad to ✓ were all tried and all failed; see
    /// docs/phase2-notes.md, "Submitting a TV text field — NOT POSSIBLE").
    /// A deep link, like `.youtube`, so no TV-side field is needed either.
    case web
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected, connecting, connected
}

public enum TVControllerError: Error, Equatable, Sendable {
    case pairingFailed(String)
    case wrongCode
    case connectionFailed(String)
    case cancelled
}

/// The seam between UI and transport. `MockTVController` serves previews and
/// tests; `AndroidTVController` is the real Android TV Remote v2 transport.
@MainActor
public protocol TVController: AnyObject {
    var connectionState: ConnectionState { get }
    var discoveredDevices: [DiscoveredDevice] { get }
    /// True when the user denied local-network access, so discovery can never
    /// yield anything and the UI must say so. Part of the seam rather than a
    /// downcast in the view, so the permission UI survives a new transport.
    var discoveryPermissionDenied: Bool { get }

    func startDiscovery()
    func stopDiscovery()

    /// Contacts the TV; on return (no throw) the TV is displaying a 6-char
    /// hexadecimal code.
    func beginPairing(with device: DiscoveredDevice) async throws
    /// Submits the code the TV is showing. Throws `.wrongCode` or
    /// `.pairingFailed`; either way the pairing round is over — the TV closes
    /// the pairing socket when it rejects a code — so a retry starts again
    /// from `beginPairing`, which makes the TV display a code afresh.
    /// Submitting on a finished round throws `.cancelled` rather than hanging.
    func submitPairingCode(_ code: String) async throws -> PairedDevice
    func cancelPairing()

    func connect(to device: PairedDevice) async throws
    func disconnect()

    /// Fire-and-forget: delivery problems surface via `connectionState`.
    func sendKey(_ key: KeyCommand)

    /// Hold `key` (releasing whatever was held), or release everything when
    /// nil. Only `.up`/`.down`/`.left`/`.right` are accepted; anything else
    /// is ignored.
    ///
    /// ONE method, not a hold/release pair, and deliberately so. A held D-pad
    /// key auto-repeats on the TV and glides the browser's cursor for as long
    /// as it is down — so a hold that is never ended leaves the TV scrolling
    /// by itself with no way for the user to stop it. Making the controller
    /// own "what is currently held" removes both ways a caller could get that
    /// wrong: it cannot leak two holds (setting a new direction releases the
    /// old one first) and it cannot forget which key to release (nil releases
    /// whatever is down). The UI never names a key it must later match.
    ///
    /// Idempotent: setting the same direction twice sends nothing extra, so
    /// a drag can call this on every gesture update.
    func setHeldDirection(_ key: KeyCommand?)

    func sendText(_ text: String)

    /// The TV's focused text field as last reported, nil when none (or the
    /// on-screen keyboard is closed — writes are impossible then).
    var focusedTextField: TextFieldStatus? { get }
    /// Replace the focused field's contents (IME clear+append handshake).
    /// Fire-and-forget; a failed write surfaces as focusedTextField → nil.
    func setText(_ text: String)
    /// True while one of OUR writes is in flight — from the moment the write
    /// begins until it completes, aborts, or is cancelled.
    ///
    /// A write is clear-then-append (this firmware has no working range
    /// replace), and the TV echoes the intermediate EMPTY field between the
    /// two edits. That echo is a real, absolute field status, indistinguishable
    /// by value from a TV-side clear — so anything mirroring `focusedTextField`
    /// must use this flag to skip our own transient states instead of guessing.
    var isWriteInFlight: Bool { get }

    /// Compose-on-phone search. Fire-and-forget: both targets are deep links
    /// and land immediately, needing no TV-side text field.
    func search(_ query: String, target: SearchTarget)
}

public extension TVController {
    /// Transports that cannot detect a permission denial (the mock, and any
    /// future non-Bonjour transport) simply never show the permission card.
    var discoveryPermissionDenied: Bool { false }
}
