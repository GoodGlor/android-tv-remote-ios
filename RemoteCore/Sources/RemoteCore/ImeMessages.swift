import Foundation

/// The focused TV text field as last reported. Absolute state — the TV sends
/// the complete value on every edit (spike-verified), so this never drifts.
public struct TextFieldStatus: Equatable, Sendable {
    public let counter: UInt64
    public let value: String
    public let selectionStart: Int
    public let selectionEnd: Int
    public let hint: String
    /// Owning app. Field-22 statuses don't carry it; ImeChannel patches it
    /// from the last app-info message, so "" only ever appears pre-merge.
    public internal(set) var packageName: String

    public init(counter: UInt64, value: String, selectionStart: Int, selectionEnd: Int,
                hint: String, packageName: String) {
        self.counter = counter
        self.value = value
        self.selectionStart = selectionStart
        self.selectionEnd = selectionEnd
        self.hint = hint
        self.packageName = packageName
    }
}

/// The three incoming IME messages (RemoteMessage fields 20/21/22).
public enum ImeMessage: Equatable, Sendable {
    /// Field 20 (focus, with status) or field 22 (one per edit).
    case fieldStatus(TextFieldStatus)
    /// Field 20 with app info only — the foreground app has no reported
    /// field; treat as focus lost.
    case appChanged(packageName: String)
    /// Field 21 — the (ime_counter, field_counter) pair. NOT a focus signal:
    /// the TV sends {0,0} both on blur and as the write-handshake reply.
    case imeState(UInt64, UInt64)
}

enum ImeDecoder {
    static func decode(_ message: [UInt8]) -> ImeMessage? {
        guard let top = Wire.fields(message).first else { return nil }
        switch (top.number, top.wireType) {
        case (21, 2):
            let inner = Wire.fields(top.payload)
            return .imeState(inner.first { $0.number == 1 }?.varint ?? 0,
                             inner.first { $0.number == 2 }?.varint ?? 0)
        case (20, 2), (22, 2):
            let inner = Wire.fields(top.payload)
            // Field 20 nests app info at 1 (package at its sub-field 12).
            let package = inner.first { $0.number == 1 && $0.wireType == 2 }
                .flatMap { appInfo in
                    Wire.fields(appInfo.payload).first { $0.number == 12 && $0.wireType == 2 }
                }
                .flatMap { String(bytes: $0.payload, encoding: .utf8) }
            guard let statusField = inner.first(where: { $0.number == 2 && $0.wireType == 2 }) else {
                guard top.number == 20, let package else { return nil }
                return .appChanged(packageName: package)
            }
            let status = Wire.fields(statusField.payload)
            return .fieldStatus(TextFieldStatus(
                counter: status.first { $0.number == 1 }?.varint ?? 0,
                value: status.first { $0.number == 2 && $0.wireType == 2 }
                    .flatMap { String(bytes: $0.payload, encoding: .utf8) } ?? "",
                // Int(exactly:) rather than Int(_:): these varints come off
                // the same untrusted socket bytes as everything else in this
                // decoder, and a corrupted/adversarial value above Int.max
                // must not trap. Falling back to 0 is safe — a selection
                // index the TV never legitimately sends is meaningless
                // either way.
                selectionStart: Int(exactly: status.first { $0.number == 3 }?.varint ?? 0) ?? 0,
                selectionEnd: Int(exactly: status.first { $0.number == 4 }?.varint ?? 0) ?? 0,
                hint: status.first { $0.number == 6 && $0.wireType == 2 }
                    .flatMap { String(bytes: $0.payload, encoding: .utf8) } ?? "",
                packageName: package ?? ""))
        default:
            return nil
        }
    }
}

/// Outgoing IME messages, byte-pinned to what the real TV ACCEPTED.
/// This firmware applies the NET length change at the cursor: net-positive
/// appends the value, net-negative deletes from the tail (the value is
/// ignored). Hence exactly two write shapes — append and tail-delete.
enum ImeEncoder {
    /// The handshake opener. Counter echoes the field's current status
    /// counter; the value MUST be empty (a non-empty echo is ignored).
    static func showRequest(statusCounter: UInt64) -> Data {
        var status = Wire.field(1, varint: statusCounter)
        status += Wire.field(2, bytes: [])
        status += Wire.field(3, varint: 0) + Wire.field(4, varint: 0) + Wire.field(5, varint: 1)
        return Data(Wire.field(22, bytes: Wire.field(2, bytes: status)))
    }

    static func append(imeCounter: UInt64, fieldCounter: UInt64, text: String) -> Data {
        batchEdit(imeCounter: imeCounter, fieldCounter: fieldCounter, start: 0, end: 0, text: text)
    }

    static func deleteTail(imeCounter: UInt64, fieldCounter: UInt64, count: Int) -> Data {
        batchEdit(imeCounter: imeCounter, fieldCounter: fieldCounter,
                  start: 0, end: UInt64(count), text: "")
    }

    private static func batchEdit(imeCounter: UInt64, fieldCounter: UInt64,
                                  start: UInt64, end: UInt64, text: String) -> Data {
        var object = Wire.field(1, varint: start) + Wire.field(2, varint: end)
        object += Wire.field(3, bytes: Array(text.utf8))
        let edit = Wire.field(1, varint: 1) + Wire.field(2, bytes: object)
        let batch = Wire.field(1, varint: imeCounter) + Wire.field(2, varint: fieldCounter)
                  + Wire.field(3, bytes: edit)
        return Data(Wire.field(21, bytes: batch))
    }
}
