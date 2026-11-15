import Foundation

// MARK: - Auracast / stereo pair vocabulary

/// Which half of a stereo pair a unit plays, from the JBL app's `AudioChannel`
/// (device-info token `0x46`, and the `04` TLV of an Auracast group reply).
public enum AudioChannel: UInt8, Sendable, CaseIterable, Equatable {
    /// Not in a stereo pair: the unit plays the whole mix (JBL calls this NONE).
    case mono = 0
    case left = 1
    case right = 2

    public var label: String {
        switch self {
        case .mono: "Mono"
        case .left: "Left"
        case .right: "Right"
        }
    }

    public var badge: String? {
        switch self {
        case .mono: nil
        case .left: "L"
        case .right: "R"
        }
    }

    public var swapped: AudioChannel {
        switch self {
        case .mono: .mono
        case .left: .right
        case .right: .left
        }
    }

    /// Unknown byte values are ignored rather than guessed at.
    public init?(channel: UInt8) {
        self.init(rawValue: channel)
    }
}

/// `SetLinkMode` value: what the speaker's radio is doing.
/// Go 4 and every other Auracast-capable portable use `auracast`; older
/// PartyBoost models use `partyBoost`.
public enum LinkMode: UInt8, Sendable, CaseIterable, Equatable {
    case off = 0
    case partyBoost = 1
    case auracast = 2

    public var label: String {
        switch self {
        case .off: "Off"
        case .partyBoost: "PartyBoost"
        case .auracast: "Auracast"
        }
    }
}

/// Role reported by `AA 6B` / `AA 16` and by the `03` TLV of a group reply.
public enum DeviceRole: UInt8, Sendable, Equatable {
    case normal = 0
    case master = 1
    case slave = 2
    case standby = 3
    case twsMaster = 101
    case twsSlave = 102

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .master: "Broadcasting"
        case .slave: "Receiving"
        case .standby: "Standby"
        case .twsMaster: "TWS master"
        case .twsSlave: "TWS slave"
        }
    }

    public init?(roleValue: UInt8) {
        self.init(rawValue: roleValue)
    }
}

public enum AuracastGroupAction: UInt8, Sendable, Equatable {
    case create = 1
    case destroy = 2
    case prepare = 3
}

public enum AuracastGroupType: UInt8, Sendable, Equatable {
    case stereo = 1
    case party = 2

    public var label: String {
        switch self {
        case .stereo: "Stereo"
        case .party: "Party"
        }
    }
}

// MARK: - Group request / status

/// A create/destroy request for `AA A0`.
///
/// JBL's app has two shapes: the compact one it sends to non-long-lasting
/// models (Go 4, Clip 5, Xtreme 4) and the longer one used by AirTouch and
/// long-lasting-stereo models. `longLasting` picks between them.
public struct AuracastGroupRequest: Equatable, Sendable {
    public var action: AuracastGroupAction
    public var type: AuracastGroupType
    public var role: DeviceRole?
    public var channel: AudioChannel
    public var groupID: [UInt8]?
    public var name: String?
    public var partnerAddress: [UInt8]?
    public var longLasting: Bool

    public init(action: AuracastGroupAction = .create, type: AuracastGroupType = .stereo,
                role: DeviceRole? = nil, channel: AudioChannel,
                groupID: [UInt8]? = nil, name: String? = nil, partnerAddress: [UInt8]? = nil,
                longLasting: Bool = false) {
        self.action = action
        self.type = type
        self.role = role
        self.channel = channel
        self.groupID = groupID
        self.name = name
        self.partnerAddress = partnerAddress
        self.longLasting = longLasting
    }
}

/// What the speaker reports for `AA A1`: `token | length | value` entries.
public struct AuracastGroup: Equatable, Sendable {
    public var action: AuracastGroupAction?
    public var type: AuracastGroupType?
    public var role: DeviceRole?
    public var channel: AudioChannel?
    public var groupID: [UInt8]?
    public var name: String?
    public var partnerAddress: [UInt8]?
    /// The `08` TLV: the app writes `14` here and only reads it back.
    public var extra: UInt8?
    /// Bytes we could not place, kept for diagnostics.
    public var unknown: [[UInt8]] = []

    public init() {}

    public init(payload: [UInt8]) {
        var offset = 0
        while offset + 2 <= payload.count {
            let token = payload[offset]
            let length = Int(payload[offset + 1])
            guard offset + 2 + length <= payload.count else { break }
            let value = Array(payload[(offset + 2)..<(offset + 2 + length)])
            switch token {
            case 0x01: action = value.first.flatMap(AuracastGroupAction.init(rawValue:))
            case 0x02: type = value.first.flatMap(AuracastGroupType.init(rawValue:))
            case 0x03: role = value.first.flatMap(DeviceRole.init(roleValue:))
            case 0x04: channel = value.first.flatMap(AudioChannel.init(channel:))
            case 0x05: groupID = value
            case 0x06: name = String(decoding: value, as: UTF8.self)
            case 0x07: partnerAddress = value
            case 0x08: extra = value.first
            default: unknown.append([token] + value)
            }
            offset += 2 + length
        }
    }

    /// True when this unit is part of a stereo group.
    public var isStereo: Bool { type == .stereo && channel != .mono && channel != nil }
    public var isParty: Bool { type == .party }
    public var groupIDHex: String? {
        groupID.map { $0.map { String(format: "%02X", $0) }.joined() }
    }
}

// MARK: - Frames

public extension Frame {
    /// `AA 6A 01 <mode>` — the switch behind JBL's Auracast / PartyBoost button.
    /// Answered by `AA 6B 01 <role>`.
    static func setLinkMode(_ mode: LinkMode) -> Frame {
        Frame(.setLinkMode, [mode.rawValue])
    }

    /// `AA 17 00` — role check, answered by `AA 16 01 <role>`.
    static let requestLinkRole = Frame(.requestLinkRole)

    /// `AA 15 03 <deviceIndex> 46 <channel>` — select this unit's stereo half.
    ///
    /// This is the same SetDeviceInfo frame JBL's app builds for
    /// `SetChannelCommand`: channel 0 none, 1 left, 2 right. The speaker
    /// answers with a DEV_ACK (`AA 00 02 15 00`).
    static func setAudioChannel(_ channel: AudioChannel, deviceIndex: UInt8 = 0) -> Frame {
        Frame(.setDeviceInfo, [deviceIndex, InfoTokenID.audioChannel, channel.rawValue])
    }

    /// `AA 15 03 <deviceIndex> 49 <0|1>` — lock the stereo half so it survives a power cycle.
    static func setStereoLock(_ locked: Bool, deviceIndex: UInt8 = 0) -> Frame {
        Frame(.setDeviceInfo, [deviceIndex, InfoTokenID.stereoLock, locked ? 0x01 : 0x00])
    }

    /// `AA A1 00` — ask for the current Auracast group; `AA A2` answers.
    static let requestAuracastGroup = Frame(.requestAuracastGroup)

    /// `AA A0 <length> <TLV…>` — create or destroy a stereo/party group.
    ///
    /// Compact form (Go 4, Clip 5, Xtreme 4): `01 01 action | 02 01 type | 04 01 channel`,
    /// plus `05 04 <group id>`. Long-lasting / AirTouch adds the role, name, partner
    /// address and a trailing `08 01 14`, exactly as `SetAuraCastGroupCommand` does.
    static func setAuracastGroup(_ request: AuracastGroupRequest) -> Frame {
        var payload: [UInt8] = [0x01, 0x01, request.action.rawValue, 0x02, 0x01, request.type.rawValue]
        if request.longLasting, let role = request.role {
            payload += [0x03, 0x01, role.rawValue]
        }
        payload += [0x04, 0x01, request.channel.rawValue]
        if let id = request.groupID, id.count == 4 {
            payload += [0x05, 0x04] + id
        }
        if let name = request.name {
            let bytes = Array(name.utf8.prefix(30))
            payload += [0x06, UInt8(bytes.count)] + bytes
        }
        if let address = request.partnerAddress, address.count == 6 {
            payload += [0x07, 0x06] + address
        }
        if request.longLasting {
            payload += [0x08, 0x01, 0x14]
        }
        return Frame(.setAuracastGroup, payload)
    }
}
