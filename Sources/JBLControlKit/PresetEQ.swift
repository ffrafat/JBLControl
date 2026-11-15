import Foundation

/// JBL's preset encoder for the five-band "advanced level" models (Go 4, Clip 5, Tuner 3).
///
/// Selecting a preset is not a level write: JBL's app sends each preset band's
/// biquad coefficients as five fixed-point int32s (DefaultPresetEQPayload in
/// JBL Portable). The speaker replies with an AA 99 whose first byte is the
/// newly active category, which is how the app confirms the switch.
///
/// Ported one-for-one from the decompiled DefaultPresetEQPayload.genFirmwarePayload.
public enum PresetEQ {
    /// 2^29: the Q-format scale JBL's encoder uses for every coefficient.
    static let scale = 536_870_912.0
    /// Java's 3.1415927f, converted to the double the encoder actually multiplies.
    static let pi = Double(Float.pi)

    /// Five coefficients, in JBL's order: b0, b1, b2, -a1, -a2.
    public static func coefficients(for band: EQBand, sampleRate: Double = 48000) -> [Int32] {
        let frequency = Double(band.frequency)
        let gain = Double(band.gain)
        var q = Double(band.q)
        let tan = 1 / tan((pi * frequency) / sampleRate)
        let tan2 = tan * tan
        let amplitude = pow(10, gain * 0.05)

        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0

        switch band.type {
        case .peaking:
            if amplitude < 1 { q *= amplitude }
            let peak = (amplitude * tan) / q
            let denominator = 1 + (tan / q) + tan2
            b0 = 1 + peak + tan2
            b1 = 2 * (1 - tan2)
            b2 = (1 - peak) + tan2
            a0 = denominator
            a1 = b1
            a2 = tan2 + (1 - (tan / q))

        case .highShelf:
            var a = amplitude
            var inverse = 1.0
            if a <= 1 { inverse = 1 / a; a = 1 }
            let root = sqrt(a)
            let scaled = a * tan2
            let numerator0 = 1 + (root * tan / q) + scaled
            let numerator1 = 2 * (1 - scaled)
            let numerator2 = (1 - (root * tan / q)) + scaled
            let inverseTan = tan2 * inverse
            a0 = 1 + (sqrt(inverse) * tan / q) + inverseTan
            a1 = 2 * (1 - inverseTan)
            a2 = inverseTan + (1 - (sqrt(inverse) * tan / q))
            b0 = numerator0
            b1 = numerator1
            b2 = numerator2

        case .lowShelf:
            var a = amplitude
            var inverse = 1.0
            if a <= 1 { inverse = 1 / a; a = 1 }
            let root = sqrt(a)
            let numerator0 = (root * tan / q) + a + tan2
            let numerator1 = 2 * (a - tan2)
            let numerator2 = (a - (root * tan / q)) + tan2
            a0 = inverse + (sqrt(inverse) * tan / q) + tan2
            a1 = 2 * (inverse - tan2)
            a2 = (inverse - (sqrt(inverse) * tan / q)) + tan2
            b0 = numerator0
            b1 = numerator1
            b2 = numerator2

        case .highPass:
            b0 = tan2
            b1 = -2 * tan2
            b2 = tan2
            a0 = 1 + (tan / q) + tan2
            a1 = 2 * (1 - tan2)
            a2 = (1 - (tan / q)) + tan2

        case .lowPass:
            b0 = 1
            b1 = 2
            b2 = 1
            a0 = 1 + (tan / q) + tan2
            a1 = 2 * (1 - tan2)
            a2 = tan2 + (1 - (tan / q))
        }

        let normal = 1 / a0
        return [b0, b1, b2, -a1, -a2].map { value in
            Int32((value * normal * scale) + 0.5)
        }
    }

    /// Category then coefficients: the payload an AA 97 carries to select a preset.
    public static func payload(category: UInt8, bands: [EQBand], sampleRate: Double = 48000) -> [UInt8] {
        var payload: [UInt8] = [category]
        for band in bands {
            for value in coefficients(for: band, sampleRate: sampleRate) {
                let bits = UInt32(bitPattern: value)
                payload += [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF),
                            UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
            }
        }
        return payload
    }
}
