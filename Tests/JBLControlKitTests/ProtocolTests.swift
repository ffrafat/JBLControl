import Foundation
import Testing
@testable import JBLControlKit

func bytes(_ hex: String) -> Data {
    let h = Array(hex.filter(\.isHexDigit))
    return Data(stride(from: 0, to: h.count, by: 2).map { UInt8(String(h[$0..<$0 + 2]), radix: 16)! })
}

// Captured from a real Flip 7 (firmware 0.7.2.0) on 2026-10-10.
let flip7EQReply = """
AA 99 00 62 06 C2 07 00 00 BB 80 00 40 90 00 00 42 FA 00 00 3F 34 FD F4 01 40 60 00 00 43 7A 00 00 40 00 00 00 \
01 40 20 00 00 43 FA 00 00 40 00 00 00 01 3F C0 00 00 44 7A 00 00 40 00 00 00 01 40 20 00 00 44 FA 00 00 40 00 \
00 00 01 40 60 00 00 45 7A 00 00 40 00 00 00 02 40 90 00 00 45 FA 00 00 3F 34 FD F4
"""

let flip7 = Catalog.model(0x2107)!

@Test func requestFramesEncode() {
    #expect(Frame.requestInfo.encoded == bytes("AA 11 00"))
    #expect(Frame.requestVersion.encoded == bytes("AA 41 00"))
    #expect(Frame.requestEQ.encoded == bytes("AA 98 00 00"))
}

@Test func decoderSplitsAndJoinsNotifications() {
    var d = FrameDecoder()
    #expect(d.feed(bytes("AA 12 03 00 44")).isEmpty)
    let frames = d.feed(bytes("1E AA 42 04 00 07 02 00"))
    #expect(frames == [Frame(0x12, [0x00, 0x44, 0x1E]), Frame(0x42, [0x00, 0x07, 0x02, 0x00])])
}

@Test func infoTokensParse() {
    var d = FrameDecoder()
    let frames = d.feed(bytes("""
    AA 12 11 00 C1 0E 46 46 52 20 4A 42 4C 20 46 6C 69 70 20 37 \
    AA 12 04 00 42 21 07 AA 12 03 00 43 01 AA 12 03 00 44 1E \
    AA 12 03 00 47 00 AA 12 06 00 4D 00 07 02 00
    """))
    let tokens = frames.compactMap { InfoToken.parse($0.payload) }
    #expect(tokens == [
        .name("FFR JBL Flip 7"), .productID(0x2107), .color(0x01), .battery(level: 30, charging: false),
        .audioSourceConnected(false), .firmware("0.7.2.0"),
    ])
}

@Test func advancedEQReplyParses() throws {
    var d = FrameDecoder()
    let frame = try #require(d.feed(bytes(flip7EQReply)).first)
    let state = try #require(EQState(payload: frame.payload))
    #expect(state.activeCategory == 0x06)
    #expect(state.curveCategory == 0xC2)
    #expect(state.sampleRate == 48000)
    #expect(state.bands.map(\.gain) == [4.5, 3.5, 2.5, 1.5, 2.5, 3.5, 4.5])
    #expect(state.bands.map(\.frequency) == [125, 250, 500, 1000, 2000, 4000, 8000])
}

@Test func manufacturerDataYieldsProductID() {
    #expect(JBL.productID(fromManufacturerData: bytes("57 00 07 21 01 28 ED 4D 20 31 29 00")) == 0x2107)
    #expect(JBL.productID(fromManufacturerData: bytes("4C 00 07 21")) == nil)
}

@Test func responseOfFlatCurveIsZeroAndBoostShows() throws {
    #expect(abs(EQResponse.gain(at: 1000, bands: EQLayouts.parametricShape)) < 0.001)
    let energetic = try #require(flip7.presets.first { $0.category == 0x08 })
    #expect(EQResponse.gain(at: 200, bands: energetic.bands) > 6)
}

// Captured from the same Flip 7 while plugged in.
@Test func batteryHighBitMeansCharging() {
    #expect(InfoToken.parse([0x00, 0x44, 0x8A]) == .battery(level: 10, charging: true))
    #expect(InfoToken.parse([0x00, 0x44, 0x64]) == .battery(level: 100, charging: false))
}
