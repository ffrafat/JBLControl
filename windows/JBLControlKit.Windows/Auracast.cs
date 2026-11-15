namespace JBLControlKit.Windows;

// Ported from Sources/JBLControlKit/Auracast.swift.
// Frames from JBL Portable 6.9.33 (SetLinkModeCommand, SetChannelCommand,
// SetChannelLockCommand, ReqAuracastGroupCommand, SetAuraCastGroupCommand,
// SetAuracastGroupNonLLSCommand).

/// <summary>Which half of a stereo pair a unit plays (device-info token 0x46).</summary>
public enum AudioChannel : byte
{
    /// <summary>Not in a stereo pair: the unit plays the whole mix (JBL calls this NONE).</summary>
    Mono = 0,
    Left = 1,
    Right = 2,
}

public static class AudioChannelExtensions
{
    public static string Label(this AudioChannel channel) => channel switch
    {
        AudioChannel.Mono => "Mono",
        AudioChannel.Left => "Left",
        AudioChannel.Right => "Right",
        _ => throw new ArgumentOutOfRangeException(nameof(channel)),
    };

    public static string? Badge(this AudioChannel channel) => channel switch
    {
        AudioChannel.Left => "L",
        AudioChannel.Right => "R",
        _ => null,
    };

    public static AudioChannel Swapped(this AudioChannel channel) => channel switch
    {
        AudioChannel.Left => AudioChannel.Right,
        AudioChannel.Right => AudioChannel.Left,
        _ => AudioChannel.Mono,
    };
}

/// <summary><c>SetLinkMode</c> value: what the speaker's radio is doing.</summary>
public enum LinkMode : byte
{
    Off = 0,
    PartyBoost = 1,
    Auracast = 2,
}

public static class LinkModeExtensions
{
    public static string Label(this LinkMode mode) => mode switch
    {
        LinkMode.Off => "Off",
        LinkMode.PartyBoost => "PartyBoost",
        LinkMode.Auracast => "Auracast",
        _ => throw new ArgumentOutOfRangeException(nameof(mode)),
    };
}

/// <summary>Role reported by <c>AA 6B</c> / <c>AA 16</c> and by the <c>03</c> TLV of a group reply.</summary>
public enum DeviceRole : byte
{
    Normal = 0,
    Master = 1,
    Slave = 2,
    Standby = 3,
    TwsMaster = 101,
    TwsSlave = 102,
}

public static class DeviceRoleExtensions
{
    public static string Label(this DeviceRole role) => role switch
    {
        DeviceRole.Normal => "Normal",
        DeviceRole.Master => "Broadcasting",
        DeviceRole.Slave => "Receiving",
        DeviceRole.Standby => "Standby",
        DeviceRole.TwsMaster => "TWS master",
        DeviceRole.TwsSlave => "TWS slave",
        _ => throw new ArgumentOutOfRangeException(nameof(role)),
    };
}

public enum AuracastGroupAction : byte
{
    Create = 1,
    Destroy = 2,
    Prepare = 3,
}

public enum AuracastGroupType : byte
{
    Stereo = 1,
    Party = 2,
}

public static class AuracastGroupTypeExtensions
{
    public static string Label(this AuracastGroupType type) => type switch
    {
        AuracastGroupType.Stereo => "Stereo",
        AuracastGroupType.Party => "Party",
        _ => throw new ArgumentOutOfRangeException(nameof(type)),
    };
}

/// <summary>A create/destroy request for <c>AA A0</c>.</summary>
public sealed class AuracastGroupRequest
{
    public AuracastGroupAction Action { get; init; } = AuracastGroupAction.Create;
    public AuracastGroupType Type { get; init; } = AuracastGroupType.Stereo;
    public DeviceRole? Role { get; init; }
    public AudioChannel Channel { get; init; } = AudioChannel.Mono;
    public byte[]? GroupId { get; init; }
    public string? Name { get; init; }
    public byte[]? PartnerAddress { get; init; }

    /// <summary>Pick the longer form JBL's app sends to AirTouch / long-lasting-stereo models.</summary>
    public bool LongLasting { get; init; }
}

/// <summary>What the speaker reports for <c>AA A1</c>: <c>token | length | value</c> entries.</summary>
public sealed class AuracastGroup
{
    public AuracastGroupAction? Action { get; private set; }
    public AuracastGroupType? Type { get; private set; }
    public DeviceRole? Role { get; private set; }
    public AudioChannel? Channel { get; private set; }
    public byte[]? GroupId { get; private set; }
    public string? Name { get; private set; }
    public byte[]? PartnerAddress { get; private set; }
    public byte? Extra { get; private set; }
    public List<byte[]> Unknown { get; } = new();

    public static AuracastGroup Parse(byte[] payload)
    {
        var group = new AuracastGroup();
        int offset = 0;
        while (offset + 2 <= payload.Length)
        {
            byte token = payload[offset];
            int length = payload[offset + 1];
            if (offset + 2 + length > payload.Length) break;
            byte[] value = payload[(offset + 2)..(offset + 2 + length)];
            switch (token)
            {
                case 0x01 when value.Length > 0:
                    group.Action = (AuracastGroupAction)value[0];
                    break;
                case 0x02 when value.Length > 0:
                    group.Type = (AuracastGroupType)value[0];
                    break;
                case 0x03 when value.Length > 0:
                    group.Role = (DeviceRole)value[0];
                    break;
                case 0x04 when value.Length > 0:
                    group.Channel = (AudioChannel)value[0];
                    break;
                case 0x05:
                    group.GroupId = value;
                    break;
                case 0x06:
                    group.Name = System.Text.Encoding.UTF8.GetString(value);
                    break;
                case 0x07:
                    group.PartnerAddress = value;
                    break;
                case 0x08 when value.Length > 0:
                    group.Extra = value[0];
                    break;
                default:
                    group.Unknown.Add(new[] { token }.Concat(value).ToArray());
                    break;
            }
            offset += 2 + length;
        }
        return group;
    }

    public bool IsStereo => Type == AuracastGroupType.Stereo
        && Channel is AudioChannel.Left or AudioChannel.Right;

    public bool IsParty => Type == AuracastGroupType.Party;

    public string? GroupIdHex => GroupId is null ? null : Convert.ToHexString(GroupId);
}

public readonly partial struct Frame
{
    /// <summary><c>AA 6A 01 &lt;mode&gt;</c>, answered by <c>AA 6B 01 &lt;role&gt;</c>.</summary>
    public static Frame SetLinkMode(LinkMode mode) => new((byte)0x6A, new[] { (byte)mode });

    /// <summary><c>AA 17 00</c> — role check, answered by <c>AA 16 01 &lt;role&gt;</c>.</summary>
    public static Frame RequestLinkRole => new((byte)0x17);

    /// <summary><c>AA 15 03 &lt;deviceIndex&gt; 46 &lt;channel&gt;</c>.</summary>
    public static Frame SetAudioChannel(AudioChannel channel, byte deviceIndex = 0) =>
        new((byte)0x15, new[] { deviceIndex, (byte)0x46, (byte)channel });

    /// <summary><c>AA 15 03 &lt;deviceIndex&gt; 49 &lt;0|1&gt;</c>.</summary>
    public static Frame SetStereoLock(bool locked, byte deviceIndex = 0) =>
        new((byte)0x15, new[] { deviceIndex, (byte)0x49, locked ? (byte)1 : (byte)0 });

    /// <summary><c>AA A1 00</c> — ask for the current group; <c>AA A2</c> answers.</summary>
    public static Frame RequestAuracastGroup => new((byte)0xA1);

    /// <summary><c>AA A0 &lt;length&gt; &lt;TLV…&gt;</c> — create or destroy a stereo/party group.</summary>
    public static Frame SetAuracastGroup(AuracastGroupRequest request)
    {
        var payload = new List<byte>
        {
            0x01, 0x01, (byte)request.Action,
            0x02, 0x01, (byte)request.Type,
        };
        if (request.LongLasting && request.Role is { } role)
        {
            payload.AddRange(new byte[] { 0x03, 0x01, (byte)role });
        }
        payload.AddRange(new byte[] { 0x04, 0x01, (byte)request.Channel });
        if (request.GroupId is { Length: 4 } id)
        {
            payload.AddRange(new byte[] { 0x05, 0x04 });
            payload.AddRange(id);
        }
        if (request.Name is { } name)
        {
            byte[] bytes = System.Text.Encoding.UTF8.GetBytes(name);
            if (bytes.Length > 30) bytes = bytes[..30];
            payload.AddRange(new byte[] { 0x06, (byte)bytes.Length });
            payload.AddRange(bytes);
        }
        if (request.PartnerAddress is { Length: 6 } address)
        {
            payload.AddRange(new byte[] { 0x07, 0x06 });
            payload.AddRange(address);
        }
        if (request.LongLasting)
        {
            payload.AddRange(new byte[] { 0x08, 0x01, 0x14 });
        }
        return new Frame((byte)0xA0, payload.ToArray());
    }
}
