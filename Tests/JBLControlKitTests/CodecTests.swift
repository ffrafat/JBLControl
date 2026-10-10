import Foundation
import Testing
@testable import JBLControlKit

// MARK: Catalog

@Test func catalogClassifiesModels() throws {
    let expectations: [(UInt16, ProtocolFamily, SupportLevel)] = [
        (0x2107, .legacyParametric, .verified),     // Flip 7
        (0x20E3, .legacyParametric, .verified),     // Charge 6
        (0x20DC, .legacyLevels, .beta),             // Xtreme 4
        (0x2040, .legacySimple, .beta),             // Charge 5
        (0x214E, .protocol4Parametric, .experimental), // Boombox 4
        (0x2168, .protocol4Quantized, .experimental),  // Go 5
        (0x0023, .infoOnly, .unsupported),          // Flip 3 (SPP)
    ]
    for (pid, family, support) in expectations {
        let model = try #require(Catalog.model(pid))
        #expect(model.family == family, "\(model.name)")
        #expect(model.support == support, "\(model.name)")
    }
    #expect(Catalog.all.count == 37)
}

@Test func flip7PickerHasJBLPresetsThenCustom() {
    #expect(flip7.pickerPresets.map(\.name) == ["Signature", "Chill", "Energetic", "Vocal", "Custom"])
    #expect(flip7.pickerPresets.last?.category == 0xC2)
    #expect(flip7.color(0x01).name == "Black")
    #expect(Catalog.model(0x2168)!.color(0x1A).name == "Squad")
}

@Test func parametricGainGridSnapsLikeJBLApp() {
    let bands = flip7.customBands
    #expect(bands.map(\.label) == ["125", "250", "500", "1k", "2k", "4k", "8k"])
    #expect(bands[0].snap(-1.0) == -0.75)
    #expect(bands[0].snap(-12) == -9)
    #expect(bands[3].snap(2.3) == 2.5)
    #expect(bands[3].snap(9) == 6)
}

// MARK: Legacy parametric (verified on Flip 7)

@Test func legacyParametricRoundTripsSpeakerBytes() throws {
    let codec = EQCodec(model: flip7)
    var d = MessageDecoder()
    let reply = try #require(d.feed(bytes(flip7EQReply)).first)
    let snapshot = try #require(codec.parse(reply))
    #expect(snapshot == EQSnapshot(activeCategory: 0x06, gains: [4.5, 3.5, 2.5, 1.5, 2.5, 3.5, 4.5]))

    // Writing the speaker's own curve back reproduces its band bytes exactly.
    let write = try #require(codec.setCustom(snapshot.gains!).first)
    #expect(write.prefix(7) == bytes("AA 97 00 62 C2 C2 07"))
    #expect(write.dropFirst(6) == bytes(flip7EQReply).dropFirst(6))
}

@Test func legacyParametricPresetSelectSendsPresetBands() throws {
    let codec = EQCodec(model: flip7)
    let energetic = try #require(flip7.presets.first { $0.category == 0x08 })
    let write = try #require(codec.select(energetic, customGains: Array(repeating: 0, count: 7)).first)
    #expect(write.prefix(7) == bytes("AA 97 00 62 08 08 07"))
    let state = try #require(EQState(payload: Array(write.dropFirst(4))))
    #expect(state.bands == energetic.bands)
}

// MARK: Legacy levels / simple (from the JBL app, unconfirmed)

@Test func legacyLevelsWriteLayout() throws {
    let model = try #require(Catalog.model(0x20DC))
    #expect(model.customBands.count == 5)
    let write = try #require(EQCodec(model: model).setCustom([1, -2, 0, 3, -6]).first)
    #expect(write == bytes("AA 97 00 0E C1 C1 06 05 01 01 02 FE 03 00 04 03 05 FA"))
}

@Test func legacySimpleWriteAndReply() throws {
    let model = try #require(Catalog.model(0x2040))
    let codec = EQCodec(model: model)
    #expect(codec.readRequests() == [bytes("AA 6C 01 00")])
    #expect(codec.setCustom([2, 0, -3]) == [bytes("AA 6E 08 C1 03 01 02 02 00 03 FD")])
    // scope 00, active C1, category C1 with bass +2, mid 0, treble −3
    let reply = Incoming.legacy(Frame(0x6D, [0x00, 0xC1, 0xC1, 0x03, 0x01, 0x02, 0x02, 0x00, 0x03, 0xFD]))
    #expect(codec.parse(reply) == EQSnapshot(activeCategory: 0xC1, gains: [2, 0, -3]))
}

// MARK: Protocol 4 (byte layout pinned by openjbl's test_protocol4_write_frame_is_byte_exact)

@Test func protocol4ParametricWriteIsByteExact() throws {
    let model = try #require(Catalog.model(0x214E))
    let packet = try #require(EQCodec(model: model).setCustom(Array(repeating: 0, count: 7)).first)
    let b = [UInt8](packet)
    #expect(Array(b[0..<6]) == [0x00, 0xDD, 0x02, 0x00, 0x01, 0x00])   // DD00, SET, 1 packet, index 0
    #expect(Int(b[6]) | Int(b[7]) << 8 == b.count - 8)
    #expect(Array(b[8..<10]) == [0x02, 0x0E])                           // feature 0E02
    let value = Array(b[12...])
    #expect(Int(b[10]) | Int(b[11]) << 8 == value.count)
    #expect(Array(value[0..<3]) == [0xC1, 0x01, 0x07])
    #expect(Array(value[3..<19]) == [0, 0, 0, 0, 0, 0, 0xBB, 0x80, 0, 0, 0, 0, 0, 0, 0, 0])
    // Band 1: low shelf, frequency before gain.
    #expect(value[19] == 0)
    #expect(EQState.float(value, 20) == 125 && EQState.float(value, 24) == 0)
}

@Test func protocol4ReplyRoundTrips() throws {
    let model = try #require(Catalog.model(0x214E))
    let codec = EQCodec(model: model)
    let gains: [Float] = [3, -1.5, 0, 2, 0, 1, -2]
    // A GET reply carrying the same feature value we would write.
    let value = P4EQ.parametricValue(category: 0xC1, bands: zip(EQLayouts.parametricShape, gains).map { var b = $0; b.gain = $1; return b })
    let reply = P4Message(command: P4Message.get, payload: [0x02, 0x0E, UInt8(value.count & 0xFF), UInt8(value.count >> 8)] + value)
    var d = MessageDecoder()
    let incoming = try #require(d.feed(reply.packets[0]).first)
    #expect(codec.parse(incoming) == EQSnapshot(activeCategory: 0xC1, gains: gains))
}

@Test func protocol4QuantizedUsesStepIndices() throws {
    let model = try #require(Catalog.model(0x2168))
    let packet = try #require(EQCodec(model: model).setCustom([6, 0, -6, 0.5, 0, 0, 0]).first)
    // value: C1 | band1 index of +6 = 0 | 0 dB = 12 | −6 dB = 24 | +0.5 = 11 | 12 | 12 | 12
    #expect(Array(packet.suffix(8)) == [0xC1, 0, 12, 24, 11, 12, 12, 12])
    #expect(P4EQ.quantizedValue([-9, 0, 0, 0, 0, 0, 0])?[1] == 24)
    #expect(P4EQ.quantizedValue([0.3, 0, 0, 0, 0, 0, 0]) == nil)
}

@Test func protocol4MessagesSplitAndReassemble() {
    let big = P4Message(command: P4Message.get, payload: Array(repeating: 0x5A, count: 1000))
    let packets = big.packets
    #expect(packets.count == 3)
    var d = MessageDecoder()
    #expect(d.feed(packets[0]).isEmpty)
    #expect(d.feed(packets[1]).isEmpty)
    #expect(d.feed(packets[2]) == [.p4(big)])
}
