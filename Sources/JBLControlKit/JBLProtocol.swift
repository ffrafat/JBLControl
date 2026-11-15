import Foundation

/// JBL Portable BLE control protocol ("legacy" AA-framed generation), as used by the Flip 7.
/// See docs/PROTOCOL-FLIP7.md for the captures this is built from.
public enum JBL {
    public static let serviceUUID = "65786365-6C70-6F69-6E74-2E636F6D0000"
    /// Speaker → app notifications.
    public static let notifyUUID = "65786365-6C70-6F69-6E74-2E636F6D0001"
    /// App → speaker commands.
    public static let writeUUID = "65786365-6C70-6F69-6E74-2E636F6D0002"
    /// Bluetooth SIG company identifier used in JBL manufacturer advertising data.
    public static let harmanCompanyID: UInt16 = 0x0057
    /// Advertised service-data keys that identify JBL Portable speakers.
    public static let advertisedServiceIDs: Set<String> = ["FDDF", "FC69", "DFFD"]

    /// Product ID from manufacturer data: `57 00 | PID little-endian | …`.
    public static func productID(fromManufacturerData data: Data) -> UInt16? {
        let b = [UInt8](data)
        guard b.count >= 4, UInt16(b[0]) | UInt16(b[1]) << 8 == harmanCompanyID else { return nil }
        return UInt16(b[2]) | UInt16(b[3]) << 8
    }
}

public enum Command: UInt8, Sendable {
    case devAck = 0x00
    case requestInfo = 0x11
    case info = 0x12
    /// Ask for one info token (AA 13 02 00 <token>); with a length and value, sets it.
    case requestToken = 0x13
    case requestVersion = 0x41
    case version = 0x42
    case notifyEQChange = 0x64
    case setAdvancedEQ = 0x97
    case requestAdvancedEQ = 0x98
    case advancedEQ = 0x99
    case unsupported = 0xEE
}

public struct Frame: Equatable, Sendable {
    public static let identifier: UInt8 = 0xAA
    /// Commands whose length field is two bytes big-endian.
    static let longLengthCommands: Set<UInt8> = [0x92, 0x96, 0x97, 0x98, 0x99]

    public var command: UInt8
    public var payload: [UInt8]

    public init(_ command: UInt8, _ payload: [UInt8] = []) {
        self.command = command
        self.payload = payload
    }

    public init(_ command: Command, _ payload: [UInt8] = []) {
        self.init(command.rawValue, payload)
    }

    public var isLong: Bool { Self.longLengthCommands.contains(command) }

    public var encoded: Data {
        var out: [UInt8] = [Self.identifier, command]
        if isLong {
            out += [UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF)]
        } else {
            out.append(UInt8(payload.count))
        }
        return Data(out + payload)
    }

    public static let requestInfo = Frame(.requestInfo)
    public static let requestVersion = Frame(.requestVersion)
    public static let requestEQ = Frame(.requestAdvancedEQ)
}

/// Reassembles frames that may be split across (or packed into) BLE notifications.
public struct FrameDecoder: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ data: Data) -> [Frame] {
        buffer += data
        var frames: [Frame] = []
        while true {
            guard let start = buffer.firstIndex(of: Frame.identifier) else { buffer.removeAll(); break }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 3 else { break }
            let long = Frame.longLengthCommands.contains(buffer[1])
            let header = long ? 4 : 3
            guard buffer.count >= header else { break }
            let size = long ? Int(buffer[2]) << 8 | Int(buffer[3]) : Int(buffer[2])
            guard buffer.count >= header + size else { break }
            frames.append(Frame(buffer[1], Array(buffer[header..<header + size])))
            buffer.removeFirst(header + size)
        }
        return frames
    }
}

// MARK: - Speaker info (0x12 tokens)

/// One `0x12` notification carries one token: `00 | token | value`.
/// Tokens with the high bit set carry a length-prefixed UTF-8 string.
public enum InfoToken: Equatable, Sendable {
    case name(String)
    case serial(String)
    case productID(UInt16)
    case color(UInt8)
    /// Percentage in the low 7 bits; the high bit is set while charging (Flip 7: `0x8A` = charging, 10%).
    case battery(level: Int, charging: Bool)
    case audioChannel(UInt8)
    case audioSourceConnected(Bool)
    /// Token 3C: 1 while the speaker is in Auracast / Play Together mode, 0 when it isn't.
    case auracast(UInt8)
    case firmware(String)
    case other(token: UInt8, value: [UInt8])

    public static func parse(_ payload: [UInt8]) -> InfoToken? {
        guard payload.count >= 2 else { return nil }
        let token = payload[1]
        var value = Array(payload.dropFirst(2))
        if token & 0x80 != 0, let length = value.first {
            value = Array(value.dropFirst().prefix(Int(length)))
            let text = String(decoding: value, as: UTF8.self)
            switch token {
            case 0xC1: return .name(text)
            case 0xC2: return .serial(text)
            default: return .other(token: token, value: value)
            }
        }
        switch (token, value.count) {
        case (0x42, 2...): return .productID(UInt16(value[0]) << 8 | UInt16(value[1]))
        case (0x43, 1...): return .color(value[0])
        case (0x44, 1...): return .battery(level: Int(value[0] & 0x7F), charging: value[0] & 0x80 != 0)
        case (0x46, 1...): return .audioChannel(value[0])
        case (0x47, 1...): return .audioSourceConnected(value[0] != 0)
        case (0x3C, 1...): return .auracast(value[0])
        case (0x4D, 1...): return .firmware(FirmwareVersion.format(value))
        default: return .other(token: token, value: value)
        }
    }
}

/// Info-token ids used by the 0x11 / 0x12 / 0x13 commands.
public enum InfoTokenID {
    /// 3C — Auracast / Play Together mode: 1 on, 0 off.
    public static let auracast: UInt8 = 0x3C
    public static let productID: UInt8 = 0x42
    public static let color: UInt8 = 0x43
    public static let battery: UInt8 = 0x44
    public static let audioChannel: UInt8 = 0x46
    public static let audioSourceConnected: UInt8 = 0x47
    public static let firmware: UInt8 = 0x4D
}

public extension Frame {
    /// AA 13 | 00 | token — asks for a single info token, the shape JBL's app calls a token request.
    static func requestToken(_ token: UInt8) -> Frame {
        Frame(.requestToken, [0x00, token])
    }

    /// AA 13 | 00 | token | length | value… — sets one token.
    ///
    /// JBL's app builds the Auracast switch as AA 13 04 00 3C 01 01 (on) / …01 00 (off), and answers with
    /// a DEV_ACK (AA 00 02 13 00 = accepted).
    static func setToken(_ token: UInt8, _ value: [UInt8]) -> Frame {
        Frame(.requestToken, [0x00, token, UInt8(value.count)] + value)
    }

    /// The Auracast / Play Together switch.
    static func setAuracast(_ on: Bool) -> Frame {
        setToken(InfoTokenID.auracast, [on ? 0x01 : 0x00])
    }
}

public enum FirmwareVersion {
    /// `00 07 02 00` → "0.7.2.0"
    public static func format(_ bytes: [UInt8]) -> String {
        bytes.map(String.init).joined(separator: ".")
    }
}
