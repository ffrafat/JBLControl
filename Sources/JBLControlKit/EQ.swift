import Foundation

// MARK: - Parametric EQ (0x97 / 0x98 / 0x99)

public enum FilterType: UInt8, Sendable, Codable {
    case lowShelf = 0, peaking = 1, highShelf = 2, lowPass = 3, highPass = 4
}

public struct EQBand: Equatable, Sendable {
    public var type: FilterType
    public var gain: Float
    public var frequency: Float
    public var q: Float

    public init(_ type: FilterType, _ frequency: Float, _ gain: Float, q: Float) {
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.q = q
    }
}

/// What the speaker reports for `0x98`: the active EQ category plus the stored custom curve.
/// The custom curve is always returned, whichever preset is active.
public struct EQState: Equatable, Sendable {
    public var activeCategory: UInt8
    public var curveCategory: UInt8
    public var sampleRate: UInt32
    public var bands: [EQBand]

    public init(activeCategory: UInt8, curveCategory: UInt8, sampleRate: UInt32 = 48000, bands: [EQBand]) {
        self.activeCategory = activeCategory
        self.curveCategory = curveCategory
        self.sampleRate = sampleRate
        self.bands = bands
    }

    /// Payload: `active | category | count | sampleRate:u32be | (type | gain:f32be | freq:f32be | q:f32be) * count`.
    public init?(payload p: [UInt8]) {
        guard p.count >= 7 else { return nil }
        let count = Int(p[2])
        guard p.count >= 7 + count * 13 else { return nil }
        activeCategory = p[0]
        curveCategory = p[1]
        sampleRate = UInt32(p[3]) << 24 | UInt32(p[4]) << 16 | UInt32(p[5]) << 8 | UInt32(p[6])
        bands = (0..<count).compactMap { i in
            let o = 7 + i * 13
            guard let type = FilterType(rawValue: p[o]) else { return nil }
            return EQBand(type, Self.float(p, o + 5), Self.float(p, o + 1), q: Self.float(p, o + 9))
        }
    }

    static func float(_ p: [UInt8], _ o: Int) -> Float {
        Float(bitPattern: UInt32(p[o]) << 24 | UInt32(p[o + 1]) << 16 | UInt32(p[o + 2]) << 8 | UInt32(p[o + 3]))
    }
}

extension Frame {
    /// Selects `category` and sends its band set. The speaker answers with `0x99`.
    /// Sending a preset category switches presets without touching the stored custom curve;
    /// sending the custom category (`C2`) also overwrites the custom curve.
    public static func setEQ(category: UInt8, bands: [EQBand], sampleRate: UInt32 = 48000) -> Frame {
        var p: [UInt8] = [category, category, UInt8(bands.count)]
        p += bigEndian(sampleRate)
        for band in bands {
            p.append(band.type.rawValue)
            p += bigEndian(band.gain.bitPattern) + bigEndian(band.frequency.bitPattern) + bigEndian(band.q.bitPattern)
        }
        return Frame(.setAdvancedEQ, p)
    }

    private static func bigEndian(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
}

// MARK: - Frequency response (RBJ biquad cookbook), for drawing preset curves

public enum EQResponse {
    /// Combined magnitude in dB of `bands` at frequency `f`.
    public static func gain(at f: Double, bands: [EQBand], sampleRate: Double = 48000) -> Double {
        bands.reduce(0) { $0 + biquadGain(at: f, band: $1, fs: sampleRate) }
    }

    static func biquadGain(at f: Double, band: EQBand, fs: Double) -> Double {
        let f0 = Double(band.frequency), q = Double(band.q), g = Double(band.gain)
        let a = pow(10, g / 40)
        let w0 = 2 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        let (b0, b1, b2, a0, a1, a2): (Double, Double, Double, Double, Double, Double)
        switch band.type {
        case .peaking:
            (b0, b1, b2) = (1 + alpha * a, -2 * c, 1 - alpha * a)
            (a0, a1, a2) = (1 + alpha / a, -2 * c, 1 - alpha / a)
        case .lowShelf:
            let s = 2 * sqrt(a) * alpha
            (b0, b1, b2) = (a * ((a + 1) - (a - 1) * c + s), 2 * a * ((a - 1) - (a + 1) * c), a * ((a + 1) - (a - 1) * c - s))
            (a0, a1, a2) = ((a + 1) + (a - 1) * c + s, -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - s)
        case .highShelf:
            let s = 2 * sqrt(a) * alpha
            (b0, b1, b2) = (a * ((a + 1) + (a - 1) * c + s), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - s))
            (a0, a1, a2) = ((a + 1) - (a - 1) * c + s, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - s)
        case .lowPass:
            (b0, b1, b2) = ((1 - c) / 2, 1 - c, (1 - c) / 2)
            (a0, a1, a2) = (1 + alpha, -2 * c, 1 - alpha)
        case .highPass:
            (b0, b1, b2) = ((1 + c) / 2, -(1 + c), (1 + c) / 2)
            (a0, a1, a2) = (1 + alpha, -2 * c, 1 - alpha)
        }
        let w = 2 * Double.pi * f / fs
        // |H(e^jw)| via real/imag parts of numerator and denominator.
        let nr = b0 + b1 * cos(w) + b2 * cos(2 * w), ni = -(b1 * sin(w) + b2 * sin(2 * w))
        let dr = a0 + a1 * cos(w) + a2 * cos(2 * w), di = -(a1 * sin(w) + a2 * sin(2 * w))
        return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }
}
