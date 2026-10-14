using JBLControlKit.Windows;
using Xunit;
using static JBLControlKit.Windows.Tests.TestFixtures;

namespace JBLControlKit.Windows.Tests;

public class CodecTests
{
    // MARK: Catalog

    [Theory]
    [InlineData(0x2107, ProtocolFamily.LegacyParametric, SupportLevel.Verified)] // Flip 7
    [InlineData(0x20E3, ProtocolFamily.LegacyParametric, SupportLevel.Verified)] // Charge 6
    [InlineData(0x20DC, ProtocolFamily.LegacyLevels, SupportLevel.Beta)] // Xtreme 4
    [InlineData(0x2040, ProtocolFamily.LegacySimple, SupportLevel.Beta)] // Charge 5
    [InlineData(0x214E, ProtocolFamily.Protocol4Parametric, SupportLevel.Experimental)] // Boombox 4
    [InlineData(0x2168, ProtocolFamily.Protocol4Quantized, SupportLevel.Experimental)] // Go 5
    [InlineData(0x0023, ProtocolFamily.InfoOnly, SupportLevel.Unsupported)] // Flip 3 (SPP)
    public void CatalogClassifiesModels(int pid, ProtocolFamily family, SupportLevel support)
    {
        var model = Catalog.Model((ushort)pid);
        Assert.NotNull(model);
        Assert.Equal(family, model!.Family);
        Assert.Equal(support, model.Support);
    }

    [Fact]
    public void CatalogHas37Models() => Assert.Equal(37, Catalog.All.Count);

    [Fact]
    public void Flip7PickerHasJblPresetsThenCustom()
    {
        Assert.Equal(new[] { "Signature", "Chill", "Energetic", "Vocal", "Custom" }, Flip7.PickerPresets.Select(p => p.Name));
        Assert.Equal(0xC2, Flip7.PickerPresets.Last().Category);
        Assert.Equal("Black", Flip7.Color(0x01).Name);
        Assert.Equal("Squad", Catalog.Model(0x2168)!.Color(0x1A).Name);
    }

    [Fact]
    public void ParametricGainGridSnapsLikeJblApp()
    {
        var bands = Flip7.CustomBands;
        Assert.Equal(new[] { "125", "250", "500", "1k", "2k", "4k", "8k" }, bands.Select(b => b.Label));
        Assert.Equal(-0.75f, bands[0].Snap(-1.0f));
        Assert.Equal(-9f, bands[0].Snap(-12f));
        Assert.Equal(2.5f, bands[3].Snap(2.3f));
        Assert.Equal(6f, bands[3].Snap(9f));
    }

    // MARK: Legacy parametric (verified on Flip 7)

    [Fact]
    public void LegacyParametricRoundTripsSpeakerBytes()
    {
        var codec = new EQCodec(Flip7);
        var d = new MessageDecoder();
        var reply = d.Feed(Bytes(Flip7EqReplyHex)).First();
        var snapshot = codec.Parse(reply);
        Assert.NotNull(snapshot);
        Assert.Equal(new EQSnapshot(0x06, new float[] { 4.5f, 3.5f, 2.5f, 1.5f, 2.5f, 3.5f, 4.5f }), snapshot);

        // Writing the speaker's own curve back reproduces its band bytes exactly.
        var write = codec.SetCustom(snapshot!.Gains!).First();
        Assert.Equal(Bytes("AA 97 00 62 C2 C2 07"), write.Take(7));
        Assert.Equal(Bytes(Flip7EqReplyHex).Skip(6), write.Skip(6));
    }

    [Fact]
    public void LegacyParametricPresetSelectSendsPresetBands()
    {
        var codec = new EQCodec(Flip7);
        var energetic = Flip7.Presets.First(p => p.Category == 0x08);
        var write = codec.Select(energetic, new float[7]).First();
        Assert.Equal(Bytes("AA 97 00 62 08 08 07"), write.Take(7));
        var state = EQState.TryParse(write.Skip(4).ToArray());
        Assert.NotNull(state);
        Assert.Equal(energetic.Bands, state!.Bands);
    }

    // MARK: Legacy levels / simple (from the JBL app, unconfirmed)

    [Fact]
    public void LegacyLevelsWriteLayout()
    {
        var model = Catalog.Model(0x20DC)!;
        Assert.Equal(5, model.CustomBands.Count);
        var write = new EQCodec(model).SetCustom(new float[] { 1, -2, 0, 3, -6 }).First();
        Assert.Equal(Bytes("AA 97 00 0E C1 C1 06 05 01 01 02 FE 03 00 04 03 05 FA"), write);
    }

    [Fact]
    public void LegacySimpleWriteAndReply()
    {
        var model = Catalog.Model(0x2040)!;
        var codec = new EQCodec(model);
        Assert.Equal(new[] { Bytes("AA 6C 01 00") }, codec.ReadRequests());
        Assert.Equal(new[] { Bytes("AA 6E 08 C1 03 01 02 02 00 03 FD") }, codec.SetCustom(new float[] { 2, 0, -3 }));
        // scope 00, active C1, category C1 with bass +2, mid 0, treble -3
        var reply = new Incoming.Legacy(new Frame(0x6D, new byte[] { 0x00, 0xC1, 0xC1, 0x03, 0x01, 0x02, 0x02, 0x00, 0x03, 0xFD }));
        Assert.Equal(new EQSnapshot(0xC1, new float[] { 2, 0, -3 }), codec.Parse(reply));
    }

    // MARK: Protocol 4 (byte layout pinned by openjbl's test_protocol4_write_frame_is_byte_exact)

    [Fact]
    public void Protocol4ParametricWriteIsByteExact()
    {
        var model = Catalog.Model(0x214E)!;
        var b = new EQCodec(model).SetCustom(new float[7]).First();
        Assert.Equal(new byte[] { 0x00, 0xDD, 0x02, 0x00, 0x01, 0x00 }, b.Take(6)); // DD00, SET, 1 packet, index 0
        Assert.Equal(b.Length - 8, b[6] | (b[7] << 8));
        Assert.Equal(new byte[] { 0x02, 0x0E }, b.Skip(8).Take(2)); // feature 0E02
        var value = b.Skip(12).ToArray();
        Assert.Equal(value.Length, b[10] | (b[11] << 8));
        Assert.Equal(new byte[] { 0xC1, 0x01, 0x07 }, value.Take(3));
        Assert.Equal(new byte[] { 0, 0, 0, 0, 0, 0, 0xBB, 0x80, 0, 0, 0, 0, 0, 0, 0, 0 }, value.Skip(3).Take(16));
        // Band 1: low shelf, frequency before gain.
        Assert.Equal(0, value[19]);
        Assert.Equal(125, EQState.ReadFloat(value, 20));
        Assert.Equal(0, EQState.ReadFloat(value, 24));
    }

    [Fact]
    public void Protocol4ReplyRoundTrips()
    {
        var model = Catalog.Model(0x214E)!;
        var codec = new EQCodec(model);
        float[] gains = { 3, -1.5f, 0, 2, 0, 1, -2 };
        // A GET reply carrying the same feature value we would write.
        var bands = EQLayouts.ParametricShape.Zip(gains, (band, g) => new EQBand(band.Type, band.Frequency, g, band.Q)).ToArray();
        var value = P4EQ.ParametricValue(0xC1, bands);
        var header = new byte[] { 0x02, 0x0E, (byte)(value.Length & 0xFF), (byte)(value.Length >> 8) };
        var reply = new P4Message(P4Message.CommandGet, header.Concat(value).ToArray());
        var d = new MessageDecoder();
        var incoming = d.Feed(reply.Packets[0]).First();
        Assert.Equal(new EQSnapshot(0xC1, gains), codec.Parse(incoming));
    }

    [Fact]
    public void Protocol4QuantizedUsesStepIndices()
    {
        var model = Catalog.Model(0x2168)!;
        var packet = new EQCodec(model).SetCustom(new float[] { 6, 0, -6, 0.5f, 0, 0, 0 }).First();
        // value: C1 | band1 index of +6 = 0 | 0 dB = 12 | -6 dB = 24 | +0.5 = 11 | 12 | 12 | 12
        Assert.Equal(new byte[] { 0xC1, 0, 12, 24, 11, 12, 12, 12 }, packet.Skip(packet.Length - 8));
        var quantized = P4EQ.QuantizedValue(new float[] { -9, 0, 0, 0, 0, 0, 0 });
        Assert.NotNull(quantized);
        Assert.Equal(24, quantized![1]);
        Assert.Null(P4EQ.QuantizedValue(new float[] { 0.3f, 0, 0, 0, 0, 0, 0 }));
    }

    [Fact]
    public void Protocol4MessagesSplitAndReassemble()
    {
        var big = new P4Message(P4Message.CommandGet, Enumerable.Repeat((byte)0x5A, 1000).ToArray());
        var packets = big.Packets;
        Assert.Equal(3, packets.Count);
        var d = new MessageDecoder();
        Assert.Empty(d.Feed(packets[0]));
        Assert.Empty(d.Feed(packets[1]));
        Assert.Equal(new Incoming[] { new Incoming.P4(big) }, d.Feed(packets[2]));
    }

    // MARK: Speaker identity

    [Fact]
    public void SameSpeakerAcrossRotatedAddressesAndTruncatedNames()
    {
        Assert.True(SpeakerIdentity.Matches("FFR JBL Fli", 0x2107, "FFR JBL Flip 7", 0x2107));
        Assert.True(SpeakerIdentity.Matches("FFR JBL Flip 7", null, "FFR JBL Fli", 0x2107));
        Assert.False(SpeakerIdentity.Matches("FFR JBL Flip 7", 0x2107, "Kitchen", 0x2107));
        Assert.False(SpeakerIdentity.Matches("JBL Flip 7", 0x2107, "JBL Flip 7", 0x20E3));
        Assert.False(SpeakerIdentity.Matches("", 0x2107, "JBL Flip 7", 0x2107));
    }
}
