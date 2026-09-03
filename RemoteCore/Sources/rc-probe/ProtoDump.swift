import Foundation

// Throwaway spike support for `rc-probe dump`. Its job is to make the bytes
// the TV sends legible enough to identify which protobuf fields carry
// text-field status, so the real IME message types can be written against
// facts rather than a guessed proto. Not used by the app.

/// Decodes one base-128 varint starting at `index`, advancing it past the
/// varint. Returns nil if the buffer ends mid-varint — the normal case when a
/// TCP chunk splits a message.
func decodeVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
    var value: UInt64 = 0
    var shift: UInt64 = 0
    while index < bytes.count {
        let byte = bytes[index]
        index += 1
        value |= UInt64(byte & 0x7F) << shift
        if byte & 0x80 == 0 { return value }
        shift += 7
        if shift > 63 { return nil }
    }
    return nil
}

/// The wire framing: every message is varint(length) ++ payload. Pulls as many
/// whole messages out of `buffer` as it holds, leaving any partial tail behind
/// for the next chunk.
func deframe(_ buffer: inout [UInt8]) -> [[UInt8]] {
    var messages: [[UInt8]] = []
    while true {
        var index = 0
        guard let length = decodeVarint(buffer, &index), length > 0 else { break }
        let end = index + Int(length)
        guard end <= buffer.count else { break }
        messages.append(Array(buffer[index..<end]))
        buffer.removeSubrange(0..<end)
    }
    return messages
}

/// Top-level RemoteMessage field numbers we already know from the library's
/// own hand-rolled messages. Anything unlabelled is what the spike is hunting.
/// Top-level RemoteMessage field numbers. 1/2/8/9/10/90 come from the
/// library's own hand-rolled messages; 20/21/40/50 were identified by watching
/// this TV (see docs/phase2-notes.md). Only meaningful at the TOP level —
/// nested submessages reuse the same small numbers for unrelated things, so
/// labels are deliberately not applied when recursing.
let knownFields: [Int: String] = [
    1: "configure",
    2: "set_active",
    8: "ping",
    9: "pong",
    10: "key_inject",
    20: "ime_key_inject",
    21: "ime_batch_edit / ime state",
    40: "start",
    50: "volume",
    90: "app_link",
]

func wireTypeName(_ type: Int) -> String {
    switch type {
    case 0: "varint"
    case 1: "64-bit"
    case 2: "bytes"
    case 5: "32-bit"
    default: "wire\(type)"
    }
}

/// A length-delimited payload that decodes as UTF-8 with no control characters
/// is almost certainly a string, not a nested message. Text-field contents on
/// this TV are frequently Cyrillic, so an ASCII-only test would render them as
/// meaningless byte lists and then try to parse them as protobuf.
func asString(_ bytes: [UInt8]) -> String? {
    guard !bytes.isEmpty, let string = String(bytes: bytes, encoding: .utf8) else { return nil }
    guard !string.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
    return string
}

func renderBytes(_ bytes: [UInt8]) -> String {
    if let string = asString(bytes) { return "\"\(string)\"" }
    return "[\(bytes.map(String.init).joined(separator: " "))]"
}

/// Walks one message's top-level fields. Nested length-delimited fields are
/// descended into one level, which is enough to see a text field's value and
/// counter without a full recursive decoder.
func annotate(_ bytes: [UInt8], indent: String = "  ", topLevel: Bool = true) -> [String] {
    var lines: [String] = []
    var index = 0
    while index < bytes.count {
        guard let tag = decodeVarint(bytes, &index) else {
            lines.append("\(indent)⚠️ truncated tag at \(index)")
            break
        }
        let field = Int(tag >> 3)
        let wire = Int(tag & 0x7)
        let label = topLevel ? (knownFields[field].map { " (\($0))" } ?? "") : ""

        switch wire {
        case 0:
            guard let value = decodeVarint(bytes, &index) else {
                lines.append("\(indent)⚠️ truncated varint"); return lines
            }
            lines.append("\(indent)field \(field)\(label) \(wireTypeName(wire)) = \(value)")
        case 2:
            guard let length = decodeVarint(bytes, &index),
                  index + Int(length) <= bytes.count else {
                lines.append("\(indent)⚠️ truncated bytes"); return lines
            }
            let payload = Array(bytes[index..<(index + Int(length))])
            index += Int(length)
            lines.append("\(indent)field \(field)\(label) \(wireTypeName(wire)) len=\(length) \(renderBytes(payload))")
            // Recurse only into things that are not plainly strings — otherwise
            // a field's text contents get "decoded" into nonsense warnings.
            if !payload.isEmpty, asString(payload) == nil {
                lines.append(contentsOf: annotate(payload, indent: indent + "    ", topLevel: false))
            }
        case 1, 5:
            let width = wire == 1 ? 8 : 4
            guard index + width <= bytes.count else {
                lines.append("\(indent)⚠️ truncated fixed"); return lines
            }
            let payload = Array(bytes[index..<(index + width)])
            index += width
            lines.append("\(indent)field \(field)\(label) \(wireTypeName(wire)) = \(renderBytes(payload))")
        default:
            lines.append("\(indent)⚠️ unknown wire type \(wire) on field \(field)")
            return lines
        }
    }
    return lines
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}


// MARK: - Write-direction spike (settext)

/// One decoded protobuf field at a single level. Unlike annotate(), this is
/// for machine consumption — tracking counters and building echoes.
struct WireField {
    let number: Int
    let wire: Int
    let varint: UInt64
    let payload: [UInt8]
}

func wireFields(_ bytes: [UInt8]) -> [WireField] {
    var fields: [WireField] = []
    var i = 0
    while i < bytes.count {
        guard let tag = decodeVarint(bytes, &i) else { break }
        let number = Int(tag >> 3), wire = Int(tag & 7)
        switch wire {
        case 0:
            guard let value = decodeVarint(bytes, &i) else { return fields }
            fields.append(WireField(number: number, wire: 0, varint: value, payload: []))
        case 2:
            guard let length = decodeVarint(bytes, &i), i + Int(length) <= bytes.count else { return fields }
            fields.append(WireField(number: number, wire: 2, varint: 0, payload: Array(bytes[i..<(i + Int(length))])))
            i += Int(length)
        case 1, 5:
            let width = wire == 1 ? 8 : 4
            guard i + width <= bytes.count else { return fields }
            fields.append(WireField(number: number, wire: wire, varint: 0, payload: Array(bytes[i..<(i + width)])))
            i += width
        default:
            return fields
        }
    }
    return fields
}

struct FieldStatus {
    let counter: UInt64
    let value: String
}

/// Pulls the text-field status (sub-field 2) out of a top-level field 20/22
/// payload — the shape confirmed by capture on the real TV.
func extractStatus(fromTopPayload payload: [UInt8]) -> FieldStatus? {
    guard let status = wireFields(payload).first(where: { $0.number == 2 && $0.wire == 2 }) else { return nil }
    let inner = wireFields(status.payload)
    let counter = inner.first { $0.number == 1 && $0.wire == 0 }?.varint ?? 0
    let value = inner.first { $0.number == 2 && $0.wire == 2 }
        .flatMap { String(bytes: $0.payload, encoding: .utf8) } ?? ""
    return FieldStatus(counter: counter, value: value)
}

func varintBytes(_ value: UInt64) -> [UInt8] {
    if value == 0 { return [0] }
    var bytes: [UInt8] = []
    var v = value
    while v != 0 {
        var byte = UInt8(v & 0x7F)
        v >>= 7
        if v != 0 { byte |= 0x80 }
        bytes.append(byte)
    }
    return bytes
}

func tagged(_ number: Int, varint value: UInt64) -> [UInt8] {
    varintBytes(UInt64(number << 3)) + varintBytes(value)
}

func tagged(_ number: Int, bytes: [UInt8]) -> [UInt8] {
    varintBytes(UInt64((number << 3) | 2)) + varintBytes(UInt64(bytes.count)) + bytes
}

/// RemoteImeBatchEdit (top-level field 21), per the published proto
/// (tronikos/androidtvremote2) and the working sendText in kud/androidtv-remote:
///   21 { 1: ime_counter, 2: field_counter,
///        3: RemoteEditInfo { 1: insert = 1,
///                            2: RemoteImeObject { 1: start, 2: end, 3: value } } }
/// The counters echo the TV's most recent field-21 message; start = end =
/// value.count places the caret after the inserted text.
func imeBatchEdit(imeCounter: UInt64, fieldCounter: UInt64, caret: UInt64, text: String) -> Data {
    var object = tagged(1, varint: caret) + tagged(2, varint: caret)
    object += tagged(3, bytes: Array(text.utf8))
    let edit = tagged(1, varint: 1) + tagged(2, bytes: object)
    let batch = tagged(1, varint: imeCounter) + tagged(2, varint: fieldCounter) + tagged(3, bytes: edit)
    return Data(tagged(21, bytes: batch))
}


/// RemoteImeShowRequest (top-level field 22) echoing the field's status —
/// a candidate preamble announcing "my IME is engaged with this field".
func imeShowRequest(statusCounter: UInt64, value: String) -> Data {
    var status = tagged(1, varint: statusCounter)
    status += tagged(2, bytes: Array(value.utf8))
    status += tagged(3, varint: 0) + tagged(4, varint: 0) + tagged(5, varint: 1)
    return Data(tagged(22, bytes: tagged(2, bytes: status)))
}

/// Batch edit with the RemoteImeObject reduced to value-only (no start/end),
/// and optionally no insert field — the remaining untried shapes.
func imeBatchEditMinimal(imeCounter: UInt64, fieldCounter: UInt64, text: String, includeInsert: Bool) -> Data {
    let object = tagged(3, bytes: Array(text.utf8))
    var edit: [UInt8] = includeInsert ? tagged(1, varint: 1) : []
    edit += tagged(2, bytes: object)
    let batch = tagged(1, varint: imeCounter) + tagged(2, varint: fieldCounter) + tagged(3, bytes: edit)
    return Data(tagged(21, bytes: batch))
}


/// Batch edit that replaces the field's whole contents: RemoteImeObject with
/// start 0, end = current length, value = the new text.
func imeBatchEditReplace(imeCounter: UInt64, fieldCounter: UInt64, currentLength: UInt64, text: String) -> Data {
    var object = tagged(1, varint: 0) + tagged(2, varint: currentLength)
    object += tagged(3, bytes: Array(text.utf8))
    let edit = tagged(1, varint: 1) + tagged(2, bytes: object)
    let batch = tagged(1, varint: imeCounter) + tagged(2, varint: fieldCounter) + tagged(3, bytes: edit)
    return Data(tagged(21, bytes: batch))
}
