import Foundation
import Testing
@testable import JBLControlKit

// Frames from JBL Portable 6.9.33 (com.harman.ble.jbllink), decompiled:
// SetLinkModeCommand, SetChannelCommand, SetChannelLockCommand, ReqAuracastGroupCommand,
// SetAuraCastGroupCommand and SetAuracastGroupNonLLSCommand.

@Test func linkModeFramesMatchJBLApp() {
    #expect(Frame.setLinkMode(.auracast).encoded == bytes("AA 6A 01 02"))
    #expect(Frame.setLinkMode(.partyBoost).encoded == bytes("AA 6A 01 01"))
    #expect(Frame.setLinkMode(.off).encoded == bytes("AA 6A 01 00"))
    #expect(Frame.requestLinkRole.encoded == bytes("AA 17 00"))
}

@Test func channelFramesMatchJBLApp() {
    // SetDeviceInfo (0x15): device index, token 0x46, channel byte.
    #expect(Frame.setAudioChannel(.left).encoded == bytes("AA 15 03 00 46 01"))
    #expect(Frame.setAudioChannel(.right).encoded == bytes("AA 15 03 00 46 02"))
    #expect(Frame.setAudioChannel(.mono).encoded == bytes("AA 15 03 00 46 00"))
    #expect(Frame.setStereoLock(true).encoded == bytes("AA 15 03 00 49 01"))
    #expect(Frame.setStereoLock(false).encoded == bytes("AA 15 03 00 49 00"))
}

@Test func audioChannelSwaps() {
    #expect(AudioChannel.left.swapped == .right)
    #expect(AudioChannel.right.swapped == .left)
    #expect(AudioChannel.mono.swapped == .mono)
    #expect(AudioChannel(channel: 2) == .right)
    #expect(AudioChannel(channel: 9) == nil)
}

@Test func stereoInfoTokensParse() {
    #expect(InfoToken.parse([0x00, 0x46, 0x01]) == .audioChannel(.left))
    #expect(InfoToken.parse([0x00, 0x46, 0x02]) == .audioChannel(.right))
    #expect(InfoToken.parse([0x00, 0x46, 0x00]) == .audioChannel(.mono))
    #expect(InfoToken.parse([0x00, 0x49, 0x01]) == .stereoLock(true))
    #expect(InfoToken.parse([0x00, 0x4C, 0x01]) == .auracastSupport(true))
    #expect(InfoToken.parse([0x00, 0x45, 0x02]) == .linkedDevices(2))
}

@Test func compactStereoGroupWriteMatchesApp() throws {
    let frame = Frame.setAuracastGroup(.init(action: .create, type: .stereo, channel: .left,
                                             groupID: [0x1A, 0x2B, 0x3C, 0x4D]))
    #expect(frame.encoded == bytes("AA A0 0F 01 01 01 02 01 01 04 01 01 05 04 1A 2B 3C 4D"))

    let destroy = Frame.setAuracastGroup(.init(action: .destroy, type: .stereo, channel: .mono,
                                               groupID: [0x1A, 0x2B, 0x3C, 0x4D]))
    #expect(destroy.encoded == bytes("AA A0 0F 01 01 02 02 01 01 04 01 00 05 04 1A 2B 3C 4D"))
}

@Test func longLastingStereoGroupWriteMatchesApp() {
    let frame = Frame.setAuracastGroup(.init(action: .create, type: .stereo, role: .master,
                                             channel: .right, groupID: [0x01, 0x02, 0x03, 0x04],
                                             name: "Go 4", partnerAddress: [1, 2, 3, 4, 5, 6],
                                             longLasting: true))
    #expect(frame.encoded == bytes("""
    AA A0 23 01 01 01 02 01 01 03 01 01 04 01 02 05 04 01 02 03 04     06 04 47 6F 20 34 07 06 01 02 03 04 05 06 08 01 14
    """))
}

@Test func auracastGroupReplyParses() throws {
    var d = MessageDecoder()
    let messages = d.feed(bytes("""
    AA A2 17 01 01 01 02 01 01 03 01 01 04 01 01 05 04 1A 2B 3C 4D 06 03 4B 69 74
    """))
    guard case .legacy(let frame) = try #require(messages.first) else {
        Issue.record("expected a legacy frame")
        return
    }
    #expect(frame.command == Command.auracastGroup.rawValue)
    let group = AuracastGroup(payload: frame.payload)
    #expect(group.action == .create)
    #expect(group.type == .stereo)
    #expect(group.role == .master)
    #expect(group.channel == .left)
    #expect(group.groupID == [0x1A, 0x2B, 0x3C, 0x4D])
    #expect(group.name == "Kit")
    #expect(group.isStereo)
    #expect(group.groupIDHex == "1A2B3C4D")
}

@Test func protocol4AuracastAndChannelFrames() {
    // DeviceFeature ids from JBL's app: AuraCastMode 0x2004, PartyChannelType 0x2C04.
    #expect(P4Message.set([(P4Party.auracastMode, [0x01])]).packets
        == [bytes("00 DD 02 00 01 00 05 00 04 20 01 00 01")])
    #expect(P4Message.set([(P4Party.channel, [AudioChannel.right.rawValue])]).packets
        == [bytes("00 DD 02 00 01 00 05 00 04 2C 01 00 02")])
}

@Test func protocol4PartyFeaturesAreParsed() {
    let model = Catalog.model(0x214E)!
    let channel = P4Message(command: P4Message.get,
                            payload: [0x04, 0x2C, 0x01, 0x00, 0x02])
    #expect(model.family.usesProtocol4)
    #expect(P4Party.channel == 0x2C04)
    #expect(channel.features[P4Party.channel] == [0x02])
}

@Test func go4AdvertisesAuracastAndStereoChannel() throws {
    let go4 = try #require(Catalog.model(0x20E4))
    #expect(go4.hasAuracast)
    #expect(go4.hasStereoChannel)
    #expect(!go4.stereoIsAutomatic)
    #expect(!go4.writesNeedOptIn)

    let duo = try #require(Catalog.model(0x215C))
    #expect(duo.hasAuracast)
    #expect(duo.stereoIsAutomatic)
    #expect(!duo.hasStereoChannel)
    #expect(duo.writesNeedOptIn)
}

@Test func simpleEQSignatureFrameMatchesApp() throws {
    let charge5 = try #require(Catalog.model(0x2040))
    #expect(charge5.pickerPresets.map(\.name) == ["Signature", "Custom"])
    let signature = try #require(charge5.pickerPresets.first)
    #expect(signature.category == 0x01)
    #expect(EQCodec(model: charge5).select(signature, customGains: [0, 0, 0]) == [bytes("AA 6E 02 01 00")])
}

@Test func simpleEQCannotSelectAnUnknownPreset() throws {
    let charge5 = try #require(Catalog.model(0x2040))
    let energetic = EQPreset(category: 0x08, name: "Energetic", bands: [])
    #expect(EQCodec(model: charge5).select(energetic, customGains: [0, 0, 0]).isEmpty)
}
