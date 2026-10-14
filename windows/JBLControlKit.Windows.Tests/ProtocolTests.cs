using JBLControlKit.Windows;
using Xunit;
using static JBLControlKit.Windows.Tests.TestFixtures;

namespace JBLControlKit.Windows.Tests;

public class ProtocolTests
{
    [Fact]
    public void RequestFramesEncode()
    {
        Assert.Equal(Bytes("AA 11 00"), Frame.RequestInfo.Encoded);
        Assert.Equal(Bytes("AA 41 00"), Frame.RequestVersion.Encoded);
        Assert.Equal(Bytes("AA 98 00 00"), Frame.RequestEq.Encoded);
    }

    [Fact]
    public void DecoderSplitsAndJoinsNotifications()
    {
        var d = new FrameDecoder();
        Assert.Empty(d.Feed(Bytes("AA 12 03 00 44")));
        var frames = d.Feed(Bytes("1E AA 42 04 00 07 02 00"));
        Assert.Equal(new[]
        {
            new Frame(0x12, new byte[] { 0x00, 0x44, 0x1E }),
            new Frame(0x42, new byte[] { 0x00, 0x07, 0x02, 0x00 }),
        }, frames);
    }

    [Fact]
    public void InfoTokensParse()
    {
        var d = new FrameDecoder();
        var frames = d.Feed(Bytes("""
            AA 12 11 00 C1 0E 46 46 52 20 4A 42 4C 20 46 6C 69 70 20 37
            AA 12 04 00 42 21 07 AA 12 03 00 43 01 AA 12 03 00 44 1E
            AA 12 03 00 47 00 AA 12 06 00 4D 00 07 02 00
            """));
        var tokens = frames.Select(f => InfoToken.Parse(f.Payload)).Where(t => t is not null).ToList();
        Assert.Equal(new InfoToken[]
        {
            new InfoToken.Name("FFR JBL Flip 7"),
            new InfoToken.ProductId(0x2107),
            new InfoToken.Color(0x01),
            new InfoToken.Battery(30, false),
            new InfoToken.AudioSourceConnected(false),
            new InfoToken.Firmware("0.7.2.0"),
        }, tokens);
    }

    [Fact]
    public void AdvancedEqReplyParses()
    {
        var d = new FrameDecoder();
        var frame = d.Feed(Bytes(Flip7EqReplyHex)).First();
        var state = EQState.TryParse(frame.Payload);
        Assert.NotNull(state);
        Assert.Equal(0x06, state!.ActiveCategory);
        Assert.Equal(0xC2, state.CurveCategory);
        Assert.Equal((uint)48000, state.SampleRate);
        Assert.Equal(new float[] { 4.5f, 3.5f, 2.5f, 1.5f, 2.5f, 3.5f, 4.5f }, state.Bands.Select(b => b.Gain));
        Assert.Equal(new float[] { 125, 250, 500, 1000, 2000, 4000, 8000 }, state.Bands.Select(b => b.Frequency));
    }

    [Fact]
    public void ManufacturerDataYieldsProductId()
    {
        Assert.Equal((ushort)0x2107, Jbl.ProductId(Bytes("57 00 07 21 01 28 ED 4D 20 31 29 00")));
        Assert.Null(Jbl.ProductId(Bytes("4C 00 07 21")));
    }

    [Fact]
    public void ResponseOfFlatCurveIsZeroAndBoostShows()
    {
        Assert.True(Math.Abs(EQResponse.Gain(1000, EQLayouts.ParametricShape)) < 0.001);
        var energetic = Flip7.Presets.First(p => p.Category == 0x08);
        Assert.True(EQResponse.Gain(200, energetic.Bands) > 6);
    }

    // Captured from the same Flip 7 while plugged in.
    [Fact]
    public void BatteryHighBitMeansCharging()
    {
        Assert.Equal(new InfoToken.Battery(10, true), InfoToken.Parse(new byte[] { 0x00, 0x44, 0x8A }));
        Assert.Equal(new InfoToken.Battery(100, false), InfoToken.Parse(new byte[] { 0x00, 0x44, 0x64 }));
    }
}
