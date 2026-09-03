import Foundation
import Testing
@testable import RemoteCore

// Every fixture below is a real TV message from docs/ime-captures.md.

@Test func decodesFocusWithInitialStatus() throws {
    let message = hexBytes("""
        a2 01 56 0a 3c 08 01 10 11 18 86 80 80 60 38 00 40 00 52 0a d0 9f d0 be d1 88 d1 83 d0 ba \
        62 16 63 6f 6d 2e 69 6e 74 65 72 6e 65 74 2e 74 76 62 72 6f 77 73 65 72 68 ff ff ff ff ff \
        ff ff ff ff 01 12 16 08 07 12 00 18 00 20 00 28 01 32 0a d0 9f d0 be d1 88 d1 83 d0 ba
        """)
    guard case .fieldStatus(let status) = try #require(ImeDecoder.decode(message)) else {
        Issue.record("expected fieldStatus"); return
    }
    #expect(status.counter == 7)
    #expect(status.value == "")
    #expect(status.hint == "Пошук")
    #expect(status.packageName == "com.internet.tvbrowser")  // field 20 carries app info
    #expect(status.selectionStart == 0 && status.selectionEnd == 0)
}

@Test func decodesLiveTypingStatusWithoutPackage() throws {
    // Field 22 has no app info — packageName must come back empty (ImeChannel fills it).
    let message = hexBytes("b2 01 1c 12 1a 08 11 12 04 d0 b9 d1 86 18 02 20 02 28 01 32 0a d0 9f d0 be d1 88 d1 83 d0 ba")
    guard case .fieldStatus(let status) = try #require(ImeDecoder.decode(message)) else {
        Issue.record("expected fieldStatus"); return
    }
    #expect(status.counter == 17)
    #expect(status.value == "йц")
    #expect(status.selectionStart == 2 && status.selectionEnd == 2)
    #expect(status.packageName == "")
}

@Test func decodesAppChangeWithoutField() throws {
    let message = hexBytes("a2 01 21 0a 1f 62 1d 63 6f 6d 2e 67 6f 6f 67 6c 65 2e 61 6e 64 72 6f 69 64 2e 79 6f 75 74 75 62 65 2e 74 76")
    #expect(ImeDecoder.decode(message) == .appChanged(packageName: "com.google.android.youtube.tv"))
}

@Test func decodesImeStateCounters() {
    #expect(ImeDecoder.decode(hexBytes("aa 01 04 08 01 10 00")) == .imeState(1, 0))
    #expect(ImeDecoder.decode(hexBytes("aa 01 04 08 00 10 00")) == .imeState(0, 0))
}

@Test func ignoresForeignMessages() {
    #expect(ImeDecoder.decode(hexBytes("c2 02 02 08 01")) == nil)   // field 40 (start)
    #expect(ImeDecoder.decode(hexBytes("12 00")) == nil)            // set_active
}

// Encoders must produce byte-for-byte what the TV ACCEPTED in the spike.

@Test func encodesShowRequestExactly() {
    #expect(Array(ImeEncoder.showRequest(statusCounter: 85))
        == hexBytes("b2 01 0c 12 0a 08 55 12 00 18 00 20 00 28 01"))
}

@Test func encodesTailDeleteExactly() {
    #expect(Array(ImeEncoder.deleteTail(imeCounter: 0, fieldCounter: 0, count: 2))
        == hexBytes("aa 01 10 08 00 10 00 1a 0a 08 01 12 06 08 00 10 02 1a 00"))
}

@Test func encodesAppendExactlyIncludingCyrillic() {
    #expect(Array(ImeEncoder.append(imeCounter: 0, fieldCounter: 0, text: "чудово"))
        == hexBytes("aa 01 1c 08 00 10 00 1a 16 08 01 12 12 08 00 10 00 1a 0c d1 87 d1 83 d0 b4 d0 be d0 b2 d0 be"))
}

@Test func decodesSelectionFieldsWithoutCrashingOnAnOversizedVarint() throws {
    // Synthetic (no real TV sends this) — a field-22 status whose selection
    // fields (3, 4) carry the maximal 10-byte varint. Regression for the
    // Int(_:) trap: this must clamp to 0, not crash the decoder.
    let hugeSelectionStart = hexBytes("b2 01 13 12 11 08 00 12 00 18 ff ff ff ff ff ff ff ff ff 01 20 00")
    guard case .fieldStatus(let status) = try #require(ImeDecoder.decode(hugeSelectionStart)) else {
        Issue.record("expected fieldStatus"); return
    }
    #expect(status.selectionStart == 0)
    #expect(status.selectionEnd == 0)
}
