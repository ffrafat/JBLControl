using System.Text;

namespace JBLControlKit.Windows;

/// <summary>
/// JBL Portable BLE control protocol ("legacy" AA-framed generation), as used by the Flip 7.
/// Ported from Sources/JBLControlKit/JBLProtocol.swift — see docs/PROTOCOL-FLIP7.md for the
/// captures this is built from.
/// </summary>
public static class Jbl
{
    public const string ServiceUuid = "65786365-6C70-6F69-6E74-2E636F6D0000";
    /// <summary>Speaker → app notifications.</summary>
    public const string NotifyUuid = "65786365-6C70-6F69-6E74-2E636F6D0001";
    /// <summary>App → speaker commands.</summary>
    public const string WriteUuid = "65786365-6C70-6F69-6E74-2E636F6D0002";
    /// <summary>Bluetooth SIG company identifier used in JBL manufacturer advertising data.</summary>
    public const ushort HarmanCompanyId = 0x0057;
    /// <summary>Advertised service-data keys that identify JBL Portable speakers.</summary>
    public static readonly HashSet<string> AdvertisedServiceIds = new(StringComparer.OrdinalIgnoreCase) { "FDDF", "FC69", "DFFD" };

    /// <summary>Product ID from manufacturer data: `57 00 | PID little-endian | …`.</summary>
    public static ushort? ProductId(byte[] manufacturerData)
    {
        if (manufacturerData.Length < 4) return null;
        ushort company = (ushort)(manufacturerData[0] | (manufacturerData[1] << 8));
        if (company != HarmanCompanyId) return null;
        return (ushort)(manufacturerData[2] | (manufacturerData[3] << 8));
    }
}

public enum Command : byte
{
    DevAck = 0x00,
    RequestInfo = 0x11,
    Info = 0x12,
    RequestVersion = 0x41,
    Version = 0x42,
    NotifyEqChange = 0x64,
    SetAdvancedEq = 0x97,
    RequestAdvancedEq = 0x98,
    AdvancedEq = 0x99,
    Unsupported = 0xEE,
}

/// <summary>
/// An `AA`-framed request/reply. Declared <c>partial</c> so EQ.cs can add the <c>SetEq</c> factory
/// (mirroring the Swift <c>extension Frame</c> in EQ.swift).
/// </summary>
public readonly partial struct Frame : IEquatable<Frame>
{
    public const byte Identifier = 0xAA;
    /// <summary>Commands whose length field is two bytes big-endian.</summary>
    internal static readonly HashSet<byte> LongLengthCommands = new() { 0x92, 0x96, 0x97, 0x98, 0x99 };

    public byte CommandByte { get; }
    public byte[] Payload { get; }

    public Frame(byte command, byte[]? payload = null)
    {
        CommandByte = command;
        Payload = payload ?? Array.Empty<byte>();
    }

    public Frame(Command command, byte[]? payload = null) : this((byte)command, payload)
    {
    }

    public bool IsLong => LongLengthCommands.Contains(CommandByte);

    public byte[] Encoded
    {
        get
        {
            var outBytes = new List<byte> { Identifier, CommandByte };
            if (IsLong)
            {
                outBytes.Add((byte)(Payload.Length >> 8 & 0xFF));
                outBytes.Add((byte)(Payload.Length & 0xFF));
            }
            else
            {
                outBytes.Add((byte)Payload.Length);
            }
            outBytes.AddRange(Payload);
            return outBytes.ToArray();
        }
    }

    public static Frame RequestInfo => new(Command.RequestInfo);
    public static Frame RequestVersion => new(Command.RequestVersion);
    public static Frame RequestEq => new(Command.RequestAdvancedEq);

    public bool Equals(Frame other) => CommandByte == other.CommandByte && Payload.AsSpan().SequenceEqual(other.Payload);
    public override bool Equals(object? obj) => obj is Frame f && Equals(f);

    public override int GetHashCode()
    {
        var h = new HashCode();
        h.Add(CommandByte);
        foreach (var b in Payload) h.Add(b);
        return h.ToHashCode();
    }

    public static bool operator ==(Frame a, Frame b) => a.Equals(b);
    public static bool operator !=(Frame a, Frame b) => !a.Equals(b);
}

/// <summary>Reassembles frames that may be split across (or packed into) BLE notifications.</summary>
public sealed class FrameDecoder
{
    private readonly List<byte> buffer = new();

    public List<Frame> Feed(byte[] data)
    {
        buffer.AddRange(data);
        var frames = new List<Frame>();
        while (true)
        {
            int start = buffer.IndexOf(Frame.Identifier);
            if (start < 0)
            {
                buffer.Clear();
                break;
            }
            if (start > 0) buffer.RemoveRange(0, start);
            if (buffer.Count < 3) break;
            bool isLong = Frame.LongLengthCommands.Contains(buffer[1]);
            int header = isLong ? 4 : 3;
            if (buffer.Count < header) break;
            int size = isLong ? (buffer[2] << 8 | buffer[3]) : buffer[2];
            if (buffer.Count < header + size) break;
            frames.Add(new Frame(buffer[1], buffer.GetRange(header, size).ToArray()));
            buffer.RemoveRange(0, header + size);
        }
        return frames;
    }
}

// MARK: - Speaker info (0x12 tokens)

/// <summary>
/// One <c>0x12</c> notification carries one token: <c>00 | token | value</c>.
/// Tokens with the high bit set carry a length-prefixed UTF-8 string.
/// </summary>
public abstract record InfoToken
{
    public sealed record Name(string Value) : InfoToken;

    public sealed record Serial(string Value) : InfoToken;

    public sealed record ProductId(ushort Value) : InfoToken;

    public sealed record Color(byte Value) : InfoToken;

    /// <summary>Percentage in the low 7 bits; the high bit is set while charging (Flip 7: 0x8A = charging, 10%).</summary>
    public sealed record Battery(int Level, bool Charging) : InfoToken;

    public sealed record AudioChannel(byte Value) : InfoToken;

    public sealed record AudioSourceConnected(bool Value) : InfoToken;

    public sealed record Firmware(string Value) : InfoToken;

    public sealed record Other(byte Token, byte[] Value) : InfoToken
    {
        public bool Equals(Other? other) => other is not null && Token == other.Token && Value.AsSpan().SequenceEqual(other.Value);

        public override int GetHashCode()
        {
            var h = new HashCode();
            h.Add(Token);
            foreach (var b in Value) h.Add(b);
            return h.ToHashCode();
        }
    }

    public static InfoToken? Parse(byte[] payload)
    {
        if (payload.Length < 2) return null;
        byte token = payload[1];
        byte[] value = payload[2..];
        if ((token & 0x80) != 0 && value.Length > 0)
        {
            int length = value[0];
            var text = value[1..].Take(length).ToArray();
            string s = Encoding.UTF8.GetString(text);
            return token switch
            {
                0xC1 => new Name(s),
                0xC2 => new Serial(s),
                _ => new Other(token, text),
            };
        }
        return (token, value.Length) switch
        {
            (0x42, >= 2) => new ProductId((ushort)((value[0] << 8) | value[1])),
            (0x43, >= 1) => new Color(value[0]),
            (0x44, >= 1) => new Battery(value[0] & 0x7F, (value[0] & 0x80) != 0),
            (0x46, >= 1) => new AudioChannel(value[0]),
            (0x47, >= 1) => new AudioSourceConnected(value[0] != 0),
            (0x4D, >= 1) => new Firmware(FirmwareVersion.Format(value)),
            _ => new Other(token, value),
        };
    }
}

public static class FirmwareVersion
{
    /// <summary><c>00 07 02 00</c> → "0.7.2.0"</summary>
    public static string Format(byte[] bytes) => string.Join(".", bytes);
}
