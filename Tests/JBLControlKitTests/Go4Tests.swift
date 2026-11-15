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

@Test func go4PresetSelectKeepsCustomLevels() throws {
    let go4 = try #require(Catalog.model(0x210A))
    let signature = try #require(go4.presets.first { $0.category == 0x06 })
    let frame = try #require(EQCodec(model: go4).select(signature, customGains: [1, -2, 0, 3, -6]).first)
    #expect(frame == bytes("AA 97 00 0E 06 C1 06 05 01 01 02 FE 03 00 04 03 05 FA"))
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

// MARK: - Auracast (token 3C)

@Test func auracastFramesMatchJBLApp() {
    #expect(Frame.requestToken(InfoTokenID.auracast).encoded == bytes("AA 13 02 00 3C"))
    #expect(Frame.setAuracast(true).encoded == bytes("AA 13 04 00 3C 01 01"))
    #expect(Frame.setAuracast(false).encoded == bytes("AA 13 04 00 3C 01 00"))
}

@Test func auracastTokenParses() {
    #expect(InfoToken.parse([0x00, 0x3C, 0x01]) == .auracast(0x01))
    #expect(InfoToken.parse([0x00, 0x3C, 0x00]) == .auracast(0x00))
    var decoder = FrameDecoder()
    let frames = decoder.feed(bytes("AA 12 03 00 3C 01"))
    #expect(frames.first.flatMap { InfoToken.parse($0.payload) } == .auracast(0x01))
}
