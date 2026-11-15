import Foundation
import Testing
@testable import JBLControlKit

/// The JBL Go 4 speaks the legacy "advanced level" EQ: five integer bands inside the AA 97 frame.
///
/// The frames below are byte-for-byte what openjbl 0.3.0 builds for PID 20E4 from the JBL Portable
/// app's own model data, so this is a regression fence rather than a guess. Whether a given Go 4
/// firmware accepts the write still has to be confirmed on hardware: reads are safe either way.

private let go4PIDs: [UInt16] = [0x20E4, 0x210A, 0x215C, 0x2181]

@Test func go4ModelsUseFiveLevelBands() throws {
    for pid in go4PIDs {
        let model = try #require(Catalog.model(pid))
        #expect(model.family == .legacyLevels)
        #expect(model.customCategory == 0xC1)
        #expect(model.customBands.count == 5)
        #expect(model.customBands.map(\.frequency) == [100, 1000, 2000, 7000, 10000])
        #expect(model.customBands.allSatisfy { $0.range == -6...6 && $0.step == 1 })
    }
}

@Test func go4CustomWriteIsByteExact() throws {
    let go4 = try #require(Catalog.model(0x20E4))
    let frame = try #require(EQCodec(model: go4).setCustom([0, 0, 0, 0, 0]).first)
    #expect(frame == bytes("AA 97 00 0E C1 C1 06 05 01 00 02 00 03 00 04 00 05 00"))
}

@Test func go4PresetSelectSendsBiquadCoefficients() throws {
    // Captured on a real Go 4: this is the frame JBL's DefaultPresetEQPayload
    // builds for Signature, and the speaker answers with AA 99 … 06 … (active = 06).
    let go4 = try #require(Catalog.model(0x210A))
    let signature = try #require(go4.presets.first { $0.category == 0x06 })
    let frame = try #require(EQCodec(model: go4).select(signature, customGains: []).first)
    expectPresetFrame(frame, "AA 97 00 65 06 00 00 00 20 62 ED 6B C0 9F 77 95 1F 9F 12 94 3F 62 88 6A E0 00 00 00 20 8C 57 6F C4 F4 3C 14 1C 75 A8 90 3B 0D C3 EB E3 00 00 00 20 AC 9B 43 C9 0F B2 AA 18 55 64 BC 36 F2 4D 55 E7 00 00 00 20 B7 CC 1A E4 25 B4 D2 0D 4A 33 E5 1B DC 4B 2D F2 00 00 00 20 F1 86 D4 F4 FC 26 28 0B 10 79 2B 0B 05 D9 D7 F4")
}

@Test func go4ChillPresetCoversShelvesAndLowPass() throws {
    // Chill exercises the low-shelf, high-shelf and low-pass coefficient paths,
    // which Signature (peaking only) does not. Captured on the same Go 4.
    let go4 = try #require(Catalog.model(0x20E4))
    let chill = try #require(go4.presets.first { $0.category == 0x22 })
    let frame = try #require(EQCodec(model: go4).select(chill, customGains: []).first)
    expectPresetFrame(frame, "AA 97 00 65 22 50 F4 EB 1F FA A4 FC C0 8A C8 18 1F 0B 12 03 3F 2B FA FA E0 00 00 00 20 8C 57 6F C4 F4 3C 14 1C 75 A8 90 3B 0D C3 EB E3 86 B9 47 1F 75 51 18 C8 EB 56 B8 19 8C AE E7 37 90 EF FF E6 2F 54 EA 18 E4 04 5C EB 2D 59 46 04 F7 47 EB 1E CB 05 88 F8 48 55 55 09 91 AA AA 12 48 55 55 09 2F 00 00 00 B0 AA AA FA")
}

/// The header and category must be byte-exact; a coefficient may drift by a few
/// LSBs between platforms' tan/sqrt implementations, which the firmware accepts.
private func expectPresetFrame(_ frame: Data, _ expectedHex: String) {
    let expected = bytes(expectedHex)
    #expect(frame.prefix(5) == expected.prefix(5))
    #expect(frame.count == expected.count)
    guard frame.count == expected.count else { return }
    func int32(_ data: Data, _ offset: Int) -> Int32 {
        let b = data.startIndex + offset
        return Int32(bitPattern: UInt32(data[b]) | UInt32(data[b + 1]) << 8
                     | UInt32(data[b + 2]) << 16 | UInt32(data[b + 3]) << 24)
    }
    var offset = 5
    while offset + 3 < frame.count {
        #expect(abs(Int(int32(frame, offset)) - Int(int32(expected, offset))) <= 2048,
                "coefficient at byte \(offset)")
        offset += 4
    }
}

@Test func xtreme4PresetsAreNotImplementedYet() throws {
    // Xtreme 4 uses the AKM encoder instead of DefaultPresetEQPayload.
    let xtreme4 = try #require(Catalog.model(0x20DC))
    #expect(!xtreme4.supportsPresets)
    #expect(xtreme4.pickerPresets.map(\.name) == ["Custom"])
    let signature = try #require(xtreme4.presets.first)
    #expect(EQCodec(model: xtreme4).select(signature, customGains: []).isEmpty)
}

@Test func emptyCustomCurveNeverSendsZeroBands() throws {
    let go4 = try #require(Catalog.model(0x20E4))
    let frame = try #require(EQCodec(model: go4).setCustom([]).first)
    #expect(frame == bytes("AA 97 00 0E C1 C1 06 05 01 00 02 00 03 00 04 00 05 00"))
}

@Test func go4LevelReplyParsesBack() throws {
    let go4 = try #require(Catalog.model(0x20E4))
    let reply = Incoming.legacy(Frame(0x99, [0x06, 0xC1, 0x06, 0x05, 0x01, 0x01, 0x02, 0xFE,
                                             0x03, 0x00, 0x04, 0x03, 0x05, 0xFA]))
    #expect(EQCodec(model: go4).parse(reply) == EQSnapshot(activeCategory: 0x06, gains: [1, -2, 0, 3, -6]))
}

// MARK: - Captured from a real Go 4 (PID 20E4, firmware 0.6.4.0)

@Test func go4InfoBurstParses() {
    var d = FrameDecoder()
    let frames = d.feed(bytes("""
    AA 12 0B 00 C1 08 4A 42 4C 20 47 6F 20 34     AA 12 04 00 42 20 E4 AA 12 03 00 43 15 AA 12 03 00 44 2D     AA 12 03 00 46 00 AA 12 03 00 4C 01 AA 12 06 00 4D 30 36 34 30
    """))
    let tokens = frames.compactMap { InfoToken.parse($0.payload) }
    #expect(tokens == [
        .name("JBL Go 4"), .productID(0x20E4), .color(0x15), .battery(level: 45, charging: false),
        .audioChannel(.mono), .auracastSupport(true), .firmware("0.6.4.0"),
    ])
}

@Test func firmwareAcceptsBothByteAndAsciiForms() {
    #expect(FirmwareVersion.format([0x00, 0x07, 0x02, 0x00]) == "0.7.2.0")
    #expect(FirmwareVersion.format([0x30, 0x36, 0x34, 0x30]) == "0.6.4.0")
    #expect(FirmwareVersion.format([0x03, 0x05, 0x01]) == "3.5.1")
}

@Test func emptyGroupStatusMeansNoGroup() {
    let group = AuracastGroup(payload: [])
    #expect(group.channel == nil)
    #expect(group.type == nil)
    #expect(!group.isStereo)
}

// MARK: - Auracast (token 3C)

@Test func auracastTokenParses() {
    #expect(InfoToken.parse([0x00, 0x3C, 0x01]) == .auracast(0x01))
    #expect(InfoToken.parse([0x00, 0x3C, 0x00]) == .auracast(0x00))
    var decoder = FrameDecoder()
    let frames = decoder.feed(bytes("AA 12 03 00 3C 01"))
    #expect(frames.first.flatMap { InfoToken.parse($0.payload) } == .auracast(0x01))
}
