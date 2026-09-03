import Testing
@testable import RemoteCore

/// "raw: a2 01 56 ..." or bare "a2 01 56" → bytes.
func hexBytes(_ hex: String) -> [UInt8] {
    hex.replacingOccurrences(of: "raw:", with: "")
        .split(separator: " ")
        .compactMap { UInt8($0, radix: 16) }
}

@Test func varintRoundTripsBoundaryValues() {
    for value: UInt64 in [0, 1, 127, 128, 300, 639, 16_383, 16_384] {
        let encoded = Wire.encodeVarint(value)
        var index = 0
        #expect(Wire.decodeVarint(encoded, &index) == value)
        #expect(index == encoded.count)
    }
    #expect(Wire.encodeVarint(300) == [0xAC, 0x02])
}

@Test func decodeVarintReturnsNilOnTruncation() {
    var index = 0
    #expect(Wire.decodeVarint([0x80], &index) == nil)  // continuation bit, no next byte
}

@Test func fieldsParsesACapturedStatusMessage() {
    // docs/ime-captures.md — typing "й" in the browser (field 22, counter 16).
    let message = hexBytes("b2 01 1a 12 18 08 10 12 02 d0 b9 18 01 20 01 28 01 32 0a d0 9f d0 be d1 88 d1 83 d0 ba")
    let top = Wire.fields(message)
    #expect(top.count == 1)
    #expect(top[0].number == 22)
    #expect(top[0].wireType == 2)
    let inner = Wire.fields(top[0].payload)          // the RemoteImeShowRequest body
    #expect(inner[0].number == 2)
    let status = Wire.fields(inner[0].payload)
    #expect(status.first { $0.number == 1 }?.varint == 16)
    #expect(String(bytes: status.first { $0.number == 2 }!.payload, encoding: .utf8) == "й")
}

@Test func deframeSplitsWholeMessagesAndKeepsPartialTail() {
    let messageA = hexBytes("aa 01 04 08 01 10 00")          // ime state {1,0}
    let messageB = hexBytes("12 00")                          // set_active
    var buffer: [UInt8] = [0x07] + messageA + [0x02] + messageB + [0x1a, 0xb2]  // partial frame
    let messages = Wire.deframe(&buffer)
    #expect(messages == [messageA, messageB])
    #expect(buffer == [0x1a, 0xb2])                           // tail survives for the next chunk
    buffer = [0x00]                                           // zero-length frame must not loop
    #expect(Wire.deframe(&buffer).isEmpty)
    #expect(buffer.isEmpty)                                   // and the prefix byte must be consumed
}

@Test func deframeDoesNotStallBehindALeadingZeroLengthFrame() {
    // A leading 0x00 (zero-length frame) must be consumed, not just
    // skipped, so a complete valid frame right behind it is still reached.
    let messageA = hexBytes("aa 01 04 08 01 10 00")
    var buffer: [UInt8] = [0x00, 0x07] + messageA
    #expect(Wire.deframe(&buffer) == [messageA])
    #expect(buffer.isEmpty)
}

@Test func deframeRejectsAnOversizedLengthPrefixWithoutCrashing() {
    // A 10-byte varint can legitimately decode above Int.max. Int(_:)
    // traps on that; deframe must treat it as an incomplete/malformed
    // frame instead, the same as any other length that doesn't fit.
    var buffer: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
    #expect(Wire.deframe(&buffer).isEmpty)
    #expect(buffer.count == 10)                               // untouched, treated as a partial frame
}

@Test func fieldsRejectsAnOversizedLengthWithoutCrashingAndKeepsThePartialList() {
    // field 1 (varint, value 5), then field 2 (length-delimited) whose
    // length is the maximal 10-byte varint — far larger than the buffer.
    let bytes = hexBytes("08 05 12 ff ff ff ff ff ff ff ff ff 01")
    let fields = Wire.fields(bytes)
    #expect(fields == [Wire.Field(number: 1, wireType: 0, varint: 5, payload: [])])
}
