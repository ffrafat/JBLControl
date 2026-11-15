using System.Globalization;

namespace JBLControlKit.Windows;

// Ported from Sources/JBLControlKit/Models.swift.

/// <summary>How a speaker is spoken to. Derived from the feature flags in the JBL Portable app's model config.</summary>
public enum ProtocolFamily
{
    /// <summary>`AA 97/98/99`, seven float parametric bands. Flip 7, Charge 6.</summary>
    LegacyParametric,

    /// <summary>`AA 97/98/99`, integer band levels. Xtreme 4, Go 4, Clip 5, Tuner 3.</summary>
    LegacyLevels,

    /// <summary>`AA 6C/6D/6E`, bass / mid / treble. Charge 5, Flip 6, Pulse 5, Xtreme 3, Boombox 2/3.</summary>
    LegacySimple,

    /// <summary>`DD 00` frames, feature `0E02` parametric EQ. Boombox 4, Xtreme 5.</summary>
    Protocol4Parametric,

    /// <summary>`DD 00` frames, feature `0E7F` quantized 7-band EQ. Grip, Go 5, Essential 3 SE.</summary>
    Protocol4Quantized,

    /// <summary>No EQ in JBL's own app; battery and info only.</summary>
    InfoOnly,
}

public static class ProtocolFamilyExtensions
{
    public static bool UsesProtocol4(this ProtocolFamily family) =>
        family is ProtocolFamily.Protocol4Parametric or ProtocolFamily.Protocol4Quantized;
}

/// <summary>How much of a model's protocol has been confirmed on real hardware.</summary>
public enum SupportLevel
{
    /// <summary>Byte-level read/write confirmed on hardware.</summary>
    Verified,

    /// <summary>Encoding taken from the JBL app; reads are safe, writes are not yet confirmed.</summary>
    Beta,

    /// <summary>Newer frame format or transport that nobody has tested from a Mac yet.</summary>
    Experimental,

    /// <summary>Can't be reached from macOS/Windows (Wi-Fi models, classic SPP-only speakers).</summary>
    Unsupported,
}

public static class SupportLevelExtensions
{
    public static string Label(this SupportLevel level) => level switch
    {
        SupportLevel.Verified => "Verified",
        SupportLevel.Beta => "Beta",
        SupportLevel.Experimental => "Experimental",
        SupportLevel.Unsupported => "Unsupported",
        _ => throw new ArgumentOutOfRangeException(nameof(level)),
    };
}

public enum FormFactor
{
    /// <summary>Flip, Charge, Xtreme, Pulse.</summary>
    Cylinder,

    /// <summary>Go, Clip, Grip, Tuner.</summary>
    Compact,

    Boombox,
}

public sealed class SpeakerColor : IEquatable<SpeakerColor>
{
    public string Name { get; }

    /// <summary>Gradient start/end from JBL's config, as 0xRRGGBB.</summary>
    public uint GradientStart { get; }

    public uint GradientEnd { get; }

    public SpeakerColor(string name, uint gradientStart, uint gradientEnd)
    {
        Name = name;
        GradientStart = gradientStart;
        GradientEnd = gradientEnd;
    }

    public static readonly SpeakerColor Fallback = new("Black", 0xB1B1B1, 0x434343);

    public bool Equals(SpeakerColor? other) =>
        other is not null && Name == other.Name && GradientStart == other.GradientStart && GradientEnd == other.GradientEnd;

    public override bool Equals(object? obj) => obj is SpeakerColor c && Equals(c);
    public override int GetHashCode() => HashCode.Combine(Name, GradientStart, GradientEnd);
}

public sealed class EQPreset : IEquatable<EQPreset>
{
    public byte Category { get; }
    public string Name { get; }

    /// <summary>The preset's filters as published by JBL, used to draw its response curve.</summary>
    public EQBand[] Bands { get; }

    public byte Id => Category;

    public EQPreset(byte category, string name, EQBand[] bands)
    {
        Category = category;
        Name = name;
        Bands = bands;
    }

    /// <summary>SF-Symbol-style identifier; the Windows UI layer maps these to Segoe Fluent glyphs.</summary>
    public string Symbol => Category switch
    {
        0x06 => "waveform",
        0x08 => "bolt.fill",
        0x22 or 0x07 => "leaf.fill",
        0x03 => "music.mic",
        0x09 => "flame.fill",
        0x01 or 0x02 => "speaker.wave.3.fill",
        _ => "slider.vertical.3",
    };

    public bool Equals(EQPreset? other) =>
        other is not null && Category == other.Category && Name == other.Name && Bands.AsSpan().SequenceEqual(other.Bands);

    public override bool Equals(object? obj) => obj is EQPreset p && Equals(p);
    public override int GetHashCode() => HashCode.Combine(Category, Name);
}

/// <summary>One editable slider of a model's custom EQ.</summary>
public sealed class EQBandSpec
{
    public string Label { get; }
    public float Frequency { get; }
    public float RangeLow { get; }
    public float RangeHigh { get; }
    public float Step { get; }

    /// <summary>Step below zero when it differs (band 1 of the parametric models uses 0.75 dB).</summary>
    public float NegativeStep { get; }

    public EQBandSpec(string label, float frequency, float rangeLow, float rangeHigh, float step, float? negativeStep = null)
    {
        Label = label;
        Frequency = frequency;
        RangeLow = rangeLow;
        RangeHigh = rangeHigh;
        Step = step;
        NegativeStep = negativeStep ?? step;
    }

    public float Snap(float value)
    {
        float v = Math.Min(Math.Max(value, RangeLow), RangeHigh);
        float s = v < 0 ? NegativeStep : Step;
        return MathF.Round(v / s, MidpointRounding.AwayFromZero) * s;
    }
}

/// <summary>The multi-speaker capabilities the JBL app's model table declares.</summary>
public sealed class ModelFeatures
{
    /// <summary><c>AURACAST_SUPPORT</c>: the unit can join or start an Auracast broadcast.</summary>
    public bool Auracast { get; }

    /// <summary><c>NON_PARTY_BOOST_SUPPORT</c> / <c>PARTYBOOST_BUTTON_SUPPORT</c>: the older PartyBoost link.</summary>
    public bool PartyBoost { get; }

    /// <summary><c>LONG_LASTING_STEREO</c>: the pair survives a power cycle.</summary>
    public bool LongLastingStereo { get; }

    /// <summary><c>AIR_TOUCH_STEREO</c>: the Duo picks its own halves when bumped together.</summary>
    public bool AirTouchStereo { get; }

    /// <summary>The models JBL's app drives with its newer stereo flow.</summary>
    public bool NewStereoFlow { get; }

    public ModelFeatures(bool auracast = false, bool partyBoost = false, bool longLastingStereo = false,
        bool airTouchStereo = false, bool newStereoFlow = false)
    {
        Auracast = auracast;
        PartyBoost = partyBoost;
        LongLastingStereo = longLastingStereo;
        AirTouchStereo = airTouchStereo;
        NewStereoFlow = newStereoFlow;
    }
}

public sealed class SpeakerModel
{
    public ushort ProductId { get; }
    public string Name { get; }
    public ProtocolFamily Family { get; }
    public SupportLevel Support { get; }
    public FormFactor FormFactor { get; }
    public EQPreset[] Presets { get; }
    public Dictionary<byte, SpeakerColor> Colors { get; }
    public ModelFeatures Features { get; }
    public ushort Id => ProductId;

    public SpeakerModel(ushort productId, string name, ProtocolFamily family, SupportLevel support,
        FormFactor formFactor, EQPreset[] presets, Dictionary<byte, SpeakerColor> colors, ModelFeatures? features = null)
    {
        ProductId = productId;
        Name = name;
        Family = family;
        Support = support;
        FormFactor = formFactor;
        Presets = presets;
        Colors = colors;
        Features = features ?? new ModelFeatures();
    }

    public SpeakerColor Color(byte? code)
    {
        if (code.HasValue && Colors.TryGetValue(code.Value, out var c)) return c;
        if (Colors.TryGetValue(0x00, out var fallback)) return fallback;
        return SpeakerColor.Fallback;
    }

    public string ShortName => Name.Replace("JBL ", "");

    /// <summary>Category byte that selects the custom curve.</summary>
    public byte CustomCategory => Family == ProtocolFamily.LegacyParametric ? (byte)0xC2 : (byte)0xC1;

    /// <summary>Presets the picker offers: the model's own, then Custom.</summary>
    ///
    /// <para>A 3-band (simple EQ) model has no preset table in the JBL app, but its
    /// firmware still carries JBL Signature as category <c>01</c>; selecting it is
    /// <c>AA 6E 02 01 00</c>, the same frame the app sends.</para>
    public List<EQPreset> PickerPresets
    {
        get
        {
            if (!HasEq) return new List<EQPreset>();
            var custom = new EQPreset(CustomCategory, "Custom", Array.Empty<EQBand>());
            if (!SupportsPresets) return new List<EQPreset> { custom };
            var list = new List<EQPreset>(Presets);
            if (Family == ProtocolFamily.LegacySimple && !list.Exists(p => p.Category == 0x01))
            {
                list.Insert(0, new EQPreset(0x01, "Signature", Array.Empty<EQBand>()));
            }
            list.Add(custom);
            return list;
        }
    }

    public bool HasEq => Family != ProtocolFamily.InfoOnly && Support != SupportLevel.Unsupported;

    /// <summary>
    /// Whether JBL's preset payload for this model is implemented.
    /// Xtreme 4 uses a different (AKM) coefficient encoder that isn't ported yet.
    /// </summary>
    public bool SupportsPresets => !(Family == ProtocolFamily.LegacyLevels && ProductId == 0x20DC);

    /// <summary>The unit can join or start an Auracast broadcast.</summary>
    public bool HasAuracast => Features.Auracast;

    /// <summary>Left/right can be chosen over the control channel (not on AirTouch models).</summary>
    public bool HasStereoChannel => Features.Auracast && !Features.AirTouchStereo;

    /// <summary>The two halves are chosen by AirTouch, not by an <c>AA 15</c> write.</summary>
    public bool StereoIsAutomatic => Features.AirTouchStereo;

    /// <summary>Writes are allowed without opting in only where they have been confirmed on hardware.</summary>
    public bool WritesNeedOptIn => Support != SupportLevel.Verified;

    public List<EQBandSpec> CustomBands
    {
        get
        {
            switch (Family)
            {
                case ProtocolFamily.LegacyParametric:
                case ProtocolFamily.Protocol4Parametric:
                case ProtocolFamily.Protocol4Quantized:
                    return EQLayouts.Parametric7;
                case ProtocolFamily.LegacyLevels:
                    var shape = Presets.Length > 0
                        ? Presets[0].Bands.Select(b => b.Frequency).ToArray()
                        : new float[] { 100, 1000, 2000, 7000, 10000 };
                    return shape.Select(f => new EQBandSpec(EQLayouts.Label(f), f, -6, 6, 1)).ToList();
                case ProtocolFamily.LegacySimple:
                    return EQLayouts.Simple3;
                default:
                    return new List<EQBandSpec>();
            }
        }
    }
}

public static class EQLayouts
{
    /// <summary>The custom editor of the 7-band models, from the JBL app (`custom_c2_eq.json`).</summary>
    public static readonly EQBand[] ParametricShape =
    {
        new(FilterType.LowShelf, 125, 0, 0.707f),
        new(FilterType.Peaking, 250, 0, 2f),
        new(FilterType.Peaking, 500, 0, 2f),
        new(FilterType.Peaking, 1000, 0, 2f),
        new(FilterType.Peaking, 2000, 0, 2f),
        new(FilterType.Peaking, 4000, 0, 2f),
        new(FilterType.HighShelf, 8000, 0, 0.707f),
    };

    public static readonly List<EQBandSpec> Parametric7 = ParametricShape.Select((band, i) => i == 0
        ? new EQBandSpec(Label(band.Frequency), band.Frequency, -9, 6, 0.5f, 0.75f)
        : new EQBandSpec(Label(band.Frequency), band.Frequency, -6, 6, 0.5f)).ToList();

    public static readonly List<EQBandSpec> Simple3 = new()
    {
        new("Bass", 100, -6, 6, 1),
        new("Mid", 1000, -6, 6, 1),
        new("Treble", 8000, -6, 6, 1),
    };

    public static string Label(float f) => f >= 1000
        ? (f % 1000 == 0 ? $"{(int)(f / 1000)}k" : (f / 1000).ToString("0.0", CultureInfo.InvariantCulture) + "k")
        : ((int)f).ToString(CultureInfo.InvariantCulture);
}

public static class Catalog
{
    public static SpeakerModel? Model(ushort? productId)
    {
        if (productId is null) return null;
        return All.FirstOrDefault(m => m.ProductId == productId);
    }

    /// <summary>Every model in the JBL Portable app's catalog. Generated by scripts/generate-catalog.py.</summary>
    public static IReadOnlyList<SpeakerModel> All => GeneratedCatalog.Models;
}

/// <summary>
/// JBL speakers rotate their BLE address and keep advertising while connected, so one speaker
/// shows up under several peripheral identifiers. Advertised names are also truncated in the
/// advertisement ("FFR JBL Fli") but complete in the scan response ("FFR JBL Flip 7").
/// Two sightings are the same speaker when the model matches and one name is a prefix of the other.
/// (Two identically named speakers of the same model can't be told apart this way; the newest wins.)
/// </summary>
public static class SpeakerIdentity
{
    public static bool Matches(string nameA, ushort? productIdA, string nameB, ushort? productIdB)
    {
        if (productIdA.HasValue && productIdB.HasValue && productIdA != productIdB) return false;
        string x = nameA.Trim();
        string y = nameB.Trim();
        if (x.Length < 3 || y.Length < 3) return false;
        return x.StartsWith(y, StringComparison.Ordinal) || y.StartsWith(x, StringComparison.Ordinal);
    }
}
