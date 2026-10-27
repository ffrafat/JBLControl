import AudioToolbox
import CoreAudio
import Observation

/// The speaker's volume and mute. JBL's control protocol has no volume command, so this is the
/// speaker's audio output on this Mac (what the volume keys change), found by its Bluetooth name.
/// Only available while the speaker is one of this Mac's sound outputs.
@MainActor @Observable
final class SpeakerVolume {
    /// The speaker's output device, or nil when it isn't connected to this Mac for audio.
    private(set) var device: AudioDeviceID?
    /// 0...1
    private(set) var level: Float = 0
    private(set) var isMuted = false

    /// Bluetooth outputs often have no mute control; muting them sets the volume to 0 and remembers it.
    @ObservationIgnored private var levelBeforeMute: Float?

    /// Re-reads the device and its volume (they change from the keyboard, Control Center, or a reconnect).
    func refresh(speakerName: String?) {
        var reading: Float32?
        device = AudioOutput.outputDevices().first {
            guard AudioOutput.name(of: $0).map({ AudioOutput.isSpeaker($0, speakerName: speakerName) }) ?? false else { return false }
            reading = Self.get(Float32.self, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, of: $0)
            return reading != nil // no volume control, nothing to show
        }
        guard let device, let reading else { return }
        level = reading
        if let mute = Self.get(UInt32.self, kAudioDevicePropertyMute, of: device) {
            isMuted = mute != 0
        } else {
            if level > 0 { levelBeforeMute = nil } // turned up elsewhere
            isMuted = levelBeforeMute != nil
        }
    }

    func setLevel(_ value: Float) {
        guard let device else { return }
        level = min(max(value, 0), 1)
        Self.set(Float32(level), kAudioHardwareServiceDeviceProperty_VirtualMainVolume, of: device)
        if isMuted, level > 0 { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard let device else { return }
        if Self.set(UInt32(muted ? 1 : 0), kAudioDevicePropertyMute, of: device) {
            isMuted = muted
        } else if muted {
            levelBeforeMute = level
            Self.set(Float32(0), kAudioHardwareServiceDeviceProperty_VirtualMainVolume, of: device)
            level = 0
            isMuted = true
        } else {
            let restore = levelBeforeMute ?? 0.5
            levelBeforeMute = nil
            isMuted = false
            setLevel(restore)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T: BitwiseCopyable>(_ type: T.Type, _ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> T? {
        var address = address(selector)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    /// Whether the device has the property and accepted the new value.
    @discardableResult
    private static func set<T: BitwiseCopyable>(_ value: T, _ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> Bool {
        var address = address(selector)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue
        else { return false }
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }
}

extension AudioOutput {
    /// Every device with at least one output stream.
    static func outputDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.filter { device in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr && streamSize > 0
        }
    }
}
