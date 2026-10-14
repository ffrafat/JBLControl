namespace JBLControlKit.Windows;

// MARK: - Parametric EQ (0x97 / 0x98 / 0x99)
// Ported from Sources/JBLControlKit/EQ.swift.

public enum FilterType : byte
{
    LowShelf = 0,
    Peaking = 1,
    HighShelf = 2,
    LowPass = 3,
    HighPass = 4,
}

public readonly struct EQBand : IEquatable<EQBand>
{
    public FilterType Type { get; }
    public float Frequency { get; }
    public float Gain { get; }
    public float Q { get; }

    public EQBand(FilterType type, float frequency, float gain, float q)
    {
        Type = type;
        Frequency = frequency;
        Gain = gain;
        Q = q;
    }

    public bool Equals(EQBand other) =>
        Type == other.Type && Frequency.Equals(other.Frequency) && Gain.Equals(other.Gain) && Q.Equals(other.Q);

    public override bool Equals(object? obj) => obj is EQBand b && Equals(b);
    public override int GetHashCode() => HashCode.Combine(Type, Frequency, Gain, Q);
    public static bool operator ==(EQBand a, EQBand b) => a.Equals(b);
    public static bool operator !=(EQBand a, EQBand b) => !a.Equals(b);
}

/// <summary>
/// What the speaker reports for `0x98`: the active EQ category plus the stored custom curve.
/// The custom curve is always returned, whichever preset is active.
/// </summary>
public sealed class EQState : IEquatable<EQState>
{
    public byte ActiveCategory { get; }
    public byte CurveCategory { get; }
    public uint SampleRate { get; }
    public EQBand[] Bands { get; }

    public EQState(byte activeCategory, byte curveCategory, EQBand[] bands, uint sampleRate = 48000)
    {
        ActiveCategory = activeCategory;
        CurveCategory = curveCategory;
        SampleRate = sampleRate;
        Bands = bands;
    }

    /// <summary>Payload: `active | category | count | sampleRate:u32be | (type | gain:f32be | freq:f32be | q:f32be) * count`.</summary>
    public static EQState? TryParse(byte[] p)
    {
        if (p.Length < 7) return null;
        int count = p[2];
        if (p.Length < 7 + count * 13) return null;
        byte activeCategory = p[0];
        byte curveCategory = p[1];
        uint sampleRate = (uint)(p[3] << 24 | p[4] << 16 | p[5] << 8 | p[6]);
        var bands = new List<EQBand>();
        for (int i = 0; i < count; i++)
        {
            int o = 7 + i * 13;
            if (!Enum.IsDefined(typeof(FilterType), p[o])) continue;
            var type = (FilterType)p[o];
            bands.Add(new EQBand(type, ReadFloat(p, o + 5), ReadFloat(p, o + 1), ReadFloat(p, o + 9)));
        }
        return new EQState(activeCategory, curveCategory, bands.ToArray(), sampleRate);
    }

    public static float ReadFloat(byte[] p, int o)
    {
        uint bits = (uint)(p[o] << 24 | p[o + 1] << 16 | p[o + 2] << 8 | p[o + 3]);
        return BitConverter.UInt32BitsToSingle(bits);
    }

    public bool Equals(EQState? other) =>
        other is not null && ActiveCategory == other.ActiveCategory && CurveCategory == other.CurveCategory
        && SampleRate == other.SampleRate && Bands.AsSpan().SequenceEqual(other.Bands);

    public override bool Equals(object? obj) => obj is EQState s && Equals(s);
    public override int GetHashCode() => HashCode.Combine(ActiveCategory, CurveCategory, SampleRate);
}

/// <summary>Adds the EQ-write factory to <see cref="Frame"/> (mirrors Swift's <c>extension Frame</c> in EQ.swift).</summary>
public readonly partial struct Frame
{
    /// <summary>
    /// Selects <paramref name="category"/> and sends its band set. The speaker answers with `0x99`.
    /// Sending a preset category switches presets without touching the stored custom curve;
    /// sending the custom category (`C2`) also overwrites the custom curve.
    /// </summary>
    public static Frame SetEq(byte category, EQBand[] bands, uint sampleRate = 48000)
    {
        var p = new List<byte> { category, category, (byte)bands.Length };
        p.AddRange(BigEndian(sampleRate));
        foreach (var band in bands)
        {
            p.Add((byte)band.Type);
            p.AddRange(BigEndian(BitConverter.SingleToUInt32Bits(band.Gain)));
            p.AddRange(BigEndian(BitConverter.SingleToUInt32Bits(band.Frequency)));
            p.AddRange(BigEndian(BitConverter.SingleToUInt32Bits(band.Q)));
        }
        return new Frame(Command.SetAdvancedEq, p.ToArray());
    }

    private static byte[] BigEndian(uint v) =>
        new[] { (byte)(v >> 24 & 0xFF), (byte)(v >> 16 & 0xFF), (byte)(v >> 8 & 0xFF), (byte)(v & 0xFF) };
}

// MARK: - Frequency response (RBJ biquad cookbook), for drawing preset curves

public static class EQResponse
{
    /// <summary>Combined magnitude in dB of <paramref name="bands"/> at frequency <paramref name="f"/>.</summary>
    public static double Gain(double f, IEnumerable<EQBand> bands, double sampleRate = 48000) =>
        bands.Sum(b => BiquadGain(f, b, sampleRate));

    public static double BiquadGain(double f, EQBand band, double fs)
    {
        double f0 = band.Frequency, q = band.Q, g = band.Gain;
        double a = Math.Pow(10, g / 40);
        double w0 = 2 * Math.PI * f0 / fs;
        double alpha = Math.Sin(w0) / (2 * q);
        double c = Math.Cos(w0);
        double b0, b1, b2, a0, a1, a2;
        switch (band.Type)
        {
            case FilterType.Peaking:
                b0 = 1 + alpha * a;
                b1 = -2 * c;
                b2 = 1 - alpha * a;
                a0 = 1 + alpha / a;
                a1 = -2 * c;
                a2 = 1 - alpha / a;
                break;
            case FilterType.LowShelf:
            {
                double s = 2 * Math.Sqrt(a) * alpha;
                b0 = a * ((a + 1) - (a - 1) * c + s);
                b1 = 2 * a * ((a - 1) - (a + 1) * c);
                b2 = a * ((a + 1) - (a - 1) * c - s);
                a0 = (a + 1) + (a - 1) * c + s;
                a1 = -2 * ((a - 1) + (a + 1) * c);
                a2 = (a + 1) + (a - 1) * c - s;
                break;
            }
            case FilterType.HighShelf:
            {
                double s = 2 * Math.Sqrt(a) * alpha;
                b0 = a * ((a + 1) + (a - 1) * c + s);
                b1 = -2 * a * ((a - 1) + (a + 1) * c);
                b2 = a * ((a + 1) + (a - 1) * c - s);
                a0 = (a + 1) - (a - 1) * c + s;
                a1 = 2 * ((a - 1) - (a + 1) * c);
                a2 = (a + 1) - (a - 1) * c - s;
                break;
            }
            case FilterType.LowPass:
                b0 = (1 - c) / 2;
                b1 = 1 - c;
                b2 = (1 - c) / 2;
                a0 = 1 + alpha;
                a1 = -2 * c;
                a2 = 1 - alpha;
                break;
            case FilterType.HighPass:
                b0 = (1 + c) / 2;
                b1 = -(1 + c);
                b2 = (1 + c) / 2;
                a0 = 1 + alpha;
                a1 = -2 * c;
                a2 = 1 - alpha;
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(band));
        }
        double w = 2 * Math.PI * f / fs;
        // |H(e^jw)| via real/imag parts of numerator and denominator.
        double nr = b0 + b1 * Math.Cos(w) + b2 * Math.Cos(2 * w), ni = -(b1 * Math.Sin(w) + b2 * Math.Sin(2 * w));
        double dr = a0 + a1 * Math.Cos(w) + a2 * Math.Cos(2 * w), di = -(a1 * Math.Sin(w) + a2 * Math.Sin(2 * w));
        return 10 * Math.Log10((nr * nr + ni * ni) / (dr * dr + di * di));
    }
}
