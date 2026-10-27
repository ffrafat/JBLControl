using System.Diagnostics;
using System.Runtime.InteropServices;
using Windows.Devices.Enumeration;
using Windows.Media.Devices;

namespace JBLControl.Windows;

/// <summary>
/// The speaker's volume and mute. JBL's control protocol has no volume command, so this is the speaker's
/// audio output on this PC (what the volume keys change), found by its Bluetooth name. Only available while
/// the speaker is one of this PC's sound outputs. Ported from Sources/JBLControl/SpeakerVolume.swift.
/// </summary>
public sealed class SpeakerVolume
{
    private static readonly TimeSpan LookupInterval = TimeSpan.FromSeconds(5);

    private IAudioEndpointVolume? endpoint;
    private string? endpointId;
    private string? lookedUpFor;
    private DateTimeOffset lastLookup;

    public bool IsAvailable => endpoint is not null;

    /// <summary>0...1</summary>
    public float Level { get; private set; }

    public bool IsMuted { get; private set; }

    /// <summary>Re-reads the device and its volume (they change from the keyboard, the Sound settings, or a reconnect).</summary>
    public async Task RefreshAsync(string? speakerName)
    {
        try
        {
            if (endpoint is null || speakerName != lookedUpFor || DateTimeOffset.Now - lastLookup > LookupInterval)
                await LookUpAsync(speakerName);
            if (endpoint is null) return;
            Marshal.ThrowExceptionForHR(endpoint.GetMasterVolumeLevelScalar(out float level));
            Marshal.ThrowExceptionForHR(endpoint.GetMute(out bool muted));
            Level = level;
            IsMuted = muted;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[volume] {ex.Message}");
            Release();
        }
    }

    public void SetLevel(float level)
    {
        if (endpoint is null) return;
        Level = Math.Clamp(level, 0, 1);
        var context = Guid.Empty;
        endpoint.SetMasterVolumeLevelScalar(Level, ref context);
        if (IsMuted && Level > 0) SetMuted(false);
    }

    public void SetMuted(bool muted)
    {
        if (endpoint is null) return;
        var context = Guid.Empty;
        if (endpoint.SetMute(muted, ref context) >= 0) IsMuted = muted;
    }

    private async Task LookUpAsync(string? speakerName)
    {
        lookedUpFor = speakerName;
        lastLookup = DateTimeOffset.Now;
        var outputs = await DeviceInformation.FindAllAsync(MediaDevice.GetAudioRenderSelector());
        var output = outputs.FirstOrDefault(d => KeepAwake.IsSpeaker(d.Name, speakerName));
        string? id = output is null ? null : MMDeviceId(output.Id);
        if (id == endpointId && endpoint is not null) return;
        Release();
        if (id is null) return;

        var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        try
        {
            Marshal.ThrowExceptionForHR(enumerator.GetDevice(id, out var device));
            var iid = typeof(IAudioEndpointVolume).GUID;
            Marshal.ThrowExceptionForHR(device.Activate(ref iid, ClsctxAll, IntPtr.Zero, out object volume));
            Marshal.ReleaseComObject(device);
            endpoint = (IAudioEndpointVolume)volume;
            endpointId = id;
        }
        finally
        {
            Marshal.ReleaseComObject(enumerator);
        }
    }

    private void Release()
    {
        if (endpoint is not null) Marshal.ReleaseComObject(endpoint);
        endpoint = null;
        endpointId = null;
    }

    /// <summary>
    /// WinRT names an audio endpoint <c>\\?\SWD#MMDEVAPI#{0.0.0.00000000}.{guid}#{interface}</c>; Core Audio
    /// knows it as the part in the middle.
    /// </summary>
    private static string? MMDeviceId(string winRtId)
    {
        const string marker = "MMDEVAPI#";
        int start = winRtId.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
        if (start < 0) return null;
        start += marker.Length;
        int end = winRtId.IndexOf('#', start);
        return end < 0 ? winRtId[start..] : winRtId[start..end];
    }

    // Core Audio (mmdeviceapi.h, endpointvolume.h). Methods are declared in vtable order up to the last one used.

    private const int ClsctxAll = 0x17;

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumerator { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int GetChannelCount(out uint count);
        [PreserveSig] int SetMasterVolumeLevel(float levelDb, ref Guid eventContext);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid eventContext);
        [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(uint channel, float levelDb, ref Guid eventContext);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid eventContext);
        [PreserveSig] int GetChannelVolumeLevel(uint channel, out float levelDb);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint channel, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid eventContext);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }
}
