import Foundation

/// How a speaker is spoken to. Derived from the feature flags in the JBL Portable app's model config.
public enum ProtocolFamily: String, Sendable {
    /// `AA 97/98/99`, seven float parametric bands. Flip 7, Charge 6.
    case legacyParametric
    /// `AA 97/98/99`, integer band levels. Xtreme 4, Go 4, Clip 5, Tuner 3.
    case legacyLevels
    /// `AA 6C/6D/6E`, bass / mid / treble. Charge 5, Flip 6, Pulse 5, Xtreme 3, Boombox 2/3.
    case legacySimple
    /// `DD 00` frames, feature `0E02` parametric EQ. Boombox 4, Xtreme 5.
    case protocol4Parametric
    /// `DD 00` frames, feature `0E7F` quantized 7-band EQ. Grip, Go 5, Essential 3 SE.
    case protocol4Quantized
    /// No EQ in JBL's own app; battery and info only.
    case infoOnly

    public var usesProtocol4: Bool { self == .protocol4Parametric || self == .protocol4Quantized }
}

/// How much of a model's protocol has been confirmed on real hardware.
public enum SupportLevel: Int, Sendable, Comparable {
    /// Byte-level read/write confirmed on hardware.
    case verified
    /// Encoding taken from the JBL app; reads are safe, writes are not yet confirmed.
    case beta
    /// Newer frame format or transport that nobody has tested from a Mac yet.
    case experimental
    /// Can't be reached from macOS (Wi-Fi models, classic SPP-only speakers).
    case unsupported

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .verified: "Verified"
        case .beta: "Beta"
        case .experimental: "Experimental"
        case .unsupported: "Unsupported"
        }
    }
}

public enum FormFactor: String, Sendable {
    /// Flip, Charge, Xtreme, Pulse.
    case cylinder
    /// Go, Clip, Grip, Tuner.
    case compact
    case boombox
}

public struct SpeakerColor: Sendable, Equatable {
    public let name: String
    /// Gradient start/end from JBL's config, as 0xRRGGBB.
    public let gradient: (UInt32, UInt32)

    public init(_ name: String, _ start: UInt32, _ end: UInt32) {
        self.name = name
        gradient = (start, end)
    }

    public static func == (a: Self, b: Self) -> Bool { a.name == b.name && a.gradient == b.gradient }

    public static let fallback = SpeakerColor("Black", 0xB1B1B1, 0x434343)
}

public struct EQPreset: Identifiable, Equatable, Sendable {
    public let category: UInt8
    public let name: String
    /// The preset's filters as published by JBL, used to draw its response curve.
    public let bands: [EQBand]
    public var id: UInt8 { category }

    public init(category: UInt8, name: String, bands: [EQBand]) {
        self.category = category
        self.name = name
        self.bands = bands
    }

    public var symbol: String {
        switch category {
        case 0x06: "waveform"
        case 0x08: "bolt.fill"
        case 0x22, 0x07: "leaf.fill"
        case 0x03: "music.mic"
        case 0x09: "flame.fill"
        case 0x01, 0x02: "speaker.wave.3.fill"
        default: "slider.vertical.3"
        }
    }
}

/// One editable slider of a model's custom EQ.
public struct EQBandSpec: Sendable, Equatable {
    public let label: String
    public let frequency: Float
    public let range: ClosedRange<Float>
    public let step: Float
    /// Step below zero when it differs (band 1 of the parametric models uses 0.75 dB).
    public let negativeStep: Float

    public init(_ label: String, frequency: Float, range: ClosedRange<Float>, step: Float, negativeStep: Float? = nil) {
        self.label = label
        self.frequency = frequency
        self.range = range
        self.step = step
        self.negativeStep = negativeStep ?? step
    }

    public func snap(_ value: Float) -> Float {
        let v = min(max(value, range.lowerBound), range.upperBound)
        let s = v < 0 ? negativeStep : step
        return (v / s).rounded() * s
    }
}

public struct SpeakerModel: Sendable, Identifiable {
    public let productID: UInt16
    public let name: String
    public let family: ProtocolFamily
    public let support: SupportLevel
    public let formFactor: FormFactor
    public let presets: [EQPreset]
    public let colors: [UInt8: SpeakerColor]
    public var id: UInt16 { productID }

    public init(productID: UInt16, name: String, family: ProtocolFamily, support: SupportLevel,
                formFactor: FormFactor, presets: [EQPreset], colors: [UInt8: SpeakerColor]) {
        self.productID = productID
        self.name = name
        self.family = family
        self.support = support
        self.formFactor = formFactor
        self.presets = presets
        self.colors = colors
    }

    public func color(_ code: UInt8?) -> SpeakerColor {
        code.flatMap { colors[$0] } ?? colors[0x00] ?? .fallback
    }

    public var shortName: String { name.replacingOccurrences(of: "JBL ", with: "") }

    /// Category byte that selects the custom curve.
    public var customCategory: UInt8 { family == .legacyParametric ? 0xC2 : 0xC1 }

    /// Presets the picker offers: the model's own, then Custom.
    public var pickerPresets: [EQPreset] {
        guard hasEQ else { return [] }
        return presets + [EQPreset(category: customCategory, name: "Custom", bands: [])]
    }

    public var hasEQ: Bool { family != .infoOnly && support != .unsupported }

    /// Writes are allowed without opting in only where they have been confirmed on hardware.
    public var writesNeedOptIn: Bool { support != .verified }

    public var customBands: [EQBandSpec] {
        switch family {
        case .legacyParametric, .protocol4Parametric, .protocol4Quantized:
            return EQLayouts.parametric7
        case .legacyLevels:
            let shape = presets.first?.bands.map(\.frequency) ?? [100, 1000, 2000, 7000, 10000]
            return shape.map { EQBandSpec(EQLayouts.label($0), frequency: $0, range: -6...6, step: 1) }
        case .legacySimple:
            return EQLayouts.simple3
        case .infoOnly:
            return []
        }
    }
}

public enum EQLayouts {
    /// The custom editor of the 7-band models, from the JBL app (`custom_c2_eq.json`).
    public static let parametricShape: [EQBand] = [
        EQBand(.lowShelf, 125, 0, q: 0.707),
        EQBand(.peaking, 250, 0, q: 2),
        EQBand(.peaking, 500, 0, q: 2),
        EQBand(.peaking, 1000, 0, q: 2),
        EQBand(.peaking, 2000, 0, q: 2),
        EQBand(.peaking, 4000, 0, q: 2),
        EQBand(.highShelf, 8000, 0, q: 0.707),
    ]

    public static let parametric7: [EQBandSpec] = parametricShape.enumerated().map { i, band in
        i == 0
            ? EQBandSpec(label(band.frequency), frequency: band.frequency, range: -9...6, step: 0.5, negativeStep: 0.75)
            : EQBandSpec(label(band.frequency), frequency: band.frequency, range: -6...6, step: 0.5)
    }

    public static let simple3: [EQBandSpec] = [
        EQBandSpec("Bass", frequency: 100, range: -6...6, step: 1),
        EQBandSpec("Mid", frequency: 1000, range: -6...6, step: 1),
        EQBandSpec("Treble", frequency: 8000, range: -6...6, step: 1),
    ]

    public static func label(_ f: Float) -> String {
        f >= 1000 ? (f.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(f / 1000))k" : String(format: "%.1fk", f / 1000)) : "\(Int(f))"
    }
}

public enum Catalog {
    public static func model(_ productID: UInt16?) -> SpeakerModel? {
        guard let productID else { return nil }
        return all.first { $0.productID == productID }
    }

    /// Every model in the JBL Portable app's catalog. Generated by scripts/generate-catalog.py.
    public static var all: [SpeakerModel] { GeneratedCatalog.models }
}
