import AVFoundation
import CoreAudio
import Observation
import os

/// Keeps a JBL speaker from auto-powering-off by playing a brief, very quiet low tone every few
/// minutes while it's idle. JBL portables switch off after roughly 10–20 minutes without audio and
/// have no setting to stop that (except Go 5 / Xtreme 5).
///
/// It works through sound, not the control protocol, so it only works while this Mac is the
/// speaker's audio output. It never plays on other output devices and never changes the system's
/// output. It pings even if the device looks busy: many apps hold the output open in silence, and a
/// tone this low and quiet is inaudible under music anyway.
@MainActor @Observable
final class KeepAwake {
    enum State: Equatable {
        case off
        /// On, but the speaker isn't this Mac's sound output, so pings can't reach it.
        case waitingForOutput
        case active
    }

    static let pingInterval: TimeInterval = 5 * 60
    private static let checkInterval: Duration = .seconds(30)

    private(set) var state: State = .off
    var isEnabled: Bool = UserDefaults.standard.bool(forKey: Pref.keepAwake) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Pref.keepAwake)
            restart()
        }
    }

    @ObservationIgnored private weak var speaker: SpeakerManager?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastPing: Date?
    @ObservationIgnored private let tone = TonePlayer()

    init(speaker: SpeakerManager) {
        self.speaker = speaker
        restart()
    }

    private func restart() {
        loop?.cancel()
        lastPing = nil
        guard isEnabled else {
            state = .off
            return
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    private func tick() {
        guard let device = AudioOutput.defaultDevice(),
              let deviceName = AudioOutput.name(of: device),
              isSpeaker(deviceName) else {
            state = .waitingForOutput
            return
        }
        state = .active
        if let lastPing, Date.now.timeIntervalSince(lastPing) < Self.pingInterval { return }
        lastPing = .now
        log.info("keep-awake ping to \(deviceName, privacy: .public)")
        tone.play()
    }

    /// The system output is this speaker (by its Bluetooth name), or any JBL when the name isn't known yet.
    private func isSpeaker(_ deviceName: String) -> Bool {
        if let name = speaker?.name {
            return deviceName.hasPrefix(name) || name.hasPrefix(deviceName)
        }
        return deviceName.localizedCaseInsensitiveContains("JBL")
    }
}

/// Default output device queries (CoreAudio).
enum AudioOutput {
    static func defaultDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    static func name(of device: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }
}

/// A 2-second 30 Hz sine at about −40 dBFS with smooth fades: enough signal for the speaker to
/// count as "playing" (pure digital silence is often ignored), too low and quiet to hear.
@MainActor
final class TonePlayer {
    private let engine = AVAudioEngine()
    private var playing = false

    func play() {
        guard !playing else { return }
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        let duration = 2.0, frequency = 30.0, amplitude: Float = 0.01, fade = 0.25
        let total = Int(duration * sampleRate)
        var frame = 0
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for i in 0..<Int(frameCount) {
                let t = Double(frame) / sampleRate
                let envelope = min(1, t / fade, max(0, (duration - t) / fade))
                let sample = frame < total ? amplitude * Float(envelope * sin(2 * .pi * frequency * t)) : 0
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[i] = sample
                }
                frame += 1
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            log.error("keep-awake tone failed: \(error.localizedDescription, privacy: .public)")
            engine.detach(source)
            return
        }
        playing = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration + 0.3))
            engine.stop()
            engine.detach(source)
            playing = false
        }
    }
}
