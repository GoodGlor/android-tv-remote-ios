import Foundation

/// Encoders for the TV browser's OWN remote protocol — not Android TV Remote
/// v2. Different port, different wire format, different server (a Ktor
/// endpoint inside `com.internet.tvbrowser`). See
/// docs/tvbrowser-remote-protocol.md; every byte below is pinned to a frame
/// that moved a real TV's cursor.
///
/// Why this exists at all: Remote v2 physically cannot move a pointer. Its
/// uinput device declares KEY events only — no REL, no ABS — so no message
/// over that protocol can do this. This one takes relative FLOAT deltas.
enum CursorMessages {
    /// `RemoteEvent{ cursor_move = 1 }` wrapping
    /// `CursorMove{ action = MOVE, dx, dy }`.
    ///
    /// Deltas are relative and, on the verified TV, 1:1 with screen pixels
    /// (20 sends of (7.1, 14.05) moved the cursor exactly +142, +281). `dy > 0`
    /// is DOWN — the same sense as phone screen coordinates, so callers need
    /// no axis flip.
    static func move(dx: Float, dy: Float) -> Data {
        var body = Wire.field(1, varint: UInt64(MotionAction.move.rawValue))
        body += fixed32(2, dx)
        body += fixed32(3, dy)
        return Data(Wire.field(1, bytes: body))
    }

    /// `RemoteEvent{ cursor_click = 4 }` wrapping an EMPTY `CursorClick`.
    ///
    /// The message genuinely has no fields, so the click lands wherever the
    /// cursor already is. Two bytes total: field 4, wire type 2, length 0.
    static func click() -> Data {
        Data(Wire.field(4, bytes: []))
    }

    /// Android `MotionEvent` actions, as the TV browser's enum orders them.
    /// Only `.move` is used today; the rest are named because the wire values
    /// are theirs and a future drag would need `down`/`up`.
    private enum MotionAction: Int {
        case down = 0, up = 1, move = 2, cancel = 3
        case outside = 4, pointerDown = 5, pointerUp = 6
    }

    /// A protobuf fixed32 field carrying an IEEE-754 float, little-endian.
    /// Wire type 5, so the tag is `number << 3 | 5`.
    private static func fixed32(_ number: Int, _ value: Float) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(number << 3 | 5)]
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        return bytes
    }
}
