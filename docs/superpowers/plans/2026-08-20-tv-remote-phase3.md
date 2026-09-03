# Phase 3 — Text entry, search, pointer mode: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A live two-way mirror of the TV's focused text field (Cyrillic included), phone-composed search (YouTube deep link / global-search injection), and a third trackpad-style Pointer input mode.

**Architecture:** Hand-rolled protobuf wire helpers (`Wire`) + IME message codecs (`ImeMessages`) feed an `ImeChannel` state machine that owns the verified Xiaomi write handshake; `AndroidTVController` publishes the focused field and exposes `setText`/`search`; the UI grows a live keyboard sheet and a `PointerEngine`-driven third mode. No library fork, no new dependencies.

**Tech Stack:** Swift 6 / SwiftUI / swift-testing (`@Test`, `#expect`), SwiftPM package `RemoteCore`, pinned dependency `AndroidTVRemoteControl@32393c3` (untouched).

**Spec:** `docs/superpowers/specs/2026-08-20-tv-remote-phase3-design.md` — read it first; every protocol byte below is spike-verified fact recorded there and in `docs/phase2-notes.md`. Ground-truth wire fixtures: `docs/ime-captures.md`.

## Global Constraints

- Every `swift` / `xcodebuild` / `xcrun` command needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- **Never run bare `swift test`** — always `./Scripts/test.sh` (the dependency forces a macOS deployment-target flag; bare invocation fails to compile).
- Dependency rule: Apple platforms + the one pinned package. No swift-protobuf, nothing new.
- Key/edit pacing floor: **80ms** between streamed sends (an unpaced burst makes the TV drop the session).
- The TV allows **one control session at a time** — the app and `rc-probe` cannot be connected simultaneously.
- App project files are generated: after changing `project.yml`, run `xcodegen generate` (not needed for any task below — no plist/target changes).
- TDD: each task writes failing tests first. All 55 existing tests must stay green.
- UTF-8/Cyrillic must round-trip everywhere; counts are **Character counts** (the TV counted `йцу` as 3).

---

### Task 1: `Wire` + `ImeMessages` codecs, pinned to captured bytes

**Files:**
- Create: `RemoteCore/Sources/RemoteCore/Wire.swift`
- Create: `RemoteCore/Sources/RemoteCore/ImeMessages.swift`
- Test: `RemoteCore/Tests/RemoteCoreTests/WireTests.swift`
- Test: `RemoteCore/Tests/RemoteCoreTests/ImeMessagesTests.swift`

**Interfaces:**
- Consumes: nothing (leaf task).
- Produces:
  - `enum Wire` (internal): `encodeVarint(_ value: UInt64) -> [UInt8]`, `decodeVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64?`, `field(_ number: Int, varint: UInt64) -> [UInt8]`, `field(_ number: Int, bytes: [UInt8]) -> [UInt8]`, `struct Field: Equatable { let number: Int; let wireType: Int; let varint: UInt64; let payload: [UInt8] }`, `fields(_ bytes: [UInt8]) -> [Field]`, `deframe(_ buffer: inout [UInt8]) -> [[UInt8]]`
  - `public struct TextFieldStatus: Equatable, Sendable { public let counter: UInt64; public let value: String; public let selectionStart: Int; public let selectionEnd: Int; public let hint: String; public internal(set) var packageName: String }` with a public memberwise init.
  - `public enum ImeMessage: Equatable, Sendable { case fieldStatus(TextFieldStatus); case appChanged(packageName: String); case imeState(UInt64, UInt64) }`
  - `enum ImeDecoder` (internal): `static func decode(_ message: [UInt8]) -> ImeMessage?`
  - `enum ImeEncoder` (internal): `static func showRequest(statusCounter: UInt64) -> Data`, `static func append(imeCounter: UInt64, fieldCounter: UInt64, text: String) -> Data`, `static func deleteTail(imeCounter: UInt64, fieldCounter: UInt64, count: Int) -> Data`

Note: `RemoteCore/Sources/rc-probe/ProtoDump.swift` keeps its own private copies of these helpers — it is throwaway spike diagnostics with a human-oriented annotator; do NOT try to deduplicate it into `Wire`.

- [ ] **Step 1: Write the failing tests**

`RemoteCore/Tests/RemoteCoreTests/WireTests.swift`:

```swift
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
}
```

`RemoteCore/Tests/RemoteCoreTests/ImeMessagesTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./Scripts/test.sh`
Expected: compile FAILURE — `Wire`, `ImeDecoder`, `ImeEncoder`, `TextFieldStatus` not defined.

- [ ] **Step 3: Implement `Wire.swift`**

```swift
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
                guard let length = decodeVarint(bytes, &index),
                      index + Int(length) <= bytes.count else { return fields }
                fields.append(Field(number: number, wireType: 2, varint: 0,
                                    payload: Array(bytes[index..<(index + Int(length))])))
                index += Int(length)
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
            guard let length = decodeVarint(buffer, &index), length > 0 else { break }
            let end = index + Int(length)
            guard end <= buffer.count else { break }
            messages.append(Array(buffer[index..<end]))
            buffer.removeSubrange(0..<end)
        }
        return messages
    }
}
```

- [ ] **Step 4: Implement `ImeMessages.swift`**

```swift
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
                selectionStart: Int(status.first { $0.number == 3 }?.varint ?? 0),
                selectionEnd: Int(status.first { $0.number == 4 }?.varint ?? 0),
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./Scripts/test.sh`
Expected: all pass (55 existing + the new ones).

- [ ] **Step 6: Commit**

```bash
git add RemoteCore/Sources/RemoteCore/Wire.swift RemoteCore/Sources/RemoteCore/ImeMessages.swift RemoteCore/Tests/RemoteCoreTests/WireTests.swift RemoteCore/Tests/RemoteCoreTests/ImeMessagesTests.swift
git commit -m "feat: protobuf wire helpers + IME codecs pinned to captured TV bytes"
```

---

### Task 2: `ImeChannel` — the write-handshake state machine

**Files:**
- Create: `RemoteCore/Sources/RemoteCore/ImeChannel.swift`
- Test: `RemoteCore/Tests/RemoteCoreTests/ImeChannelTests.swift`

**Interfaces:**
- Consumes: `ImeMessage`, `TextFieldStatus`, `ImeEncoder` (Task 1).
- Produces (all `@MainActor`, internal — `AndroidTVController` is the only client):
  - `final class ImeChannel`
  - `init(send: @escaping (Data) -> Void, sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) })`
  - `var onFieldChanged: ((TextFieldStatus?) -> Void)?`
  - `private(set) var focusedField: TextFieldStatus?`
  - `func handle(_ message: ImeMessage)`
  - `func setText(_ text: String)` — fire-and-forget; coalesces (last write wins)
  - `func reset()` — called on disconnect; clears field, cancels writes

Behavioral contract (all spike-verified, see spec "Locked decisions"):
1. `.fieldStatus` → merge `packageName` from the last `.appChanged`/status that carried one; publish.
2. `.appChanged` → remember the package, publish `focusedField = nil` (focus lost).
3. `.imeState(a, b)` → store counters, bump an epoch (the handshake waits on it). Never treat as focus.
4. `setText`: show request (echo `focusedField.counter`) → wait for an imeState epoch bump (10 × 150ms polls); on timeout retry the show request once; on second timeout publish `focusedField = nil` (the keyboard is closed on the TV) and abandon the write.
5. After the handshake: if the field is non-empty, send `deleteTail(count: value.count)` and wait for the echoing `.fieldStatus` (same 1.5s poll pattern); then `append(text)`, wait for its echo; if the echo's value ≠ text, retry the whole sequence exactly once.
6. Only one write task at a time; a `setText` during a write replaces the pending text.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import RemoteCore

/// Drives ImeChannel with scripted messages. `sleep` yields instead of
/// sleeping, so tests run in microseconds while preserving suspension points.
@MainActor
private func makeChannel() -> (ImeChannel, sent: () -> [Data]) {
    var sent: [Data] = []
    let channel = ImeChannel(send: { sent.append($0) }, sleep: { _ in await Task.yield() })
    return (channel, { sent })
}

/// Spin the main actor until `condition` or a bounded number of yields.
@MainActor
private func spin(until condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { await Task.yield() }
}

private let browserField = TextFieldStatus(
    counter: 85, value: "hi", selectionStart: 2, selectionEnd: 2,
    hint: "Пошук", packageName: "com.internet.tvbrowser")

@MainActor @Test func statusPublishesAndMergesPackage() {
    let (channel, _) = makeChannel()
    var published: [TextFieldStatus?] = []
    channel.onFieldChanged = { published.append($0) }
    channel.handle(.fieldStatus(browserField))
    // A field-22 status arrives with no package — the channel must remember it.
    var bare = browserField
    bare.packageName = ""
    channel.handle(.fieldStatus(bare))
    #expect(published.count == 2)
    #expect(published[1]?.packageName == "com.internet.tvbrowser")
}

@MainActor @Test func appChangeClearsFocus() {
    let (channel, _) = makeChannel()
    channel.handle(.fieldStatus(browserField))
    channel.handle(.appChanged(packageName: "com.netflix.ninja"))
    #expect(channel.focusedField == nil)
}

@MainActor @Test func setTextRunsHandshakeThenClearThenAppend() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))               // "hi", counter 85
    channel.setText("привіт")
    await spin { sent().count == 1 }
    #expect(sent()[0] == ImeEncoder.showRequest(statusCounter: 85))
    channel.handle(.imeState(0, 0))                          // TV's counter reset
    await spin { sent().count == 2 }
    #expect(sent()[1] == ImeEncoder.deleteTail(imeCounter: 0, fieldCounter: 0, count: 2))
    let cleared = TextFieldStatus(counter: 86, value: "", selectionStart: 0, selectionEnd: 0,
                                  hint: "Пошук", packageName: "com.internet.tvbrowser")
    channel.handle(.fieldStatus(cleared))                    // clear echo
    await spin { sent().count == 3 }
    #expect(sent()[2] == ImeEncoder.append(imeCounter: 0, fieldCounter: 0, text: "привіт"))
}

@MainActor @Test func emptyFieldSkipsTheClearEdit() async {
    let (channel, sent) = makeChannel()
    let empty = TextFieldStatus(counter: 77, value: "", selectionStart: 0, selectionEnd: 0,
                                hint: "", packageName: "app")
    channel.handle(.fieldStatus(empty))
    channel.setText("hello")
    await spin { sent().count == 1 }
    channel.handle(.imeState(0, 0))
    await spin { sent().count == 2 }
    #expect(sent()[1] == ImeEncoder.append(imeCounter: 0, fieldCounter: 0, text: "hello"))
}

@MainActor @Test func handshakeTimeoutRetriesOnceThenClearsFocus() async {
    let (channel, sent) = makeChannel()
    channel.handle(.fieldStatus(browserField))
    var published: [TextFieldStatus?] = []
    channel.onFieldChanged = { published.append($0) }
    channel.setText("x")                                     // never answer
    await spin { sent().count == 2 && published.contains(where: { $0 == nil }) }
    #expect(sent().count == 2)                               // original + one retry
    #expect(sent()[0] == sent()[1])
    #expect(channel.focusedField == nil)                     // keyboard closed on TV
}

@MainActor @Test func coalescingKeepsOnlyTheLatestText() async {
    let (channel, sent) = makeChannel()
    let empty = TextFieldStatus(counter: 1, value: "", selectionStart: 0, selectionEnd: 0,
                                hint: "", packageName: "app")
    channel.handle(.fieldStatus(empty))
    channel.setText("a")
    channel.setText("ab")
    channel.setText("abc")                                   // only this must reach the wire
    await spin { sent().count == 1 }
    channel.handle(.imeState(0, 0))
    await spin { sent().count == 2 }
    #expect(sent()[1] == ImeEncoder.append(imeCounter: 0, fieldCounter: 0, text: "abc"))
}

@MainActor @Test func countersFromTheReplyAreUsedNotStaleOnes() async {
    let (channel, sent) = makeChannel()
    channel.handle(.imeState(1, 0))                          // stale connect-time counters
    let empty = TextFieldStatus(counter: 5, value: "", selectionStart: 0, selectionEnd: 0,
                                hint: "", packageName: "app")
    channel.handle(.fieldStatus(empty))
    channel.setText("x")
    await spin { sent().count == 1 }
    channel.handle(.imeState(3, 7))                          // the reply carries NEW counters
    await spin { sent().count == 2 }
    #expect(sent()[1] == ImeEncoder.append(imeCounter: 3, fieldCounter: 7, text: "x"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./Scripts/test.sh`
Expected: compile FAILURE — `ImeChannel` not defined.

- [ ] **Step 3: Implement `ImeChannel.swift`**

```swift
import Foundation

/// Owns the IME write handshake this TV requires and the merged read state.
/// Session-free: bytes leave through `send`, decoded messages arrive through
/// `handle` — every path is testable with a scripted fake (no TV, no clock).
///
/// The handshake (spike-verified, docs/phase2-notes.md "IME write direction"):
/// a bare batch edit is silently IGNORED. The TV accepts edits only after an
/// ime_show_request echoing the focused field's status counter, answered by a
/// field-21 message whose counters the edits must carry. No answer ever comes
/// unless the TV's on-screen keyboard is open — so a handshake timeout MEANS
/// "keyboard closed", and the channel publishes focus lost rather than lying.
@MainActor
final class ImeChannel {
    var onFieldChanged: ((TextFieldStatus?) -> Void)?
    private(set) var focusedField: TextFieldStatus?

    private let send: (Data) -> Void
    private let sleep: (Duration) async -> Void

    private var lastPackage = ""
    private var imeCounter: UInt64 = 0
    private var fieldCounter: UInt64 = 0
    private var stateEpoch = 0      // bumped on every incoming imeState
    private var statusEpoch = 0     // bumped on every incoming fieldStatus

    private var pendingText: String?
    private var writer: Task<Void, Never>?

    init(send: @escaping (Data) -> Void,
         sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.send = send
        self.sleep = sleep
    }

    func handle(_ message: ImeMessage) {
        switch message {
        case .fieldStatus(var status):
            if status.packageName.isEmpty {
                status.packageName = lastPackage   // field-22 statuses carry no app info
            } else {
                lastPackage = status.packageName
            }
            focusedField = status
            statusEpoch += 1
            onFieldChanged?(status)
        case .appChanged(let package):
            lastPackage = package
            focusedField = nil
            onFieldChanged?(nil)
        case .imeState(let ime, let field):
            imeCounter = ime
            fieldCounter = field
            stateEpoch += 1
        }
    }

    /// Replace the focused field's contents. Fire-and-forget; concurrent
    /// calls coalesce — only the latest text reaches the TV.
    func setText(_ text: String) {
        pendingText = text
        guard writer == nil else { return }
        writer = Task { [weak self] in
            await self?.drainWrites()
            self?.writer = nil
        }
    }

    func reset() {
        writer?.cancel()
        writer = nil
        pendingText = nil
        focusedField = nil
        onFieldChanged?(nil)
    }

    private func drainWrites() async {
        var retried = false
        while let text = pendingText {
            pendingText = nil
            guard await performHandshake() else {
                // Keyboard closed on the TV — the only observed cause of a
                // missing reply. Tell the UI the truth instead of hanging.
                focusedField = nil
                onFieldChanged?(nil)
                return
            }
            let currentLength = focusedField?.value.count ?? 0
            if currentLength > 0 {
                send(ImeEncoder.deleteTail(imeCounter: imeCounter,
                                           fieldCounter: fieldCounter, count: currentLength))
                _ = await awaitBump(of: \.statusEpoch)   // echo is truth; proceed either way
            }
            send(ImeEncoder.append(imeCounter: imeCounter, fieldCounter: fieldCounter, text: text))
            let echoed = await awaitBump(of: \.statusEpoch)
            if echoed, let value = focusedField?.value, value != text,
               pendingText == nil, !retried {
                retried = true          // absolute statuses make one retry safe
                pendingText = text
            }
        }
    }

    private func performHandshake() async -> Bool {
        for _ in 0..<2 {   // the spec's "one retry"
            let epoch = stateEpoch
            send(ImeEncoder.showRequest(statusCounter: focusedField?.counter ?? 0))
            for _ in 0..<10 {
                await sleep(.milliseconds(150))
                if stateEpoch != epoch { return true }
            }
        }
        return false
    }

    /// Polls for the next bump of an epoch (≤1.5s of injected sleep).
    private func awaitBump(of keyPath: KeyPath<ImeChannel, Int>) async -> Bool {
        let epoch = self[keyPath: keyPath]
        for _ in 0..<10 {
            await sleep(.milliseconds(150))
            if self[keyPath: keyPath] != epoch { return true }
        }
        return false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./Scripts/test.sh`
Expected: all pass. If `handshakeTimeoutRetriesOnceThenClearsFocus` hangs, the yield-based sleep is spinning inside `performHandshake` without the test's `spin` making progress — bump the spin bound to 500 before touching the implementation.

- [ ] **Step 5: Commit**

```bash
git add RemoteCore/Sources/RemoteCore/ImeChannel.swift RemoteCore/Tests/RemoteCoreTests/ImeChannelTests.swift
git commit -m "feat: ImeChannel — the verified IME write handshake as a state machine"
```

---

### Task 3: Session plumbing + controller surface + honest mock

**Files:**
- Modify: `RemoteCore/Sources/RemoteCore/Sessions.swift` (ControlSessioning protocol)
- Modify: `RemoteCore/Sources/RemoteCore/LibSessions.swift` (LibControlSession)
- Modify: `RemoteCore/Sources/RemoteCore/TVController.swift` (seam additions)
- Modify: `RemoteCore/Sources/RemoteCore/AndroidTVController.swift`
- Modify: `RemoteCore/Sources/RemoteCore/MockTVController.swift`
- Modify: `RemoteCore/Tests/RemoteCoreTests/AndroidTVControllerTests.swift` (fake session gains members)
- Test: `RemoteCore/Tests/RemoteCoreTests/AndroidTVControllerTests.swift`, `RemoteCore/Tests/RemoteCoreTests/MockTVControllerTests.swift`

**Interfaces:**
- Consumes: `ImeMessage`, `ImeChannel`, `TextFieldStatus` (Tasks 1–2).
- Produces:
  - `ControlSessioning` gains: `var onImeMessage: ((ImeMessage) -> Void)? { get set }`, `func sendRaw(_ data: Data)`, `func sendDeepLink(_ uri: String)` (promoting LibControlSession's existing public method into the seam).
  - `TVController` gains: `var focusedTextField: TextFieldStatus? { get }`, `func setText(_ text: String)`.
  - `MockTVController` gains: `public func focusTextField(_ status: TextFieldStatus?)` (preview/test control) and mock honesty: `setText` mutates its fake field ONLY when one is focused (mirrors the real keyboard-open constraint); `public private(set) var lastSetText: String?`.

- [ ] **Step 1: Write the failing tests**

Append to `AndroidTVControllerTests.swift` (match the file's existing fake-session pattern — it has a `FakeControlSession`; extend it with the three new members recording calls). If no `makeConnectedController()` helper exists yet, write it in this test file by extracting the arrange steps the existing connect tests repeat (build `AndroidTVController` with a fake session factory, pair/connect, deliver `.connected`), returning `(controller, fakeSession)`:

```swift
@MainActor @Test func imeMessagesFlowIntoFocusedTextField() async throws {
    // Use the file's existing helper that builds a connected controller with
    // a FakeControlSession (see connect tests above for the pattern).
    let (controller, session) = try await makeConnectedController()
    let status = TextFieldStatus(counter: 7, value: "", selectionStart: 0, selectionEnd: 0,
                                 hint: "Пошук", packageName: "com.internet.tvbrowser")
    session.onImeMessage?(.fieldStatus(status))
    #expect(controller.focusedTextField == status)
    session.onImeMessage?(.appChanged(packageName: "com.netflix.ninja"))
    #expect(controller.focusedTextField == nil)
}

@MainActor @Test func setTextSendsTheHandshakeOpenerThroughTheSession() async throws {
    let (controller, session) = try await makeConnectedController()
    let status = TextFieldStatus(counter: 85, value: "", selectionStart: 0, selectionEnd: 0,
                                 hint: "", packageName: "app")
    session.onImeMessage?(.fieldStatus(status))
    controller.setText("hello")
    for _ in 0..<50 where session.sentRaw.isEmpty { await Task.yield() }
    #expect(session.sentRaw.first == ImeEncoder.showRequest(statusCounter: 85))
}

@MainActor @Test func disconnectClearsTheFocusedField() async throws {
    let (controller, session) = try await makeConnectedController()
    session.onImeMessage?(.fieldStatus(TextFieldStatus(
        counter: 1, value: "x", selectionStart: 1, selectionEnd: 1, hint: "", packageName: "app")))
    controller.disconnect()
    #expect(controller.focusedTextField == nil)
}
```

Append to `MockTVControllerTests.swift`:

```swift
@MainActor @Test func mockSetTextRequiresAFocusedFieldLikeTheRealTV() {
    let mock = MockTVController(delay: .zero)
    mock.setText("hello")                       // no field focused → must be dropped
    #expect(mock.lastSetText == nil)
    mock.focusTextField(TextFieldStatus(counter: 1, value: "", selectionStart: 0,
                                        selectionEnd: 0, hint: "Пошук", packageName: "browser"))
    mock.setText("hello")
    #expect(mock.lastSetText == "hello")
    #expect(mock.focusedTextField?.value == "hello")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./Scripts/test.sh`
Expected: compile FAILURE — protocol members missing.

- [ ] **Step 3: Implement**

`Sessions.swift` — extend the protocol:

```swift
@MainActor
public protocol ControlSessioning: AnyObject {
    var onEvent: ((ControlEvent) -> Void)? { get set }
    /// Decoded IME traffic (fields 20/21/22), one call per message.
    var onImeMessage: ((ImeMessage) -> Void)? { get set }
    func connect(host: String)
    func sendKey(_ key: KeyCommand)
    func sendText(_ text: String)
    /// Pre-encoded RemoteMessage bytes (the session adds the length frame).
    func sendRaw(_ data: Data)
    /// The protocol's app-link launch (arbitrary URI). CAUTION: an
    /// unsupported URI drops the control session — real-TV-verified URIs only.
    func sendDeepLink(_ uri: String)
    func disconnect()
}
```

`LibSessions.swift` — in `LibControlSession`: add `public var onImeMessage: ((ImeMessage) -> Void)?` and a `private var imeBuffer: [UInt8] = []`; extend the existing `receiveData` hop to deframe and decode (keep `onRawData` — rc-probe uses it); rename `sendRawMessage` to `sendRaw` (update rc-probe call sites: `main.swift` uses `sendRawMessage` in the `settext` case):

```swift
        remoteManager.receiveData = { [weak self] data, _ in
            guard let data, !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onRawData?(data)
                self.imeBuffer.append(contentsOf: data)
                for message in Wire.deframe(&self.imeBuffer) {
                    if let ime = ImeDecoder.decode(message) {
                        self.onImeMessage?(ime)
                    }
                }
            }
        }
```

`TVController.swift` — add to the protocol, after `sendText`:

```swift
    /// The TV's focused text field as last reported, nil when none (or the
    /// on-screen keyboard is closed — writes are impossible then).
    var focusedTextField: TextFieldStatus? { get }
    /// Replace the focused field's contents (IME clear+append handshake).
    /// Fire-and-forget; a failed write surfaces as focusedTextField → nil.
    func setText(_ text: String)
```

`AndroidTVController.swift` — add `public private(set) var focusedTextField: TextFieldStatus?` and `private var imeChannel: ImeChannel?`. In `connect(to:)`, right after the control session is created and its `onEvent` is wired, add:

```swift
        let channel = ImeChannel(send: { [weak session] in session?.sendRaw($0) })
        channel.onFieldChanged = { [weak self] in self?.focusedTextField = $0 }
        session.onImeMessage = { [weak channel] in channel?.handle($0) }
        imeChannel = channel
```

Add the seam method and clear on teardown (`disconnect()` and the `.dropped` branch of `handleControl`):

```swift
    public func setText(_ text: String) {
        guard connectionState == .connected else { return }
        imeChannel?.setText(text)
    }
    // in disconnect() and on .dropped:
    imeChannel?.reset()
    imeChannel = nil
    focusedTextField = nil
```

`MockTVController.swift`:

```swift
    public private(set) var focusedTextField: TextFieldStatus?
    public private(set) var lastSetText: String?

    /// Preview/test control: pretend the TV focused (or left) a text field.
    public func focusTextField(_ status: TextFieldStatus?) {
        focusedTextField = status
    }

    public func setText(_ text: String) {
        // Mock honesty (Phase 2 lesson): the real TV accepts writes only for
        // a focused field with its keyboard open — the mock must not be more
        // permissive, or tests will pass against behavior the TV lacks.
        guard let field = focusedTextField else { return }
        lastSetText = text
        focusedTextField = TextFieldStatus(
            counter: field.counter + 2, value: text,
            selectionStart: text.count, selectionEnd: text.count,
            hint: field.hint, packageName: field.packageName)
    }
```

Update `FakeControlSession` in `AndroidTVControllerTests.swift` with the new members (`onImeMessage` stored property, `sentRaw: [Data]` recording `sendRaw`, `sentDeepLinks: [String]` recording `sendDeepLink`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `./Scripts/test.sh`
Expected: all pass (rc-probe must also still compile — it consumes `sendRaw`).

- [ ] **Step 5: Commit**

```bash
git add -A RemoteCore
git commit -m "feat: IME plumbing through the session seam; controller publishes focusedTextField"
```

---

### Task 4: Keyboard sheet rewrite + live tile

**Files:**
- Modify: `App/KeyboardSheet.swift` (full rewrite)
- Modify: `App/RemoteView.swift:190-208` (the keyboard tile)

**Interfaces:**
- Consumes: `controller.focusedTextField`, `controller.setText(_:)` (Task 3). The search buttons land in Task 5 — this task leaves a `// Search actions arrive with SearchTarget (see plan Task 5)` placeholder-free sheet: build the mirror only; Task 5 adds the buttons.
- Produces: UI only; nothing downstream consumes it.

Design note (deliberate deviation, serving the spec's search requirement): the tile stays TAPPABLE always — the sheet hosts search, which needs no TV field. "Live" is expressed by the tile's icon: accent-colored when a field is focused, muted otherwise; and by the mirror section inside the sheet enabling/disabling.

- [ ] **Step 1: Rewrite `App/KeyboardSheet.swift`**

```swift
import RemoteCore
import SwiftUI

/// Live mirror of the TV's focused text field. The phone field initializes
/// from the TV value; local edits push the FULL string (debounced) through
/// the controller's clear+append write; TV-side edits stream back in and
/// update the phone when it isn't mid-edit. Absolute values on both sides —
/// no deltas, no drift (the Phase 2 delta bug class is structurally gone).
struct KeyboardSheet: View {
    let controller: any TVController
    @Binding var isPresented: Bool

    @State private var text = ""
    @State private var pushTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var field: TextFieldStatus? { controller.focusedTextField }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(field.map { $0.hint.isEmpty ? "Type to your TV" : $0.hint }
                     ?? "No text field on TV")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Text("Done")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
            }

            TextField("", text: $text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Theme.sheetBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .padding(.top, 12)
                .disabled(field == nil)
                .opacity(field == nil ? 0.4 : 1)
                .accessibilityLabel("Text on your TV")
                .onChange(of: text) { _, newValue in
                    guard field != nil, newValue != field?.value else { return }
                    // Debounce ≥120ms so bursts coalesce before the two-edit
                    // write; ImeChannel serializes and keeps only the latest.
                    pushTask?.cancel()
                    pushTask = Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        controller.setText(newValue)
                        pushTask = nil   // a completed push no longer blocks TV-side adoption
                    }
                }
                .onChange(of: field) { _, newField in
                    guard let newField else { return }
                    // TV-side change (physical remote, or our own echo):
                    // adopt it unless a local push is still pending.
                    if pushTask == nil || pushTask!.isCancelled || newField.value == text {
                        text = newField.value
                    }
                }

            Text(field == nil
                 ? "Focus a text field on the TV (its keyboard must be open)"
                 : "Mirrored live — typing here edits \(appLabel(field!.packageName))")
                .font(.system(size: 12))
                .foregroundStyle(Theme.sheetPlaceholder)
                .padding(.top, 10)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .presentationDetents([.height(190)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.sheet)
        .onAppear {
            text = field?.value ?? ""
            focused = field != nil
        }
        .onDisappear { pushTask?.cancel() }
    }

    private func appLabel(_ package: String) -> String {
        package.split(separator: ".").last.map(String.init) ?? package
    }
}
```

- [ ] **Step 2: Update the keyboard tile in `App/RemoteView.swift`**

Replace the disabled tile (lines ~190-208, the block with the "Text entry is not supported yet" comment) with:

```swift
            // Live IME: the icon lights up while the TV reports a focused
            // text field (writes are possible), stays muted otherwise. The
            // sheet is always reachable — it also hosts search, which needs
            // no TV-side field.
            Button {
                showKeyboard = true
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(controller.focusedTextField != nil ? Theme.accent : Theme.iconMuted)
                    .frame(width: 50, height: 50)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(controller.focusedTextField != nil
                ? "Keyboard — TV text field is live"
                : "Keyboard and search")
```

- [ ] **Step 3: Verify — package tests + app build**

Run: `./Scripts/test.sh`
Expected: all pass.

Run:
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project RemoteControl.xcodeproj -scheme RemoteControl \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/rc-build build 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add App/KeyboardSheet.swift App/RemoteView.swift
git commit -m "feat: keyboard sheet is a live two-way mirror of the TV text field"
```

---

### Task 5: Search — YouTube deep link + global-search injection

**Files:**
- Modify: `RemoteCore/Sources/RemoteCore/KeyCommand.swift` (two new cases)
- Modify: `RemoteCore/Sources/RemoteCore/KeyCodeMap.swift` (their keycodes)
- Modify: `RemoteCore/Sources/RemoteCore/TVController.swift` (`SearchTarget` + `search`)
- Modify: `RemoteCore/Sources/RemoteCore/AndroidTVController.swift`
- Modify: `RemoteCore/Sources/RemoteCore/MockTVController.swift`
- Modify: `App/KeyboardSheet.swift` (the two search buttons)
- Test: `RemoteCore/Tests/RemoteCoreTests/AndroidTVControllerTests.swift`, `KeyCodeMapTests.swift`

**Interfaces:**
- Consumes: `setText`, `focusedTextField` (Task 3), `sendDeepLink`/`sendKey` on `ControlSessioning`.
- Produces:
  - `public enum SearchTarget: Equatable, Sendable { case youtube, globalSearch }` (in TVController.swift)
  - `TVController` gains `func search(_ query: String, target: SearchTarget)`
  - `KeyCommand` gains `case search, enter`
  - `MockTVController` gains `public private(set) var sentSearches: [(query: String, target: SearchTarget)]` — note: tuples aren't Equatable for #expect; store as `public struct SentSearch: Equatable { public let query: String; public let target: SearchTarget }`.

- [ ] **Step 1: Write the failing tests**

`KeyCodeMapTests.swift` (match the file's existing mapping-test style):

```swift
@Test func searchAndEnterMapToAndroidKeycodes() {
    #expect(KeyCodeMap.key(for: .search)?.rawValue == 84)   // KEYCODE_SEARCH — opens katniss (verified)
    #expect(KeyCodeMap.key(for: .enter)?.rawValue == 66)    // KEYCODE_ENTER — search submit candidate
}
```

`AndroidTVControllerTests.swift`:

```swift
@MainActor @Test func youtubeSearchSendsThePercentEncodedDeepLink() async throws {
    let (controller, session) = try await makeConnectedController()
    controller.search("йога уроки", target: .youtube)
    #expect(session.sentDeepLinks == ["https://www.youtube.com/results?search_query=%D0%B9%D0%BE%D0%B3%D0%B0%20%D1%83%D1%80%D0%BE%D0%BA%D0%B8"])
}

@MainActor @Test func globalSearchOpensKatnissThenInjectsWhenItsFieldAppears() async throws {
    let (controller, session) = try await makeConnectedController()
    controller.search("stranger", target: .globalSearch)
    #expect(session.sentKeys.last == .search)               // opener sent immediately
    // katniss's field reports focus → the query must go through setText.
    session.onImeMessage?(.fieldStatus(TextFieldStatus(
        counter: 50, value: "", selectionStart: 0, selectionEnd: 0,
        hint: "Шукайте фільми", packageName: "com.google.android.katniss")))
    for _ in 0..<200 where session.sentRaw.isEmpty { await Task.yield() }
    #expect(session.sentRaw.first == ImeEncoder.showRequest(statusCounter: 50))
}

@MainActor @Test func globalSearchDoesNotInjectIntoANonKatnissField() async throws {
    let (controller, session) = try await makeConnectedController()
    controller.search("stranger", target: .globalSearch)
    session.onImeMessage?(.fieldStatus(TextFieldStatus(
        counter: 9, value: "", selectionStart: 0, selectionEnd: 0,
        hint: "Пошук", packageName: "com.internet.tvbrowser")))
    for _ in 0..<50 { await Task.yield() }
    #expect(session.sentRaw.isEmpty)                        // wrong app — leave it alone
}
```

The injection is EVENT-DRIVEN (no polling): `search(.globalSearch)` stores a pending query with a 5s deadline task; the controller's `onFieldChanged` wiring (added in Task 3's `connect(to:)`) injects when a katniss field reports focus. That makes both tests deterministic — the field message triggers injection synchronously.

- [ ] **Step 2: Run tests to verify they fail**

Run: `./Scripts/test.sh`
Expected: compile FAILURE — `search`, `SearchTarget`, new key cases missing.

- [ ] **Step 3: Implement**

`KeyCommand.swift` — extend the enum:

```swift
public enum KeyCommand: Hashable, Sendable {
    case power, up, down, left, right, ok, back, home, menu
    case volumeUp, volumeDown, mute, channelUp, channelDown
    case rewind, playPause, fastForward, input
    case search, enter
    case launchApp(AppShortcut)
}
```

`KeyCodeMap.swift` — add to the `key(for:)` switch:

```swift
        case .search: .KEYCODE_SEARCH   // 84 — opens global search (real-TV-verified)
        case .enter: .KEYCODE_ENTER     // 66
```

`TVController.swift`:

```swift
public enum SearchTarget: Equatable, Sendable {
    /// Opens YouTube directly on the results page via its search deep link
    /// (real-TV-verified, Cyrillic included). Needs no TV-side text field.
    case youtube
    /// Opens Android TV global search (katniss) and injects the query into
    /// its IME field. The route that reaches Netflix — it has no working
    /// search deep link (all four candidate forms tested).
    case globalSearch
}

// protocol addition, after setText:
    /// Compose-on-phone search. Fire-and-forget.
    func search(_ query: String, target: SearchTarget)
```

`AndroidTVController.swift`:

```swift
    private var pendingSearchQuery: String?
    private var pendingSearchDeadline: Task<Void, Never>?

    public func search(_ query: String, target: SearchTarget) {
        guard connectionState == .connected else { return }
        switch target {
        case .youtube:
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")   // RFC 3986 unreserved — encode everything else
            let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
            controlSession?.sendDeepLink("https://www.youtube.com/results?search_query=\(encoded)")
        case .globalSearch:
            controlSession?.sendKey(.search)
            pendingSearchQuery = query
            pendingSearchDeadline?.cancel()
            pendingSearchDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                // katniss never reported its field (voice-first UI, or search
                // didn't open): leave the user in whatever opened (spec) —
                // injecting blind would type into an arbitrary focused field.
                self?.pendingSearchQuery = nil
            }
        }
    }
```

and extend the `channel.onFieldChanged` closure written in Task 3's `connect(to:)` to perform the injection the moment katniss's field appears:

```swift
        channel.onFieldChanged = { [weak self] field in
            guard let self else { return }
            self.focusedTextField = field
            if let field, let query = self.pendingSearchQuery,
               field.packageName.hasSuffix("katniss") {
                self.pendingSearchQuery = nil
                self.pendingSearchDeadline?.cancel()
                self.setText(query)
                Task { [weak self] in
                    // Submission is the spec's risk 2: ENTER after the write
                    // settles is the candidate — verify in Task 7.
                    try? await Task.sleep(for: .seconds(1))
                    self?.sendKey(.enter)
                }
            }
        }
```

Also clear `pendingSearchQuery` and cancel `pendingSearchDeadline` in `disconnect()`/`.dropped` (next to `imeChannel?.reset()`).

`MockTVController.swift`:

```swift
    public struct SentSearch: Equatable {
        public let query: String
        public let target: SearchTarget
    }
    public private(set) var sentSearches: [SentSearch] = []

    public func search(_ query: String, target: SearchTarget) {
        sentSearches.append(SentSearch(query: query, target: target))
    }
```

`App/KeyboardSheet.swift` — add below the caption `Text`, before the `Spacer`:

```swift
            HStack(spacing: 10) {
                searchButton("Search on TV", systemImage: "magnifyingglass.circle") {
                    controller.search(text, target: .globalSearch)
                }
                searchButton("YouTube", systemImage: "play.rectangle") {
                    controller.search(text, target: .youtube)
                }
            }
            .padding(.top, 14)
```

and the helper + detent bump (`.height(190)` → `.height(240)`):

```swift
    private func searchButton(_ title: String, systemImage: String,
                              action: @escaping () -> Void) -> some View {
        Button {
            action()
            isPresented = false
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(text.isEmpty ? Theme.iconMuted : Theme.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(PressableStyle())
        .disabled(text.isEmpty)
    }
```

Note: the sheet's text field is disabled without a TV field, but search needs typed text — so when `field == nil`, ENABLE the text field anyway but skip the push (`guard field != nil` already does). Change the `.disabled(field == nil)` modifier added in Task 4 to `.disabled(false)` equivalent — i.e. remove it and keep only the caption distinguishing the two uses. Concretely: delete the `.disabled(field == nil)` and `.opacity(...)` lines from the TextField; the caption text already explains the state.

- [ ] **Step 4: Run tests + app build**

Run: `./Scripts/test.sh` → all pass.
Run the xcodebuild from Task 4 Step 3 → `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add -A RemoteCore App
git commit -m "feat: phone-composed search — YouTube deep link and global-search injection"
```

---

### Task 6: Preferences migration + Pointer mode

**Files:**
- Modify: `RemoteCore/Sources/RemoteCore/Preferences.swift`
- Create: `RemoteCore/Sources/RemoteCore/PointerEngine.swift`
- Create: `App/PointerView.swift`
- Modify: `App/RemoteView.swift` (mode state + third segment)
- Test: `RemoteCore/Tests/RemoteCoreTests/PersistenceTests.swift` (Preferences), new `RemoteCore/Tests/RemoteCoreTests/PointerEngineTests.swift`

**Interfaces:**
- Consumes: `KeyCommand` (.up/.down/.left/.right/.ok).
- Produces:
  - `public enum ControlMode: String, CaseIterable, Sendable { case dpad, touchpad, pointer }`
  - `Preferences.controlMode: ControlMode` (get/nonmutating set; migrates from `lastModeIsTouchpad`, which is DELETED — update its usages/tests)
  - `public struct PointerEngine` — `init(stepLength: CGFloat = 48, minInterval: Duration = .milliseconds(80))`, `mutating func began(at: CGPoint)`, `mutating func moved(to: CGPoint, now: Duration) -> KeyCommand?`, `mutating func ended(at: CGPoint) -> KeyCommand?`

- [ ] **Step 1: Write the failing tests**

`PersistenceTests.swift` additions (match the file's UserDefaults-isolation pattern — it constructs `Preferences` with isolated `UserDefaults`; reuse its approach. If the named helpers below don't exist, write them in the test file: `makeIsolatedPreferences()` returns a `Preferences` on a fresh `UserDefaults(suiteName: UUID().uuidString)!`, and `makeIsolatedPreferencesAndDefaults()` returns both):

```swift
@Test func controlModeDefaultsToDpad() {
    let preferences = makeIsolatedPreferences()   // the file's existing helper
    #expect(preferences.controlMode == .dpad)
}

@Test func controlModeMigratesFromTheLegacyTouchpadBool() {
    let (preferences, defaults) = makeIsolatedPreferencesAndDefaults()
    defaults.set(true, forKey: "lastModeIsTouchpad")
    #expect(preferences.controlMode == .touchpad)
    preferences.controlMode = .pointer            // an explicit choice wins forever
    #expect(preferences.controlMode == .pointer)
}
```

`PointerEngineTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import RemoteCore

@Test func dragAcrossOneStepEmitsOneDirectionalKey() {
    var engine = PointerEngine(stepLength: 48, minInterval: .milliseconds(80))
    engine.began(at: .zero)
    #expect(engine.moved(to: CGPoint(x: 30, y: 0), now: .milliseconds(100)) == nil)
    #expect(engine.moved(to: CGPoint(x: 60, y: 0), now: .milliseconds(200)) == .right)
}

@Test func fastDragIsCappedByTheEightyMillisecondFloor() {
    var engine = PointerEngine(stepLength: 48, minInterval: .milliseconds(80))
    engine.began(at: .zero)
    #expect(engine.moved(to: CGPoint(x: 100, y: 0), now: .milliseconds(10)) == .right)
    // 300pt further, but only 20ms later — the floor must swallow it.
    #expect(engine.moved(to: CGPoint(x: 400, y: 0), now: .milliseconds(30)) == nil)
    // After the floor passes, the accumulated distance emits.
    #expect(engine.moved(to: CGPoint(x: 401, y: 0), now: .milliseconds(100)) == .right)
}

@Test func dominantAxisWinsOnDiagonals() {
    var engine = PointerEngine(stepLength: 48, minInterval: .milliseconds(80))
    engine.began(at: .zero)
    #expect(engine.moved(to: CGPoint(x: 20, y: -60), now: .milliseconds(100)) == .up)
}

@Test func tapEmitsOKAndDragDoesNot() {
    var engine = PointerEngine(stepLength: 48, minInterval: .milliseconds(80))
    engine.began(at: CGPoint(x: 100, y: 100))
    #expect(engine.ended(at: CGPoint(x: 104, y: 103)) == .ok)      // < 12pt = tap
    engine.began(at: .zero)
    _ = engine.moved(to: CGPoint(x: 80, y: 0), now: .milliseconds(100))
    #expect(engine.ended(at: CGPoint(x: 80, y: 0)) == nil)         // real drag
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./Scripts/test.sh`
Expected: compile FAILURE.

- [ ] **Step 3: Implement**

`Preferences.swift` — replace `lastModeIsTouchpad` with:

```swift
    /// Navigation mode. Migrates the Phase 1 Bool ("lastModeIsTouchpad") the
    /// first time; an explicit set writes the new key and wins thereafter.
    public var controlMode: ControlMode {
        get {
            if let raw = defaults.string(forKey: "controlMode"),
               let mode = ControlMode(rawValue: raw) {
                return mode
            }
            return defaults.bool(forKey: "lastModeIsTouchpad") ? .touchpad : .dpad
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "controlMode") }
    }
```

and at file scope:

```swift
public enum ControlMode: String, CaseIterable, Sendable {
    case dpad, touchpad, pointer
}
```

`PointerEngine.swift`:

```swift
import CoreGraphics

/// Turns a continuous drag into paced D-pad steps — the trackpad feel the
/// protocol can actually deliver (it has no motion events; the TV hops
/// focus between items). Faster drags cross the step threshold sooner, so
/// speed emerges naturally; the interval floor is the Phase 2 pacing rule —
/// bursts make the TV drop the session.
public struct PointerEngine {
    private let stepLength: CGFloat
    private let minInterval: Duration
    private var startPoint: CGPoint?
    private var lastPoint: CGPoint?
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var lastEmit: Duration = .seconds(-1)

    public init(stepLength: CGFloat = 48, minInterval: Duration = .milliseconds(80)) {
        self.stepLength = stepLength
        self.minInterval = minInterval
    }

    public mutating func began(at point: CGPoint) {
        startPoint = point
        lastPoint = point
        accumulatedX = 0
        accumulatedY = 0
    }

    public mutating func moved(to point: CGPoint, now: Duration) -> KeyCommand? {
        guard let last = lastPoint else { began(at: point); return nil }
        accumulatedX += point.x - last.x
        accumulatedY += point.y - last.y
        lastPoint = point
        guard now - lastEmit >= minInterval else { return nil }
        guard abs(accumulatedX) >= stepLength || abs(accumulatedY) >= stepLength else { return nil }
        lastEmit = now
        if abs(accumulatedX) >= abs(accumulatedY) {
            defer { accumulatedX -= stepLength * (accumulatedX > 0 ? 1 : -1); accumulatedY = 0 }
            return accumulatedX > 0 ? .right : .left
        } else {
            defer { accumulatedY -= stepLength * (accumulatedY > 0 ? 1 : -1); accumulatedX = 0 }
            return accumulatedY > 0 ? .down : .up
        }
    }

    public mutating func ended(at point: CGPoint) -> KeyCommand? {
        defer { startPoint = nil; lastPoint = nil; accumulatedX = 0; accumulatedY = 0 }
        guard let start = startPoint else { return nil }
        let distance = hypot(point.x - start.x, point.y - start.y)
        return distance < 12 ? .ok : nil
    }
}
```

`App/PointerView.swift` (visual pattern mirrors `TouchpadView.swift`):

```swift
import RemoteCore
import SwiftUI

struct PointerView: View {
    let press: (KeyCommand) -> Void

    @State private var engine = PointerEngine()
    @State private var epoch = ContinuousClock.now

    var body: some View {
        RoundedRectangle(cornerRadius: 26)
            .fill(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 26)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            )
            .overlay(
                VStack(spacing: 10) {
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(Theme.chevron)
                    Text("Glide to move")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Tap to select")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.chevron)
                }
            )
            .frame(height: 244)
            .contentShape(RoundedRectangle(cornerRadius: 26))
            .accessibilityLabel("Pointer surface — glide to move focus, tap to select")
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if let key = engine.moved(to: value.location, now: epoch.duration(to: .now)) {
                            press(key)
                        }
                    }
                    .onEnded { value in
                        if let key = engine.ended(at: value.location) {
                            press(key)
                        }
                    }
            )
    }
}
```

`App/RemoteView.swift` — replace the Bool state and toggle:

```swift
    @State private var mode = Preferences().controlMode
    // body:
                switch mode {
                case .dpad: DPadView(press: press)
                case .touchpad: TouchpadView(press: press)
                case .pointer: PointerView(press: press)
                }
    // persist:
        .onChange(of: mode) { _, newValue in Preferences().controlMode = newValue }
    // toggle:
    private var modeToggle: some View {
        HStack(spacing: 6) {
            modeSegment(icon: "dpad", isActive: mode == .dpad, label: "D-pad mode") { mode = .dpad }
            modeSegment(icon: "rectangle.and.hand.point.up.left", isActive: mode == .touchpad, label: "Touchpad mode") { mode = .touchpad }
            modeSegment(icon: "cursorarrow.motionlines", isActive: mode == .pointer, label: "Pointer mode") { mode = .pointer }
        }
    }
```

(Keep the existing `modeSegment` helper as is. Delete the `isTouchpad` state and its `onChange`.)

- [ ] **Step 4: Run tests + app build**

Run: `./Scripts/test.sh` → all pass (fix any `lastModeIsTouchpad` references the compiler finds — delete them in favor of `controlMode`).
Run the xcodebuild from Task 4 Step 3 → `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add -A RemoteCore App
git commit -m "feat: pointer mode — paced trackpad-style navigation as a third input mode"
```

---

### Task 7: Real-TV verification pass + fix wave

No new code — this task runs the app against the real TV and fixes what reality disagrees with. **Prerequisite: the user is at the TV.** Remember: ONE control session — quit the app before using `rc-probe` and vice versa.

**Files:**
- Modify: `docs/phase2-notes.md` (append findings), whatever the fixes touch.

- [ ] **Step 1: Build and install in the simulator**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project RemoteControl.xcodeproj -scheme RemoteControl \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/rc-build build
xcrun simctl install booted /tmp/rc-build/Build/Products/Debug-iphonesimulator/RemoteControl.app
xcrun simctl launch booted com.example.RemoteControl
open -a Simulator
```

- [ ] **Step 2: Walk the checklist with the user, in this order**

1. Connect to the TV (it may have a NEW IP — discovery handles it; the paired TV was `desktop`, last at 192.168.0.108).
2. Browser field focused on TV → keyboard tile turns accent → sheet shows the TV's text → type on phone (Latin, then Cyrillic) → appears on TV → delete/replace on phone → TV follows.
3. Type on the TV's remote → phone field follows; delete on TV → phone follows.
4. Close the TV keyboard → sheet's field disables with the honest caption.
5. Netflix open → tile muted (no field) → sheet still opens → type `stranger` → "Search on TV" → global search opens, query lands, results appear. **Record whether results include Netflix titles (spec risk 1) and whether ENTER submitted or a manual press was needed (risk 2).**
6. YouTube button with a Cyrillic query → YouTube opens on results.
7. Pointer mode: glide moves focus at a pleasant rate (tune `stepLength` if not), tap selects, no session drops during long glides.

- [ ] **Step 3: Fix what failed; re-run `./Scripts/test.sh` after each fix; commit each fix separately**

Likely candidates, pre-triaged: katniss needs a D-pad nudge before its field reports (add it to the injection task); ENTER doesn't submit (probe alternatives: `KEYCODE_DPAD_CENTER` 23, `KEYCODE_NUMPAD_ENTER` 160 via `./Scripts/probe.sh raw <host> 23 160` while katniss holds injected text); pointer feel (adjust `stepLength`).

- [ ] **Step 4: Record findings + commit**

Append a "Phase 3 real-TV verification" section to `docs/phase2-notes.md` with what worked and what needed fixing (mirror the Phase 2 findings format).

```bash
git add -A
git commit -m "docs: Phase 3 real-TV verification findings"
```
