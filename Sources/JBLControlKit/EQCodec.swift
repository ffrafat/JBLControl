import Foundation

/// What the app shows for a speaker's EQ, independent of protocol family.
public struct EQSnapshot: Equatable, Sendable {
    /// Selected preset category, or the model's custom category.
    public var activeCategory: UInt8
    /// Custom curve, one gain per `SpeakerModel.customBands`. Nil when the reply doesn't carry it.
    public var gains: [Float]?

    public init(activeCategory: UInt8, gains: [Float]?) {
        self.activeCategory = activeCategory
        self.gains = gains
    }
}

/// Builds EQ reads/writes and parses replies for one model's protocol family.
public struct EQCodec: Sendable {
    public let model: SpeakerModel

    public init(model: SpeakerModel) {
        self.model = model
    }

    /// Whether a write is answered with the new state (otherwise the app re-reads).
    public var writeRepliesWithState: Bool { model.family == .legacyParametric }

    // MARK: Requests

    public func readRequests() -> [Data] {
        switch model.family {
        case .legacyParametric, .legacyLevels: [Frame.requestEQ.encoded]
        case .legacySimple: [Frame(0x6C, [0x00]).encoded]
        case .protocol4Parametric, .protocol4Quantized: P4Message.set([(P4EQ.query, [0xFF])]).packets
        case .infoOnly: []
        }
    }

    public func select(_ preset: EQPreset, customGains: [Float]) -> [Data] {
        if preset.category == model.customCategory { return setCustom(customGains) }
        switch model.family {
        case .legacyParametric:
            return [Frame.setEQ(category: preset.category, bands: preset.bands).encoded]
        case .legacyLevels:
            return [levelsFrame(active: preset.category, gains: customGains).encoded]
        case .protocol4Parametric:
            guard let mapped = P4EQ.categoryMap[preset.category], preset.bands.count == 7 else { return [] }
            return P4Message.set([(P4EQ.parametric, P4EQ.parametricValue(category: mapped, bands: preset.bands))]).packets
        case .legacySimple, .protocol4Quantized, .infoOnly:
            return []
        }
    }

    public func setCustom(_ gains: [Float]) -> [Data] {
        switch model.family {
        case .legacyParametric:
            return [Frame.setEQ(category: model.customCategory, bands: parametricBands(gains)).encoded]
        case .legacyLevels:
            return [levelsFrame(active: model.customCategory, gains: gains).encoded]
        case .legacySimple:
            let v = gains.map { UInt8(bitPattern: Int8(clamping: Int($0.rounded()))) }
            guard v.count == 3 else { return [] }
            return [Frame(0x6E, [model.customCategory, 3, 1, v[0], 2, v[1], 3, v[2]]).encoded]
        case .protocol4Parametric:
            return P4Message.set([(P4EQ.parametric, P4EQ.parametricValue(category: 0xC1, bands: parametricBands(gains)))]).packets
        case .protocol4Quantized:
            guard let value = P4EQ.quantizedValue(gains) else { return [] }
            return P4Message.set([(P4EQ.quantized, value)]).packets
        case .infoOnly:
            return []
        }
    }

    // MARK: Replies

    public func parse(_ message: Incoming) -> EQSnapshot? {
        switch (model.family, message) {
        case (.legacyParametric, .legacy(let f)) where f.command == Command.advancedEQ.rawValue:
            return EQState(payload: f.payload).map { EQSnapshot(activeCategory: $0.activeCategory, gains: $0.bands.map(\.gain)) }

        case (.legacyLevels, .legacy(let f)) where f.command == Command.advancedEQ.rawValue:
            // Assumed to mirror the write: active | C1 | scope | count | (index | level) * count.
            let p = f.payload
            guard p.count >= 4, p.count >= 4 + Int(p[3]) * 2 else { return nil }
            let levels = (0..<Int(p[3])).map { Float(Int8(bitPattern: p[4 + $0 * 2 + 1])) }
            return EQSnapshot(activeCategory: p[0], gains: levels.count == model.customBands.count ? levels : nil)

        case (.legacySimple, .legacy(let f)) where f.command == 0x6D:
            // scope | active | (category | count | (type | value) * count) …
            let p = f.payload
            guard p.count >= 2 else { return nil }
            var o = 2, gains: [Float]?
            while o + 2 <= p.count {
                let category = p[o], count = Int(p[o + 1])
                o += 2
                guard o + count * 2 <= p.count else { break }
                if category == model.customCategory {
                    var g: [Float] = [0, 0, 0]
                    for i in 0..<count where (1...3).contains(p[o + i * 2]) {
                        g[Int(p[o + i * 2]) - 1] = Float(Int8(bitPattern: p[o + i * 2 + 1]))
                    }
                    gains = g
                }
                o += count * 2
            }
            return EQSnapshot(activeCategory: p[1], gains: gains)

        case (.protocol4Parametric, .p4(let m)), (.protocol4Quantized, .p4(let m)):
            if let v = m.features[P4EQ.parametric], v.count >= 19 {
                let category = P4EQ.unmap(v[0])
                let bands = (0..<Int(v[2])).compactMap { i -> Float? in
                    let o = 19 + i * 13
                    return o + 13 <= v.count ? EQState.float(v, o + 5) : nil
                }
                let isCustom = category == model.customCategory
                return EQSnapshot(activeCategory: isCustom ? model.customCategory : category, gains: isCustom ? bands : nil)
            }
            if let v = m.features[P4EQ.quantized], v.count >= 8 {
                return EQSnapshot(activeCategory: model.customCategory, gains: P4EQ.gains(fromQuantized: Array(v[1...7])))
            }
            return nil

        default:
            return nil
        }
    }

    // MARK: Helpers

    private func parametricBands(_ gains: [Float]) -> [EQBand] {
        zip(EQLayouts.parametricShape, gains).map { band, gain in
            var b = band
            b.gain = gain
            return b
        }
    }

    private func levelsFrame(active: UInt8, gains: [Float]) -> Frame {
        var p: [UInt8] = [active, 0xC1, 0x06, UInt8(gains.count)]
        for (i, g) in gains.enumerated() {
            p += [UInt8(i + 1), UInt8(bitPattern: Int8(clamping: Int(g.rounded())))]
        }
        return Frame(.setAdvancedEQ, p)
    }
}

/// Protocol 4 EQ features (from the JBL app's `PortableControl` / `DeviceFeature`).
public enum P4EQ {
    public static let query: UInt16 = 0x0E01
    public static let parametric: UInt16 = 0x0E02
    public static let quantized: UInt16 = 0x0E7F

    /// Legacy category → Protocol 4 category.
    public static let categoryMap: [UInt8: UInt8] = [
        0x01: 0x50, 0x03: 0x02, 0x06: 0x80, 0x07: 0x81, 0x08: 0x82, 0x09: 0x83, 0x22: 0x85, 0xC1: 0xC1, 0xC2: 0xC1,
    ]

    public static func unmap(_ p4: UInt8) -> UInt8 {
        categoryMap.first { $0.value == p4 && $0.key != 0xC2 }?.key ?? p4
    }

    /// `category | enabled=1 | 7 | 0:u32 | 48000:u32 | 0:u32 | 0:u32 | 7 × (type | freq | gain | q)`.
    public static func parametricValue(category: UInt8, bands: [EQBand]) -> [UInt8] {
        var v: [UInt8] = [category, 1, UInt8(bands.count)]
        for word: UInt32 in [0, 48000, 0, 0] { v += be32(word) }
        for b in bands {
            v.append(b.type.rawValue)
            v += be32(b.frequency.bitPattern) + be32(b.gain.bitPattern) + be32(b.q.bitPattern)
        }
        return v
    }

    /// Band 1: +6…0 in 0.5 dB steps, then −0.75…−9 in 0.75 dB steps. Bands 2–7: +6…−6 in 0.5 dB steps.
    static let firstBandSteps: [Float] = (0...12).map { 6 - 0.5 * Float($0) } + (1...12).map { -0.75 * Float($0) }
    static let otherBandSteps: [Float] = (0...24).map { 6 - 0.5 * Float($0) }

    public static func quantizedValue(_ gains: [Float]) -> [UInt8]? {
        guard gains.count == 7 else { return nil }
        var v: [UInt8] = [0xC1]
        for (i, g) in gains.enumerated() {
            let table = i == 0 ? firstBandSteps : otherBandSteps
            guard let index = table.firstIndex(where: { abs($0 - g) < 0.001 }) else { return nil }
            v.append(UInt8(index))
        }
        return v
    }

    static func gains(fromQuantized indices: [UInt8]) -> [Float] {
        indices.enumerated().map { i, index in
            let table = i == 0 ? firstBandSteps : otherBandSteps
            return table.indices.contains(Int(index)) ? table[Int(index)] : 0
        }
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
}
