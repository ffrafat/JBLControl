import Foundation

/// "Protocol 4", the frame format of newer JBL speakers (Go 5, Grip, Xtreme 5, Boombox 4).
/// From the JBL Portable app via openjbl; not yet confirmed on hardware.
///
/// Header, little-endian: `identifier:u16 (DD00, DD01 forwarded) | command:u16 | count:u8 | index:u8 | length:u16`.
/// Payload of GET/SET: a list of `feature:u16le | length:u16le | value`.
public struct P4Message: Equatable, Sendable {
    public static let get: UInt16 = 0x0001
    public static let set: UInt16 = 0x0002
    public static let notification: UInt16 = 0x0003
    static let maxPacketPayload = 490

    public var command: UInt16
    public var payload: [UInt8]

    public init(command: UInt16, payload: [UInt8]) {
        self.command = command
        self.payload = payload
    }

    /// One or more packets, split at 490 payload bytes.
    public var packets: [Data] {
        let chunks = stride(from: 0, to: max(payload.count, 1), by: Self.maxPacketPayload).map {
            Array(payload[$0..<min($0 + Self.maxPacketPayload, payload.count)])
        }
        return chunks.enumerated().map { index, chunk in
            var p: [UInt8] = [0x00, 0xDD]
            p += le16(command) + [UInt8(chunks.count), UInt8(index)] + le16(UInt16(chunk.count))
            return Data(p + chunk)
        }
    }

    public static func set(_ features: [(UInt16, [UInt8])]) -> P4Message {
        P4Message(command: set, payload: features.flatMap { le16($0.0) + le16(UInt16($0.1.count)) + $0.1 })
    }

    public static func get(_ features: [UInt16]) -> P4Message {
        P4Message(command: get, payload: features.flatMap(le16))
    }

    /// `feature → value` pairs of a GET reply or notification.
    public var features: [UInt16: [UInt8]] {
        var out: [UInt16: [UInt8]] = [:]
        var o = 0
        let p = payload
        while o + 4 <= p.count {
            let feature = UInt16(p[o]) | UInt16(p[o + 1]) << 8
            let length = Int(p[o + 2]) | Int(p[o + 3]) << 8
            guard o + 4 + length <= p.count else { break }
            out[feature] = Array(p[(o + 4)..<(o + 4 + length)])
            o += 4 + length
        }
        return out
    }
}

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

/// Anything the speaker sends on the notify characteristic.
public enum Incoming: Equatable, Sendable {
    case legacy(Frame)
    case p4(P4Message)
}

/// Splits notifications into legacy `AA` frames and (reassembled) Protocol 4 messages.
public struct MessageDecoder: Sendable {
    private var legacy = FrameDecoder()
    private var p4Parts: [UInt8: [UInt8]] = [:]
    private var p4Command: UInt16 = 0

    public init() {}

    public mutating func feed(_ data: Data) -> [Incoming] {
        let b = [UInt8](data)
        if b.count >= 8, b[1] == 0xDD, b[0] <= 0x01 {
            let command = UInt16(b[2]) | UInt16(b[3]) << 8
            let count = b[4], index = b[5]
            let length = Int(b[6]) | Int(b[7]) << 8
            let chunk = Array(b.dropFirst(8).prefix(length))
            if index == 0 { p4Parts = [:]; p4Command = command }
            p4Parts[index] = chunk
            guard p4Parts.count == Int(max(count, 1)) else { return [] }
            let payload = (0..<max(count, 1)).flatMap { p4Parts[$0] ?? [] }
            p4Parts = [:]
            return [.p4(P4Message(command: p4Command, payload: payload))]
        }
        return legacy.feed(data).map(Incoming.legacy)
    }
}
