import Foundation
import Testing
@testable import RemoteCore

// Every fixture is a frame that moved a real TV's cursor on 2026-08-22.
// See docs/tvbrowser-remote-protocol.md.

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

@Test func moveMatchesTheVerifiedWireBytes() {
    // RemoteEvent{cursor_move=1} -> CursorMove{action=MOVE(2), dx=-6, dy=-4}
    #expect(hex(CursorMessages.move(dx: -6, dy: -4)) == "0a0c0802150000c0c01d000080c0")
}

@Test func moveEncodesPositiveDeltasLittleEndian() {
    // 15.0 = 0x41700000, 10.0 = 0x41200000 — both little-endian on the wire.
    #expect(hex(CursorMessages.move(dx: 15, dy: 10)) == "0a0c080215000070411d00002041")
}

@Test func moveIsAlwaysFourteenBytes() {
    // Fixed length: tag+varint (2) + tag+float (5) + tag+float (5) = 12 body
    // bytes, so the outer length is always the single varint byte 0x0c.
    for (dx, dy) in [(Float(0), Float(0)), (0.5, -0.5), (1000, -1000)] {
        let data = CursorMessages.move(dx: dx, dy: dy)
        #expect(data.count == 14)
        #expect(data[0] == 0x0a)
        #expect(data[1] == 0x0c)
    }
}

@Test func clickIsAnEmptyMessageOnFieldFour() {
    // CursorClick genuinely has no fields (its protobuf descriptor declares
    // zero). Verified on hardware: these two bytes, sent while the cursor
    // hovered a search result, navigated the browser to that link.
    #expect(hex(CursorMessages.click()) == "2200")
}

@Test func zeroDeltaStillEncodesBothAxes() {
    // Must NOT omit zeros the way a proto3 encoder omits scalar defaults: the
    // fixed32s are read positionally here, and this project has been bitten by
    // helpful omission before.
    #expect(hex(CursorMessages.move(dx: 0, dy: 0)) == "0a0c080215000000001d00000000")
}
