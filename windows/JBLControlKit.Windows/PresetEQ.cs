namespace JBLControlKit.Windows;

// Ported from Sources/JBLControlKit/PresetEQ.swift.
// JBL's DefaultPresetEQPayload: five fixed-point biquad coefficients per preset band.

/// <summary>JBL's preset encoder for the five-band "advanced level" models (Go 4, Clip 5, Tuner 3).</summary>
public static class PresetEQ
{
    private const double Scale = 536_870_912.0;
    private static readonly double Pi = (double)MathF.PI;

    /// <summary>Five coefficients, in JBL's order: b0, b1, b2, -a1, -a2.</summary>
    public static int[] Coefficients(EQBand band, double sampleRate = 48000)
    {
        double frequency = band.Frequency;
        double gain = band.Gain;
        double q = band.Q;
        double tan = 1 / Math.Tan((Pi * frequency) / sampleRate);
        double tan2 = tan * tan;
        double amplitude = Math.Pow(10, gain * 0.05);

        double b0 = 0, b1 = 0, b2 = 0, a0 = 1, a1 = 0, a2 = 0;

        switch (band.Type)
        {
            case FilterType.Peaking:
                if (amplitude < 1) q *= amplitude;
                double peak = (amplitude * tan) / q;
                b0 = 1 + peak + tan2;
                b1 = 2 * (1 - tan2);
                b2 = (1 - peak) + tan2;
                a0 = 1 + (tan / q) + tan2;
                a1 = b1;
                a2 = tan2 + (1 - (tan / q));
                break;

            case FilterType.HighShelf:
            {
                double a = amplitude;
                double inverse = 1;
                if (a <= 1) { inverse = 1 / a; a = 1; }
                double root = Math.Sqrt(a);
                double scaled = a * tan2;
                double numerator0 = 1 + (root * tan / q) + scaled;
                double numerator1 = 2 * (1 - scaled);
                double numerator2 = (1 - (root * tan / q)) + scaled;
                double inverseTan = tan2 * inverse;
                a0 = 1 + (Math.Sqrt(inverse) * tan / q) + inverseTan;
                a1 = 2 * (1 - inverseTan);
                a2 = inverseTan + (1 - (Math.Sqrt(inverse) * tan / q));
                b0 = numerator0;
                b1 = numerator1;
                b2 = numerator2;
                break;
            }

            case FilterType.LowShelf:
            {
                double a = amplitude;
                double inverse = 1;
                if (a <= 1) { inverse = 1 / a; a = 1; }
                double root = Math.Sqrt(a);
                double numerator0 = (root * tan / q) + a + tan2;
                double numerator1 = 2 * (a - tan2);
                double numerator2 = (a - (root * tan / q)) + tan2;
                a0 = inverse + (Math.Sqrt(inverse) * tan / q) + tan2;
                a1 = 2 * (inverse - tan2);
                a2 = (inverse - (Math.Sqrt(inverse) * tan / q)) + tan2;
                b0 = numerator0;
                b1 = numerator1;
                b2 = numerator2;
                break;
            }

            case FilterType.HighPass:
                b0 = tan2;
                b1 = -2 * tan2;
                b2 = tan2;
                a0 = 1 + (tan / q) + tan2;
                a1 = 2 * (1 - tan2);
                a2 = (1 - (tan / q)) + tan2;
                break;

            case FilterType.LowPass:
                b0 = 1;
                b1 = 2;
                b2 = 1;
                a0 = 1 + (tan / q) + tan2;
                a1 = 2 * (1 - tan2);
                a2 = tan2 + (1 - (tan / q));
                break;
        }

        double normal = 1 / a0;
        return new[] { b0, b1, b2, -a1, -a2 }.Select(value => (int)((value * normal * Scale) + 0.5)).ToArray();
    }

    /// <summary>Category then coefficients: the payload an <c>AA 97</c> carries to select a preset.</summary>
    public static byte[] Payload(byte category, IEnumerable<EQBand> bands, double sampleRate = 48000)
    {
        var payload = new List<byte> { category };
        foreach (var band in bands)
        {
            foreach (int value in Coefficients(band, sampleRate))
            {
                uint bits = (uint)value;
                payload.Add((byte)(bits & 0xFF));
                payload.Add((byte)((bits >> 8) & 0xFF));
                payload.Add((byte)((bits >> 16) & 0xFF));
                payload.Add((byte)((bits >> 24) & 0xFF));
            }
        }
        return payload.ToArray();
    }
}
