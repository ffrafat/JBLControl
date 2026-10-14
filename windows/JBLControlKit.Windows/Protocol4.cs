namespace JBLControlKit.Windows;

/// <summary>
/// "Protocol 4", the frame format of newer JBL speakers (Go 5, Grip, Xtreme 5, Boombox 4).
/// From the JBL Portable app via openjbl; not yet confirmed on hardware.
/// Ported from Sources/JBLControlKit/Protocol4.swift.
///
/// Header, little-endian: `identifier:u16 (DD00, DD01 forwarded) | command:u16 | count:u8 | index:u8 | length:u16`.
/// Payload of GET/SET: a list of `feature:u16le | length:u16le | value`.
/// </summary>
public sealed class P4Message : IEquatable<P4Message>
{
    public const ushort CommandGet = 0x0001;
    public const ushort CommandSet = 0x0002;
    public const ushort CommandNotification = 0x0003;
    private const int MaxPacketPayload = 490;

    public ushort Command { get; }
    public byte[] Payload { get; }

    public P4Message(ushort command, byte[] payload)
    {
        Command = command;
        Payload = payload;
    }

    /// <summary>One or more packets, split at 490 payload bytes.</summary>
    public List<byte[]> Packets
    {
        get
        {
            var chunks = new List<byte[]>();
            int total = Math.Max(Payload.Length, 1);
            for (int start = 0; start < total; start += MaxPacketPayload)
            {
                int end = Math.Min(start + MaxPacketPayload, Payload.Length);
                chunks.Add(Payload[start..end]);
            }
            var packets = new List<byte[]>();
            for (int index = 0; index < chunks.Count; index++)
            {
                var chunk = chunks[index];
                var p = new List<byte> { 0x00, 0xDD };
                p.AddRange(Le16(Command));
                p.Add((byte)chunks.Count);
                p.Add((byte)index);
                p.AddRange(Le16((ushort)chunk.Length));
                p.AddRange(chunk);
                packets.Add(p.ToArray());
            }
            return packets;
        }
    }

    public static P4Message Set(IEnumerable<(ushort Feature, byte[] Value)> features)
    {
        var payload = new List<byte>();
        foreach (var (feature, value) in features)
        {
            payload.AddRange(Le16(feature));
            payload.AddRange(Le16((ushort)value.Length));
            payload.AddRange(value);
        }
        return new P4Message(CommandSet, payload.ToArray());
    }

    public static P4Message Get(IEnumerable<ushort> features)
    {
        var payload = new List<byte>();
        foreach (var f in features) payload.AddRange(Le16(f));
        return new P4Message(CommandGet, payload.ToArray());
    }

    /// <summary><c>feature → value</c> pairs of a GET reply or notification.</summary>
    public Dictionary<ushort, byte[]> Features
    {
        get
        {
            var outDict = new Dictionary<ushort, byte[]>();
            int o = 0;
            var p = Payload;
            while (o + 4 <= p.Length)
            {
                ushort feature = (ushort)(p[o] | (p[o + 1] << 8));
                int length = p[o + 2] | (p[o + 3] << 8);
                if (o + 4 + length > p.Length) break;
                outDict[feature] = p[(o + 4)..(o + 4 + length)];
                o += 4 + length;
            }
            return outDict;
        }
    }

    private static byte[] Le16(ushort v) => new[] { (byte)(v & 0xFF), (byte)(v >> 8) };

    public bool Equals(P4Message? other) => other is not null && Command == other.Command && Payload.AsSpan().SequenceEqual(other.Payload);
    public override bool Equals(object? obj) => obj is P4Message m && Equals(m);

    public override int GetHashCode()
    {
        var h = new HashCode();
        h.Add(Command);
        foreach (var b in Payload) h.Add(b);
        return h.ToHashCode();
    }
}

/// <summary>Anything the speaker sends on the notify characteristic.</summary>
public abstract record Incoming
{
    public sealed record Legacy(Frame Value) : Incoming;

    public sealed record P4(P4Message Value) : Incoming;
}

/// <summary>Splits notifications into legacy `AA` frames and (reassembled) Protocol 4 messages.</summary>
public sealed class MessageDecoder
{
    private readonly FrameDecoder legacy = new();
    private Dictionary<byte, byte[]> p4Parts = new();
    private ushort p4Command;

    public List<Incoming> Feed(byte[] data)
    {
        if (data.Length >= 8 && data[1] == 0xDD && data[0] <= 0x01)
        {
            ushort command = (ushort)(data[2] | (data[3] << 8));
            byte count = data[4];
            byte index = data[5];
            int length = data[6] | (data[7] << 8);
            var chunk = data.Skip(8).Take(length).ToArray();
            if (index == 0)
            {
                p4Parts = new();
                p4Command = command;
            }
            p4Parts[index] = chunk;
            int expected = Math.Max(count, (byte)1);
            if (p4Parts.Count != expected) return new List<Incoming>();
            var payload = new List<byte>();
            for (byte i = 0; i < expected; i++)
            {
                if (p4Parts.TryGetValue(i, out var part)) payload.AddRange(part);
            }
            p4Parts = new();
            return new List<Incoming> { new Incoming.P4(new P4Message(p4Command, payload.ToArray())) };
        }
        return legacy.Feed(data).Select(f => (Incoming)new Incoming.Legacy(f)).ToList();
    }
}
