import Foundation

/// Minimal protobuf wire-format helpers for the hand-rolled IME messages.
/// The transport library keeps its encoder internal, and pulling in
/// swift-protobuf for four messages would break the one-dependency rule, so
/// RemoteCore owns the varint + tag arithmetic — pinned by tests to bytes
/// captured from the real TV (docs/ime-captures.md).
enum Wire {
    struct Field: Equatable {
        let number: Int
        let wireType: Int
        let varint: UInt64
        let payload: [UInt8]
    }

    static func encodeVarint(_ value: UInt64) -> [UInt8] {
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

    static func decodeVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
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

    static func field(_ number: Int, varint value: UInt64) -> [UInt8] {
        encodeVarint(UInt64(number << 3)) + encodeVarint(value)
    }

    static func field(_ number: Int, bytes: [UInt8]) -> [UInt8] {
        encodeVarint(UInt64((number << 3) | 2)) + encodeVarint(UInt64(bytes.count)) + bytes
    }

    /// One level of fields. A truncated or unmodeled tail ends the walk
    /// without throwing — TV messages contain field types we don't parse.
    static func fields(_ bytes: [UInt8]) -> [Field] {
        var fields: [Field] = []
        var index = 0
        while index < bytes.count {
            guard let tag = decodeVarint(bytes, &index) else { break }
            let number = Int(tag >> 3), wireType = Int(tag & 7)
            switch wireType {
            case 0:
                guard let value = decodeVarint(bytes, &index) else { return fields }
                fields.append(Field(number: number, wireType: 0, varint: value, payload: []))
            case 2:
                // Compare in UInt64 space before narrowing: a corrupted or
                // adversarial 10-byte varint can decode above Int.max, and
                // Int(_:) traps rather than returning nil. Bounding by the
                // remaining byte count first guarantees the narrowing below
                // is in range.
                guard let length = decodeVarint(bytes, &index),
                      length <= UInt64(bytes.count - index) else { return fields }
                let len = Int(length)
                fields.append(Field(number: number, wireType: 2, varint: 0,
                                    payload: Array(bytes[index..<(index + len)])))
                index += len
            case 1, 5:
                let width = wireType == 1 ? 8 : 4
                guard index + width <= bytes.count else { return fields }
                fields.append(Field(number: number, wireType: wireType, varint: 0,
                                    payload: Array(bytes[index..<(index + width)])))
                index += width
            default:
                return fields
            }
        }
        return fields
    }

    /// The stream framing: every message is varint(length) ++ payload.
    /// Extracts whole messages, leaves a partial tail for the next chunk.
    static func deframe(_ buffer: inout [UInt8]) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        while true {
            var index = 0
            guard let length = decodeVarint(buffer, &index) else { break }
            if length == 0 {
                // A zero-length frame carries no payload to emit, but the
                // prefix byte(s) must still be consumed — otherwise this
                // branch never advances and every call re-decodes the same
                // leading zero forever, stalling the pipeline behind it.
                buffer.removeSubrange(0..<index)
                continue
            }
            // Same overflow hazard as `fields`: compare in UInt64 space
            // before narrowing to Int, since a malformed length prefix off
            // the socket can exceed Int.max and Int(_:) traps.
            guard length <= UInt64(buffer.count - index) else { break }
            let end = index + Int(length)
            messages.append(Array(buffer[index..<end]))
            buffer.removeSubrange(0..<end)
        }
        return messages
    }
}
