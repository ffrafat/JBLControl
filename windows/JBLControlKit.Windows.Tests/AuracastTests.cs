using JBLControlKit.Windows;
using Xunit;
using static JBLControlKit.Windows.Tests.TestFixtures;

namespace JBLControlKit.Windows.Tests;

// Frames from JBL Portable 6.9.33 (com.harman.ble.jbllink), decompiled:
// SetLinkModeCommand, SetChannelCommand, SetChannelLockCommand, ReqAuracastGroupCommand,
// SetAuraCastGroupCommand and SetAuracastGroupNonLLSCommand.
public class AuracastTests
{
    [Fact]
    public void LinkModeFramesMatchJblApp()
    {
        Assert.Equal(Bytes("AA 6A 01 02"), Frame.SetLinkMode(LinkMode.Auracast).Encoded);
        Assert.Equal(Bytes("AA 6A 01 01"), Frame.SetLinkMode(LinkMode.PartyBoost).Encoded);
        Assert.Equal(Bytes("AA 6A 01 00"), Frame.SetLinkMode(LinkMode.Off).Encoded);
        Assert.Equal(Bytes("AA 17 00"), Frame.RequestLinkRole.Encoded);
    }

    [Fact]
    public void ChannelFramesMatchJblApp()
    {
        Assert.Equal(Bytes("AA 15 03 00 46 01"), Frame.SetAudioChannel(AudioChannel.Left).Encoded);
        Assert.Equal(Bytes("AA 15 03 00 46 02"), Frame.SetAudioChannel(AudioChannel.Right).Encoded);
        Assert.Equal(Bytes("AA 15 03 00 46 00"), Frame.SetAudioChannel(AudioChannel.Mono).Encoded);
        Assert.Equal(Bytes("AA 15 03 00 49 01"), Frame.SetStereoLock(true).Encoded);
        Assert.Equal(Bytes("AA 15 03 00 49 00"), Frame.SetStereoLock(false).Encoded);
    }

    [Fact]
    public void StereoInfoTokensParse()
    {
        Assert.Equal(new InfoToken.Channel(AudioChannel.Left), InfoToken.Parse(new byte[] { 0x00, 0x46, 0x01 }));
        Assert.Equal(new InfoToken.Channel(AudioChannel.Right), InfoToken.Parse(new byte[] { 0x00, 0x46, 0x02 }));
        Assert.Equal(new InfoToken.Channel(AudioChannel.Mono), InfoToken.Parse(new byte[] { 0x00, 0x46, 0x00 }));
        Assert.Equal(new InfoToken.StereoLock(true), InfoToken.Parse(new byte[] { 0x00, 0x49, 0x01 }));
        Assert.Equal(new InfoToken.AuracastSupport(true), InfoToken.Parse(new byte[] { 0x00, 0x4C, 0x01 }));
        Assert.Equal(new InfoToken.LinkedDevices(2), InfoToken.Parse(new byte[] { 0x00, 0x45, 0x02 }));
    }

    [Fact]
    public void CompactStereoGroupWriteMatchesApp()
    {
        var create = Frame.SetAuracastGroup(new AuracastGroupRequest
        {
            Action = AuracastGroupAction.Create,
            Type = AuracastGroupType.Stereo,
            Channel = AudioChannel.Left,
            GroupId = new byte[] { 0x1A, 0x2B, 0x3C, 0x4D },
        });
        Assert.Equal(Bytes("AA A0 0F 01 01 01 02 01 01 04 01 01 05 04 1A 2B 3C 4D"), create.Encoded);

        var destroy = Frame.SetAuracastGroup(new AuracastGroupRequest
        {
            Action = AuracastGroupAction.Destroy,
            Type = AuracastGroupType.Stereo,
            Channel = AudioChannel.Mono,
            GroupId = new byte[] { 0x1A, 0x2B, 0x3C, 0x4D },
        });
        Assert.Equal(Bytes("AA A0 0F 01 01 02 02 01 01 04 01 00 05 04 1A 2B 3C 4D"), destroy.Encoded);
    }

    [Fact]
    public void LongLastingStereoGroupWriteMatchesApp()
    {
        var frame = Frame.SetAuracastGroup(new AuracastGroupRequest
        {
            Action = AuracastGroupAction.Create,
            Type = AuracastGroupType.Stereo,
            Role = DeviceRole.Master,
            Channel = AudioChannel.Right,
            GroupId = new byte[] { 0x01, 0x02, 0x03, 0x04 },
            Name = "Go 4",
            PartnerAddress = new byte[] { 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 },
            LongLasting = true,
        });
        Assert.Equal(Bytes(
            "AA A0 23 01 01 01 02 01 01 03 01 01 04 01 02 05 04 01 02 03 04 " +
            "06 04 47 6F 20 34 07 06 01 02 03 04 05 06 08 01 14"), frame.Encoded);
    }

    [Fact]
    public void AuracastGroupReplyParses()
    {
        var group = AuracastGroup.Parse(Bytes(
            "01 01 01 02 01 01 03 01 01 04 01 01 05 04 1A 2B 3C 4D 06 03 4B 69 74"));
        Assert.Equal(AuracastGroupAction.Create, group.Action);
        Assert.Equal(AuracastGroupType.Stereo, group.Type);
        Assert.Equal(DeviceRole.Master, group.Role);
        Assert.Equal(AudioChannel.Left, group.Channel);
        Assert.Equal(new byte[] { 0x1A, 0x2B, 0x3C, 0x4D }, group.GroupId);
        Assert.Equal("Kit", group.Name);
        Assert.True(group.IsStereo);
        Assert.Equal("1A2B3C4D", group.GroupIdHex);
    }

    [Fact]
    public void Protocol4AuracastAndChannelFrames()
    {
        Assert.Equal(Bytes("00 DD 02 00 01 00 05 00 04 20 01 00 01"),
            P4Message.Set(new[] { (P4Party.AuracastMode, new byte[] { 0x01 }) }).Packets.Single());
        Assert.Equal(Bytes("00 DD 02 00 01 00 05 00 04 2C 01 00 02"),
            P4Message.Set(new[] { (P4Party.Channel, new byte[] { (byte)AudioChannel.Right }) }).Packets.Single());
    }

    [Fact]
    public void Go4AdvertisesAuracastAndStereoChannel()
    {
        var go4 = Catalog.Model(0x20E4)!;
        Assert.Equal(SupportLevel.Verified, go4.Support);
        Assert.True(go4.HasAuracast);
        Assert.True(go4.HasStereoChannel);
        Assert.False(go4.StereoIsAutomatic);
        Assert.False(go4.WritesNeedOptIn);

        var duo = Catalog.Model(0x215C)!;
        Assert.True(duo.HasAuracast);
        Assert.True(duo.StereoIsAutomatic);
        Assert.False(duo.HasStereoChannel);
        Assert.True(duo.WritesNeedOptIn);
    }

    [Fact]
    public void SimpleEqSignatureFrameMatchesApp()
    {
        var charge5 = Catalog.Model(0x2040)!;
        Assert.Equal(new[] { "Signature", "Custom" }, charge5.PickerPresets.Select(p => p.Name));
        var signature = charge5.PickerPresets[0];
        Assert.Equal(0x01, signature.Category);
        Assert.Equal(Bytes("AA 6E 02 01 00"), new EQCodec(charge5).Select(signature, new float[] { 0, 0, 0 }).Single());
    }
}
