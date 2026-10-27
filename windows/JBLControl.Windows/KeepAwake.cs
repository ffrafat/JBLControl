using System.Diagnostics;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Dispatching;
using Windows.Devices.Enumeration;
using Windows.Media.Core;
using Windows.Media.Devices;
using Windows.Media.Playback;
using Windows.Storage.Streams;

namespace JBLControl.Windows;

public enum KeepAwakeState
{
    Off,

    /// <summary>On, but the speaker isn't this PC's sound output, so pings can't reach it.</summary>
    WaitingForOutput,

    Active,
}

/// <summary>
/// Keeps a JBL speaker from auto-powering-off by playing a brief, very quiet low tone every few
/// minutes while it's idle. Ported from Sources/JBLControl/KeepAwake.swift.
///
/// It works through sound, not the control protocol, so it only works while this PC is the
/// speaker's audio output. It never plays on other output devices and never changes the system's
/// output. It pings even if the device looks busy: a tone this low and quiet is inaudible under music anyway.
/// </summary>
public sealed class KeepAwake : ObservableObject
{
    public static readonly TimeSpan PingInterval = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan CheckInterval = TimeSpan.FromSeconds(30);

    private readonly SpeakerManager speaker;
    private readonly DispatcherQueueTimer timer;
    private readonly TonePlayer tone = new();
    private DateTimeOffset? lastPing;

    public KeepAwake(SpeakerManager speaker, DispatcherQueue ui)
    {
        this.speaker = speaker;
        timer = ui.CreateTimer();
        timer.Interval = CheckInterval;
        timer.Tick += async (_, _) =>
        {
            try
            {
                await TickAsync();
            }
            catch (Exception ex)
            {
                CrashLog.Write(ex); // a timer callback that throws would take the whole tray app down
            }
        };
        Restart();
    }

    private KeepAwakeState state = KeepAwakeState.Off;
    public KeepAwakeState State { get => state; private set => SetProperty(ref state, value); }

    public bool IsEnabled
    {
        get => Preferences.Shared.KeepAwake;
        set
        {
            if (Preferences.Shared.KeepAwake == value) return;
            Preferences.Shared.KeepAwake = value;
            OnPropertyChanged();
            Restart();
        }
    }

    private void Restart()
    {
        timer.Stop();
        lastPing = null;
        if (!IsEnabled)
        {
            State = KeepAwakeState.Off;
            return;
        }
        _ = TickAsync();
        timer.Start();
    }

    private async Task TickAsync()
    {
        DeviceInformation? output = null;
        try
        {
            string? id = MediaDevice.GetDefaultAudioRenderId(AudioDeviceRole.Default);
            if (!string.IsNullOrEmpty(id)) output = await DeviceInformation.CreateFromIdAsync(id);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[awake] couldn't read the default output: {ex.Message}");
        }
        if (!IsEnabled) return;
        if (output is null || !IsSpeaker(output.Name))
        {
            State = KeepAwakeState.WaitingForOutput;
            return;
        }
        State = KeepAwakeState.Active;
        if (lastPing is { } last && DateTimeOffset.Now - last < PingInterval) return;
        lastPing = DateTimeOffset.Now;
        Debug.WriteLine($"[awake] ping to {output.Name}");
        await tone.PlayAsync(output);
    }

    /// <summary>The system output is this speaker (by its Bluetooth name), or any JBL when the name isn't known yet.
    /// Windows names Bluetooth outputs like "Speakers (FFR JBL Flip 7)", so this matches by containment
    /// where the Mac app (whose device names are the bare speaker name) matches by prefix.</summary>
    private bool IsSpeaker(string deviceName)
    {
        if (speaker.Name is { } name)
            return deviceName.Contains(name, StringComparison.OrdinalIgnoreCase) || name.Contains(deviceName, StringComparison.OrdinalIgnoreCase);
        return deviceName.Contains("JBL", StringComparison.OrdinalIgnoreCase);
    }
}

/// <summary>
/// A 2-second 30 Hz sine at about −40 dBFS with smooth fades: enough signal for the speaker to
/// count as "playing" (pure digital silence is often ignored), too low and quiet to hear.
/// Played as an in-memory WAV on the given output device only.
/// </summary>
public sealed class TonePlayer
{
    private const int SampleRate = 48000;
    private const double Duration = 2.0, Frequency = 30.0, Amplitude = 0.01, Fade = 0.25;
    private static readonly byte[] Wav = BuildWav();
    private bool playing;

    public async Task PlayAsync(DeviceInformation output)
    {
        if (playing) return;
        playing = true;
        MediaPlayer? player = null;
        try
        {
            // Inside the try: a speaker switched off a moment ago can make the player refuse its output,
            // and `playing` must not stay set or Keep Awake never pings again.
            player = new MediaPlayer { AudioDevice = output, AudioCategory = MediaPlayerAudioCategory.Other };
            // Keep the tone out of the media overlay and lock-screen controls.
            player.CommandManager.IsEnabled = false;
            var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream))
            {
                writer.WriteBytes(Wav);
                await writer.StoreAsync();
                await writer.FlushAsync();
                writer.DetachStream();
            }
            stream.Seek(0);
            player.Source = MediaSource.CreateFromStream(stream, "audio/wav");
            player.Play();
            await Task.Delay(TimeSpan.FromSeconds(Duration + 0.3));
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[awake] tone failed: {ex.Message}");
        }
        finally
        {
            try
            {
                player?.Dispose();
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[awake] couldn't release the player: {ex.Message}");
            }
            playing = false;
        }
    }

    private static byte[] BuildWav()
    {
        int frames = (int)(Duration * SampleRate);
        const short channels = 2, bits = 16;
        int dataBytes = frames * channels * bits / 8;
        using var ms = new MemoryStream(44 + dataBytes);
        using var w = new BinaryWriter(ms);
        w.Write("RIFF"u8);
        w.Write(36 + dataBytes);
        w.Write("WAVEfmt "u8);
        w.Write(16);
        w.Write((short)1); // PCM
        w.Write(channels);
        w.Write(SampleRate);
        w.Write(SampleRate * channels * bits / 8);
        w.Write((short)(channels * bits / 8));
        w.Write(bits);
        w.Write("data"u8);
        w.Write(dataBytes);
        for (int i = 0; i < frames; i++)
        {
            double t = (double)i / SampleRate;
            double envelope = Math.Min(1, Math.Min(t / Fade, Math.Max(0, (Duration - t) / Fade)));
            short sample = (short)Math.Round(short.MaxValue * Amplitude * envelope * Math.Sin(2 * Math.PI * Frequency * t));
            w.Write(sample);
            w.Write(sample);
        }
        w.Flush();
        return ms.ToArray();
    }
}
