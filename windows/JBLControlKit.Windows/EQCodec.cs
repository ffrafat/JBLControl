namespace JBLControlKit.Windows;

// Ported from Sources/JBLControlKit/EQCodec.swift.

/// <summary>What the app shows for a speaker's EQ, independent of protocol family.</summary>
public sealed class EQSnapshot : IEquatable<EQSnapshot>
{
    /// <summary>Selected preset category, or the model's custom category.</summary>
    public byte ActiveCategory { get; }

    /// <summary>Custom curve, one gain per <c>SpeakerModel.CustomBands</c>. Null when the reply doesn't carry it.</summary>
    public float[]? Gains { get; }

    public EQSnapshot(byte activeCategory, float[]? gains)
    {
        ActiveCategory = activeCategory;
        Gains = gains;
    }

    public bool Equals(EQSnapshot? other)
    {
        if (other is null) return false;
        if (ActiveCategory != other.ActiveCategory) return false;
        if (Gains is null || other.Gains is null) return Gains is null == (other.Gains is null);
        return Gains.AsSpan().SequenceEqual(other.Gains);
    }

    public override bool Equals(object? obj) => obj is EQSnapshot s && Equals(s);
    public override int GetHashCode() => HashCode.Combine(ActiveCategory, Gains?.Length ?? 0);
}

/// <summary>Builds EQ reads/writes and parses replies for one model's protocol family.</summary>
public sealed class EQCodec
{
    public SpeakerModel Model { get; }

    public EQCodec(SpeakerModel model)
    {
        Model = model;
    }

    /// <summary>Whether a write is answered with the new state (otherwise the app re-reads).</summary>
    public bool WriteRepliesWithState => Model.Family == ProtocolFamily.LegacyParametric;

    // MARK: Requests

    public List<byte[]> ReadRequests() => Model.Family switch
    {
        ProtocolFamily.LegacyParametric or ProtocolFamily.LegacyLevels => new List<byte[]> { Frame.RequestEq.Encoded },
        ProtocolFamily.LegacySimple => new List<byte[]> { new Frame(0x6C, new byte[] { 0x00 }).Encoded },
        ProtocolFamily.Protocol4Parametric or ProtocolFamily.Protocol4Quantized =>
            P4Message.Set(new[] { (P4EQ.Query, new byte[] { 0xFF }) }).Packets,
        _ => new List<byte[]>(),
    };

    public List<byte[]> Select(EQPreset preset, float[] customGains)
    {
        if (preset.Category == Model.CustomCategory) return SetCustom(customGains);
        switch (Model.Family)
        {
            case ProtocolFamily.LegacyParametric:
                return new List<byte[]> { Frame.SetEq(preset.Category, preset.Bands).Encoded };
            case ProtocolFamily.LegacyLevels:
                return new List<byte[]> { LevelsFrame(preset.Category, customGains).Encoded };
            case ProtocolFamily.Protocol4Parametric:
                if (!P4EQ.CategoryMap.TryGetValue(preset.Category, out byte mapped) || preset.Bands.Length != 7)
                    return new List<byte[]>();
                return P4Message.Set(new[] { (P4EQ.Parametric, P4EQ.ParametricValue(mapped, preset.Bands)) }).Packets;
            default: // legacySimple, protocol4Quantized, infoOnly
                return new List<byte[]>();
        }
    }

    public List<byte[]> SetCustom(float[] gains)
    {
        switch (Model.Family)
        {
            case ProtocolFamily.LegacyParametric:
                return new List<byte[]> { Frame.SetEq(Model.CustomCategory, ParametricBands(gains)).Encoded };
            case ProtocolFamily.LegacyLevels:
                return new List<byte[]> { LevelsFrame(Model.CustomCategory, gains).Encoded };
            case ProtocolFamily.LegacySimple:
            {
                if (gains.Length != 3) return new List<byte[]>();
                byte[] v = gains.Select(ToSignedByte).ToArray();
                return new List<byte[]>
                {
                    new Frame(0x6E, new byte[] { Model.CustomCategory, 3, 1, v[0], 2, v[1], 3, v[2] }).Encoded,
                };
            }
            case ProtocolFamily.Protocol4Parametric:
                return P4Message.Set(new[] { (P4EQ.Parametric, P4EQ.ParametricValue(0xC1, ParametricBands(gains))) }).Packets;
            case ProtocolFamily.Protocol4Quantized:
            {
                byte[]? value = P4EQ.QuantizedValue(gains);
                return value is null ? new List<byte[]>() : P4Message.Set(new[] { (P4EQ.Quantized, value) }).Packets;
            }
            default: // infoOnly
                return new List<byte[]>();
        }
    }

    // MARK: Replies

    public EQSnapshot? Parse(Incoming message)
    {
        if (Model.Family == ProtocolFamily.LegacyParametric
            && message is Incoming.Legacy { Value: var f1 } && f1.CommandByte == (byte)Command.AdvancedEq)
        {
            var state = EQState.TryParse(f1.Payload);
            return state is null ? null : new EQSnapshot(state.ActiveCategory, state.Bands.Select(b => b.Gain).ToArray());
        }

        if (Model.Family == ProtocolFamily.LegacyLevels
            && message is Incoming.Legacy { Value: var f2 } && f2.CommandByte == (byte)Command.AdvancedEq)
        {
            // Assumed to mirror the write: active | C1 | scope | count | (index | level) * count.
            byte[] p = f2.Payload;
            if (p.Length < 4 || p.Length < 4 + p[3] * 2) return null;
            var levels = new float[p[3]];
            for (int i = 0; i < p[3]; i++) levels[i] = (sbyte)p[4 + i * 2 + 1];
            return new EQSnapshot(p[0], levels.Length == Model.CustomBands.Count ? levels : null);
        }

        if (Model.Family == ProtocolFamily.LegacySimple
            && message is Incoming.Legacy { Value: var f3 } && f3.CommandByte == 0x6D)
        {
            // scope | active | (category | count | (type | value) * count) …
            byte[] p = f3.Payload;
            if (p.Length < 2) return null;
            int o = 2;
            float[]? gains = null;
            while (o + 2 <= p.Length)
            {
                byte category = p[o];
                int count = p[o + 1];
                o += 2;
                if (o + count * 2 > p.Length) break;
                if (category == Model.CustomCategory)
                {
                    var g = new float[] { 0, 0, 0 };
                    for (int i = 0; i < count; i++)
                    {
                        byte idx = p[o + i * 2];
                        if (idx is >= 1 and <= 3) g[idx - 1] = (sbyte)p[o + i * 2 + 1];
                    }
                    gains = g;
                }
                o += count * 2;
            }
            return new EQSnapshot(p[1], gains);
        }

        if ((Model.Family == ProtocolFamily.Protocol4Parametric || Model.Family == ProtocolFamily.Protocol4Quantized)
            && message is Incoming.P4 { Value: var m })
        {
            if (m.Features.TryGetValue(P4EQ.Parametric, out var v) && v.Length >= 19)
            {
                byte category = P4EQ.Unmap(v[0]);
                int count = v[2];
                var bands = new List<float>();
                for (int i = 0; i < count; i++)
                {
                    int o = 19 + i * 13;
                    if (o + 13 <= v.Length) bands.Add(EQState.ReadFloat(v, o + 5));
                }
                bool isCustom = category == Model.CustomCategory;
                return new EQSnapshot(isCustom ? Model.CustomCategory : category, isCustom ? bands.ToArray() : null);
            }
            if (m.Features.TryGetValue(P4EQ.Quantized, out var vq) && vq.Length >= 8)
            {
                return new EQSnapshot(Model.CustomCategory, P4EQ.GainsFromQuantized(vq[1..8]));
            }
            return null;
        }

        return null;
    }

    // MARK: Helpers

    private static EQBand[] ParametricBands(float[] gains) =>
        EQLayouts.ParametricShape.Zip(gains, (band, gain) => new EQBand(band.Type, band.Frequency, gain, band.Q)).ToArray();

    private static Frame LevelsFrame(byte active, float[] gains)
    {
        var p = new List<byte> { active, 0xC1, 0x06, (byte)gains.Length };
        for (int i = 0; i < gains.Length; i++)
        {
            p.Add((byte)(i + 1));
            p.Add(ToSignedByte(gains[i]));
        }
        return new Frame(Command.SetAdvancedEq, p.ToArray());
    }

    private static byte ToSignedByte(float g)
    {
        int rounded = (int)MathF.Round(g, MidpointRounding.AwayFromZero);
        sbyte clamped = (sbyte)Math.Clamp(rounded, -128, 127);
        return unchecked((byte)clamped);
    }
}

/// <summary>Protocol 4 EQ features (from the JBL app's `PortableControl` / `DeviceFeature`).</summary>
public static class P4EQ
{
    public const ushort Query = 0x0E01;
    public const ushort Parametric = 0x0E02;
    public const ushort Quantized = 0x0E7F;

    /// <summary>Legacy category → Protocol 4 category.</summary>
    public static readonly Dictionary<byte, byte> CategoryMap = new()
    {
        [0x01] = 0x50, [0x03] = 0x02, [0x06] = 0x80, [0x07] = 0x81, [0x08] = 0x82, [0x09] = 0x83, [0x22] = 0x85,
        [0xC1] = 0xC1, [0xC2] = 0xC1,
    };

    public static byte Unmap(byte p4)
    {
        foreach (var kv in CategoryMap)
        {
            if (kv.Value == p4 && kv.Key != 0xC2) return kv.Key;
        }
        return p4;
    }

    /// <summary>`category | enabled=1 | 7 | 0:u32 | 48000:u32 | 0:u32 | 0:u32 | 7 × (type | freq | gain | q)`.</summary>
    public static byte[] ParametricValue(byte category, EQBand[] bands)
    {
        var v = new List<byte> { category, 1, (byte)bands.Length };
        foreach (uint word in new uint[] { 0, 48000, 0, 0 }) v.AddRange(Be32(word));
        foreach (var b in bands)
        {
            v.Add((byte)b.Type);
            v.AddRange(Be32(BitConverter.SingleToUInt32Bits(b.Frequency)));
            v.AddRange(Be32(BitConverter.SingleToUInt32Bits(b.Gain)));
            v.AddRange(Be32(BitConverter.SingleToUInt32Bits(b.Q)));
        }
        return v.ToArray();
    }

    /// <summary>Band 1: +6…0 in 0.5 dB steps, then −0.75…−9 in 0.75 dB steps. Bands 2–7: +6…−6 in 0.5 dB steps.</summary>
    public static readonly float[] FirstBandSteps = Enumerable.Range(0, 13).Select(i => 6 - 0.5f * i)
        .Concat(Enumerable.Range(1, 12).Select(i => -0.75f * i)).ToArray();

    public static readonly float[] OtherBandSteps = Enumerable.Range(0, 25).Select(i => 6 - 0.5f * i).ToArray();

    public static byte[]? QuantizedValue(float[] gains)
    {
        if (gains.Length != 7) return null;
        var v = new List<byte> { 0xC1 };
        for (int i = 0; i < gains.Length; i++)
        {
            var table = i == 0 ? FirstBandSteps : OtherBandSteps;
            int index = Array.FindIndex(table, t => Math.Abs(t - gains[i]) < 0.001f);
            if (index < 0) return null;
            v.Add((byte)index);
        }
        return v.ToArray();
    }

    public static float[] GainsFromQuantized(byte[] indices)
    {
        var result = new float[indices.Length];
        for (int i = 0; i < indices.Length; i++)
        {
            var table = i == 0 ? FirstBandSteps : OtherBandSteps;
            result[i] = indices[i] < table.Length ? table[indices[i]] : 0;
        }
        return result;
    }

    private static byte[] Be32(uint v) =>
        new[] { (byte)(v >> 24 & 0xFF), (byte)(v >> 16 & 0xFF), (byte)(v >> 8 & 0xFF), (byte)(v & 0xFF) };
}
