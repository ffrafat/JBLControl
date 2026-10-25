using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using CommunityToolkit.Mvvm.ComponentModel;
using JBLControlKit.Windows;
using Microsoft.UI.Dispatching;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Radios;

namespace JBLControl.Windows;

/// <summary>A JBL speaker seen advertising nearby, keyed by its (rotating) BLE address.</summary>
public sealed class DiscoveredSpeaker
{
    public required ulong Address { get; init; }
    public string Name { get; set; } = "";
    public ushort? ProductId { get; set; }
    public int Rssi { get; set; }
    public Dictionary<string, string> Advertisement { get; set; } = new();
    public SpeakerModel? Model => Catalog.Model(ProductId);

    public bool IsSameSpeaker(DiscoveredSpeaker other) =>
        SpeakerIdentity.Matches(Name, ProductId, other.Name, other.ProductId);
}

public enum SpeakerStatus { BluetoothOff, Searching, Connecting, Connected }

/// <summary>
/// Owns the BLE link to one JBL speaker and mirrors its state for the UI. Ported from
/// Sources/JBLControl/SpeakerManager.swift. Swift's @MainActor hops CoreBluetooth callbacks onto
/// the main run loop for free; WinRT events fire on background threads, so every callback here is
/// re-dispatched onto the UI thread first and all state is only ever touched from there.
/// CoreBluetooth's peripheral identifier maps to the raw BLE address on Windows.
/// </summary>
public sealed class SpeakerManager : ObservableObject, IAsyncDisposable
{
    private static readonly TimeSpan SilenceLimit = TimeSpan.FromSeconds(12);

    private readonly DispatcherQueue ui;
    private readonly Preferences prefs = Preferences.Shared;
    private readonly List<DiscoveredSpeaker> discovered = new();
    private readonly Dictionary<ulong, DateTimeOffset> lastSeen = new();
    private readonly HashSet<ulong> ignoredAliases = new();
    private readonly Queue<Outgoing> writeQueue = new();
    private readonly List<TrafficEntry> traffic = new();
    private readonly DispatcherQueueTimer pollTimer;
    private readonly DispatcherQueueTimer pruneTimer;
    private MessageDecoder decoder = new();
    private BluetoothLEAdvertisementWatcher? watcher;
    private Radio? radio;
    private bool writing;
    private bool browsing;
    private int openPanels;
    private bool discoveryStarted;
    private bool lowBatteryNotified;
    private int connectAttempt;

    /// <summary>The speaker being controlled or connected to (CBPeripheral in the Mac app).</summary>
    private ulong? activeAddress;

    // The whole device → service → characteristic chain is held for the connection's lifetime:
    // if any link is collected, WinRT silently stops delivering ValueChanged.
    private BluetoothLEDevice? device;
    private GattSession? session;
    private GattDeviceService? service;
    private GattCharacteristic? tx;
    private GattCharacteristic? rx;

    // EQ writes: while one is in flight, newer ones replace each other, so a slider drag
    // sends at most one write per round trip.
    private bool eqInFlight;
    private List<byte[]>? eqNext;
    private CancellationTokenSource? eqTimeout;

    private readonly record struct Outgoing(byte[] Data, bool IsEqWrite);

    public enum Direction { Sent, Received }

    public readonly record struct TrafficEntry(DateTimeOffset Date, Direction Direction, byte[] Data);

    public SpeakerManager(DispatcherQueue ui)
    {
        this.ui = ui;
        pollTimer = ui.CreateTimer();
        pollTimer.Interval = TimeSpan.FromSeconds(60);
        pollTimer.Tick += (_, _) => Guard(() =>
        {
            Enqueue(new List<byte[]> { Frame.RequestInfo.Encoded });
            RequestEqIfUnknown();
        });
        pruneTimer = ui.CreateTimer();
        pruneTimer.Interval = TimeSpan.FromSeconds(4);
        pruneTimer.Tick += (_, _) => Guard(PruneSilentSpeakers);
        pruneTimer.Start();
        prefs.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(Preferences.AllowExperimentalWrites)) OnPropertyChanged(nameof(CanWrite));
        };
    }

    private SpeakerStatus status = SpeakerStatus.Searching;
    public SpeakerStatus Status { get => status; private set => SetProperty(ref status, value); }

    private string? name;
    public string? Name { get => name; private set => SetProperty(ref name, value); }

    private ushort? productId;
    public ushort? ProductId { get => productId; private set => SetProperty(ref productId, value); }

    private byte? colorCode;
    public byte? ColorCode { get => colorCode; private set => SetProperty(ref colorCode, value); }

    private int? battery;
    public int? Battery { get => battery; private set => SetProperty(ref battery, value); }

    private bool charging;
    public bool Charging { get => charging; private set => SetProperty(ref charging, value); }

    private string? firmware;
    public string? Firmware { get => firmware; private set => SetProperty(ref firmware, value); }

    private EQSnapshot? eq;
    public EQSnapshot? Eq { get => eq; private set => SetProperty(ref eq, value); }

    /// <summary>Last known custom curve; survives replies that don't carry it.</summary>
    private float[] customGains = Array.Empty<float>();
    public IReadOnlyList<float> CustomGains => customGains;

    public IReadOnlyList<DiscoveredSpeaker> Discovered => discovered;
    public IReadOnlyList<TrafficEntry> Traffic => traffic;
    public List<string> GattSummary { get; } = new();

    public bool AllowExperimentalWrites
    {
        get => prefs.AllowExperimentalWrites;
        set => prefs.AllowExperimentalWrites = value;
    }

    public SpeakerModel? Model => Catalog.Model(ProductId);
    public EQPreset? ActivePreset => Eq is { } e ? Model?.PickerPresets.FirstOrDefault(p => p.Category == e.ActiveCategory) : null;
    public bool IsCustomActive => Eq is not null && Eq.ActiveCategory == Model?.CustomCategory;
    public bool CanWrite => Model is { } m && (!m.WritesNeedOptIn || AllowExperimentalWrites);
    public ulong? ConnectedAddress => Status == SpeakerStatus.Connected ? activeAddress : null;
    public ulong? ActiveAddress => activeAddress;

    /// <summary>Advertised name of the speaker currently being connected to.</summary>
    public string? ConnectingName => discovered.FirstOrDefault(s => s.Address == activeAddress)?.Name;

    /// <summary>Nearby speakers the user can switch to (supported models, strongest signal first).</summary>
    public List<DiscoveredSpeaker> Switchable => discovered
        .Where(s => s.Model is { Support: not SupportLevel.Unsupported })
        .OrderByDescending(s => s.Rssi).ToList();

    private EQCodec? Codec => Model is { } m ? new EQCodec(m) : null;

    /// <summary>Runs on the UI thread. An exception escaping a DispatcherQueue callback fail-fasts the
    /// process (XAML's UnhandledException never sees it), so anything a callback sets off is logged instead.</summary>
    private void Post(Action action) => ui.TryEnqueue(() => Guard(action));

    private static void Guard(Action action)
    {
        try
        {
            action();
        }
        catch (Exception ex)
        {
            CrashLog.Write(ex);
        }
    }

    // MARK: Actions

    public async Task StartAsync()
    {
        var adapter = await BluetoothAdapter.GetDefaultAsync();
        if (adapter is null || !adapter.IsLowEnergySupported)
        {
            Status = SpeakerStatus.BluetoothOff;
            return;
        }
        radio = await adapter.GetRadioAsync();
        radio.StateChanged += (_, _) => Post(RadioChanged);
        RadioChanged();
    }

    /// <summary>While a panel is open (the tray flyout or the main window), keep scanning so speakers
    /// turned on later show up to switch to. Each open is matched by a PanelClosed.</summary>
    public void PanelOpened()
    {
        bool first = openPanels++ == 0;
        browsing = true;
        // Drop speakers that may have gone away; anything still on air re-appears within a second.
        if (first && discovered.RemoveAll(s => s.Address != activeAddress) > 0) DiscoveredChanged();
        if (Status != SpeakerStatus.BluetoothOff) Scan();
        Refresh();
    }

    public void PanelClosed()
    {
        openPanels = Math.Max(0, openPanels - 1);
        browsing = openPanels > 0;
        if (!browsing && Status == SpeakerStatus.Connected) StopScan();
    }

    public void Refresh()
    {
        if (Status != SpeakerStatus.Connected) return;
        var requests = new List<byte[]> { Frame.RequestInfo.Encoded };
        if (Codec is { } codec) requests.AddRange(codec.ReadRequests());
        Enqueue(requests);
    }

    public void Select(EQPreset preset)
    {
        if (!CanWrite || Codec is not { } codec || Eq is not { } state) return;
        Eq = new EQSnapshot(preset.Category, state.Gains);
        SendEq(codec.Select(preset, customGains));
    }

    public void SetCustomGain(float gain, int band)
    {
        if (!CanWrite || Codec is not { } codec || Model is not { } model) return;
        if (band < 0 || band >= model.CustomBands.Count || band >= customGains.Length) return;
        float snapped = model.CustomBands[band].Snap(gain);
        if (customGains[band] == snapped && IsCustomActive) return;
        customGains[band] = snapped;
        OnPropertyChanged(nameof(CustomGains));
        Eq = new EQSnapshot(model.CustomCategory, customGains.ToArray());
        SendEq(codec.SetCustom(customGains));
    }

    public void ResetCustom()
    {
        if (!CanWrite || Codec is not { } codec || Model is not { } model) return;
        customGains = new float[model.CustomBands.Count];
        OnPropertyChanged(nameof(CustomGains));
        Eq = new EQSnapshot(model.CustomCategory, customGains.ToArray());
        SendEq(codec.SetCustom(customGains));
    }

    /// <summary>Connect to a specific speaker from the list and remember it.</summary>
    public void Choose(DiscoveredSpeaker speaker)
    {
        Remember(speaker.Name, speaker.ProductId, speaker.Address);
        ClearDeviceInfo();
        if (speaker.ProductId is { } pid) SetProductId(pid);
        Connect(speaker.Address);
    }

    public void ForgetSpeaker()
    {
        prefs.SavedSpeakerName = null;
        prefs.SavedSpeakerProductId = null;
        prefs.SavedSpeakerAddress = null;
        connectAttempt++;
        Teardown();
        activeAddress = null;
        ClearDeviceInfo();
        ProductId = null;
        Status = SpeakerStatus.Searching;
        Scan();
    }

    // MARK: Bluetooth radio

    private void RadioChanged()
    {
        if (radio?.State == RadioState.On)
        {
            // A window may have asked for a scan before the radio was known; discovery still starts here,
            // and Scan() restarts a watcher that didn't start.
            if (!discoveryStarted || Status == SpeakerStatus.BluetoothOff)
            {
                discoveryStarted = true;
                StartDiscovery();
            }
            else
            {
                Scan();
            }
            return;
        }
        discoveryStarted = false;
        StopScan();
        connectAttempt++;
        Teardown();
        ClearDeviceInfo();
        Status = SpeakerStatus.BluetoothOff;
    }

    private void StartDiscovery()
    {
        // The remembered address may have rotated since; scanning finds it again if so.
        if (prefs.AutoConnect && prefs.SavedSpeakerAddress is { } saved) Connect(saved);
        Status = activeAddress is null ? SpeakerStatus.Searching : SpeakerStatus.Connecting;
        Scan();
    }

    // MARK: Discovery

    /// <summary>Scanning continues until a link is up: speakers rotate their BLE address, so a remembered
    /// address can go stale and only a fresh advertisement leads back to it.</summary>
    private void Scan()
    {
        if (watcher is { Status: BluetoothLEAdvertisementWatcherStatus.Started or BluetoothLEAdvertisementWatcherStatus.Created })
        {
            if (watcher.Status == BluetoothLEAdvertisementWatcherStatus.Created) TryStart(watcher);
            return;
        }
        StopScan();
        // A fresh watcher each time: a stopped one can still be mid-"Stopping" and refuse to restart.
        watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
        watcher.Received += OnAdvertisementReceived;
        watcher.Stopped += OnWatcherStopped;
        TryStart(watcher);
    }

    private static void TryStart(BluetoothLEAdvertisementWatcher w)
    {
        try
        {
            w.Start();
        }
        catch (Exception ex)
        {
            CrashLog.Write(new InvalidOperationException("Couldn't start scanning", ex));
        }
    }

    /// <summary>A scan that stops on its own (radio hiccup, adapter reset) is restarted after a moment.</summary>
    private void OnWatcherStopped(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementWatcherStoppedEventArgs args)
    {
        if (args.Error == BluetoothError.Success) return;
        Debug.WriteLine($"[ble] scanning stopped: {args.Error}");
        _ = Task.Delay(TimeSpan.FromSeconds(2)).ContinueWith(_ => Post(() =>
        {
            if (sender == watcher && radio?.State == RadioState.On) Scan();
        }), TaskScheduler.Default);
    }

    private void StopScan()
    {
        if (watcher is null) return;
        watcher.Received -= OnAdvertisementReceived;
        watcher.Stopped -= OnWatcherStopped;
        watcher.Stop();
        watcher = null;
    }

    /// <summary>Drops speakers that haven't advertised for a while (they were switched off or moved away).</summary>
    private void PruneSilentSpeakers()
    {
        var cutoff = DateTimeOffset.Now - SilenceLimit;
        // Only the connected speaker is exempt; one we're merely trying to reach may be switched off.
        int removed = discovered.RemoveAll(s => s.Address != ConnectedAddress
            && (!lastSeen.TryGetValue(s.Address, out var seen) || seen < cutoff));
        if (removed > 0) DiscoveredChanged();
    }

    private void DiscoveredChanged()
    {
        OnPropertyChanged(nameof(Discovered));
        OnPropertyChanged(nameof(ConnectingName));
    }

    private void OnAdvertisementReceived(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementReceivedEventArgs args)
    {
        var ad = args.Advertisement;
        var summary = new Dictionary<string, string>();

        byte[]? manufacturer = null;
        ushort? pid = null;
        foreach (var m in ad.ManufacturerData)
        {
            var bytes = new byte[2 + m.Data.Length];
            bytes[0] = (byte)(m.CompanyId & 0xFF);
            bytes[1] = (byte)(m.CompanyId >> 8);
            m.Data.ToArray().CopyTo(bytes, 2);
            manufacturer ??= bytes;
            if (Jbl.ProductId(bytes) is { } found)
            {
                manufacturer = bytes;
                pid = found;
                break;
            }
        }
        if (manufacturer is not null) summary["manufacturerData"] = Hex(manufacturer);

        bool hasJblServiceData = false;
        foreach (var section in ad.GetSectionsByType(0x16)) // Service Data - 16-bit UUID
        {
            var data = section.Data.ToArray();
            if (data.Length < 2) continue;
            string uuid16 = $"{data[1]:X2}{data[0]:X2}"; // little-endian on the wire
            summary[$"serviceData.{uuid16}"] = Hex(data[2..]);
            if (Jbl.AdvertisedServiceIds.Contains(uuid16)) hasJblServiceData = true;
        }

        string advertisedName = ad.LocalName ?? "";
        ulong address = args.BluetoothAddress;
        int rssi = args.RawSignalStrengthInDBm;
        summary["name"] = advertisedName;
        summary["rssi"] = rssi.ToString();
        bool isJbl = pid is not null || hasJblServiceData || advertisedName.Contains("JBL", StringComparison.OrdinalIgnoreCase);
        Post(() => HandleSighting(sender, address, advertisedName, pid, rssi, summary, isJbl));
    }

    /// <summary>centralManager(_:didDiscover:advertisementData:rssi:) in the Mac app.</summary>
    private void HandleSighting(BluetoothLEAdvertisementWatcher source, ulong address, string advertisedName, ushort? pid,
        int rssi, Dictionary<string, string> summary, bool isJbl)
    {
        if (source != watcher) return; // a late event from a watcher already replaced
        var old = discovered.FirstOrDefault(s => s.Address == address);
        if (!isJbl && old is null) return;

        var speaker = new DiscoveredSpeaker { Address = address, Name = advertisedName, ProductId = pid, Rssi = rssi, Advertisement = summary };
        lastSeen[address] = DateTimeOffset.Now;
        if (old is not null)
        {
            speaker.ProductId = pid ?? old.ProductId;
            if (advertisedName.Length == 0) speaker.Name = old.Name;
        }

        // Our connected speaker also advertises under a fresh rotating address: not a second speaker.
        if (Status == SpeakerStatus.Connected && address != activeAddress && IsActiveSpeaker(speaker))
        {
            if (old is not null || !ignoredAliases.Contains(address))
            {
                Debug.WriteLine($"[ble] {speaker.Name} is also advertising as {address:X12}; same speaker");
                ignoredAliases.Add(address);
            }
            if (old is not null)
            {
                discovered.Remove(old);
                DiscoveredChanged();
            }
            return;
        }

        if (old is not null)
        {
            // Advertisement and scan response arrive separately; merge rather than lose fields.
            foreach (var kv in old.Advertisement) speaker.Advertisement.TryAdd(kv.Key, kv.Value);
            foreach (var kv in summary) speaker.Advertisement[kv.Key] = kv.Value;
            // Repeated advertisements mostly differ in signal strength; skip those to avoid redrawing.
            bool changed = old.Name != speaker.Name || old.ProductId != speaker.ProductId
                || !old.Advertisement.Where(kv => kv.Key != "rssi").OrderBy(kv => kv.Key)
                    .SequenceEqual(speaker.Advertisement.Where(kv => kv.Key != "rssi").OrderBy(kv => kv.Key));
            old.Rssi = rssi;
            if (changed)
            {
                discovered[discovered.IndexOf(old)] = speaker;
                DiscoveredChanged();
            }
        }
        else
        {
            Debug.WriteLine($"[ble] found {advertisedName} pid {pid ?? 0:X4}");
            discovered.Add(speaker);
            DiscoveredChanged();
        }
        // The same speaker seen earlier under an older address: keep only the newest sighting.
        if (discovered.RemoveAll(s => s.Address != address && s.Address != activeAddress && s.IsSameSpeaker(speaker)) > 0)
            DiscoveredChanged();

        // Auto-connect: the remembered speaker, or the first supported one when none is remembered.
        if (activeAddress is { } pending && pending != address
            && lastSeen.TryGetValue(pending, out var seen) && DateTimeOffset.Now - seen < TimeSpan.FromSeconds(5))
        {
            return; // still trying an address that's on air; don't flip-flop between aliases
        }
        if (!prefs.AutoConnect || Status == SpeakerStatus.Connected || activeAddress == address
            || speaker.Model is not { Support: not SupportLevel.Unsupported } model) return;
        if (IsRemembered(speaker) != false)
        {
            SetProductId(model.ProductId);
            Connect(address);
        }
    }

    /// <summary>Whether a sighting is the speaker we're already connected to, under another address.</summary>
    private bool IsActiveSpeaker(DiscoveredSpeaker s)
    {
        if (activeAddress is null) return false;
        var activeEntry = discovered.FirstOrDefault(d => d.Address == activeAddress);
        var candidates = new[] { Name, activeEntry?.Name, prefs.SavedSpeakerName }.OfType<string>();
        return candidates.Any(c => SpeakerIdentity.Matches(s.Name, s.ProductId, c, ProductId));
    }

    /// <summary>The remembered speaker, matched by advertised name and model (addresses rotate).</summary>
    private bool? IsRemembered(DiscoveredSpeaker s)
    {
        if (prefs.SavedSpeakerName is not { } savedName) return null;
        return SpeakerIdentity.Matches(s.Name, s.ProductId, savedName, prefs.SavedSpeakerProductId);
    }

    private void Remember(string? speakerName, ushort? pid, ulong address)
    {
        prefs.SavedSpeakerAddress = address;
        if (!string.IsNullOrEmpty(speakerName)) prefs.SavedSpeakerName = speakerName;
        if (pid is not null) prefs.SavedSpeakerProductId = pid;
    }

    // MARK: Connection

    private void Connect(ulong address)
    {
        if (activeAddress != address || device is not null)
        {
            connectAttempt++;
            Teardown();
        }
        activeAddress = address;
        Status = SpeakerStatus.Connecting;
        OnPropertyChanged(nameof(ConnectingName));
        if (discovered.FirstOrDefault(s => s.Address == address) is { } current
            && discovered.RemoveAll(s => s.Address != address && s.IsSameSpeaker(current)) > 0)
        {
            DiscoveredChanged();
        }
        Debug.WriteLine($"[ble] connecting to {address:X12}");
        _ = ConnectAsync(address, ++connectAttempt);
    }

    private async Task ConnectAsync(ulong address, int attempt)
    {
        _ = WatchdogAsync(address, attempt);
        try
        {
            device = await BluetoothLEDevice.FromBluetoothAddressAsync(address);
            if (attempt != connectAttempt) return;
            if (device is null)
            {
                Fail(attempt, "couldn't resolve the speaker from its address");
                return;
            }
            device.ConnectionStatusChanged += OnConnectionStatusChanged;

            // Keeps the link up while we hold it, instead of Windows dropping it when idle.
            session = await GattSession.FromDeviceIdAsync(device.BluetoothDeviceId);
            if (attempt != connectAttempt) return;
            session.MaintainConnection = true;

            var services = await device.GetGattServicesForUuidAsync(Guid.Parse(Jbl.ServiceUuid), BluetoothCacheMode.Uncached);
            if (attempt != connectAttempt) return;
            if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
            {
                Fail(attempt, $"control service not found ({services.Status})");
                return;
            }
            service = services.Services[0];

            var txResult = await service.GetCharacteristicsForUuidAsync(Guid.Parse(Jbl.WriteUuid), BluetoothCacheMode.Uncached);
            var rxResult = await service.GetCharacteristicsForUuidAsync(Guid.Parse(Jbl.NotifyUuid), BluetoothCacheMode.Uncached);
            if (attempt != connectAttempt) return;
            if (txResult.Characteristics.Count == 0 || rxResult.Characteristics.Count == 0)
            {
                Fail(attempt, "write/notify characteristics not found");
                return;
            }
            tx = txResult.Characteristics[0];
            rx = rxResult.Characteristics[0];

            rx.ValueChanged += OnValueChanged;
            var notify = await rx.WriteClientCharacteristicConfigurationDescriptorAsync(
                GattClientCharacteristicConfigurationDescriptorValue.Notify);
            if (attempt != connectAttempt) return;
            if (notify != GattCommunicationStatus.Success)
            {
                Fail(attempt, $"couldn't turn on notifications ({notify})");
                return;
            }

            Debug.WriteLine("[ble] control channel ready");
            if (!browsing) StopScan();
            var advertised = discovered.FirstOrDefault(s => s.Address == address);
            Remember(advertised?.Name, advertised?.ProductId ?? ProductId, address);
            GattSummary.Clear();
            decoder = new MessageDecoder();
            Status = SpeakerStatus.Connected;
            var requests = new List<byte[]> { Frame.RequestInfo.Encoded, Frame.RequestVersion.Encoded };
            if (Codec is { } codec) requests.AddRange(codec.ReadRequests());
            Enqueue(requests);
            pollTimer.Start();
            _ = Task.Delay(TimeSpan.FromSeconds(3)).ContinueWith(_ => Post(() =>
            {
                if (attempt == connectAttempt) RequestEqIfUnknown();
            }), TaskScheduler.Default);
        }
        catch (Exception ex)
        {
            Fail(attempt, $"connect failed: {ex.Message}");
        }
    }

    /// <summary>The presets stay disabled until the speaker reports its EQ; if that reply went missing
    /// (seen once on Windows: info answered, EQ not), ask again rather than wait for a notification.</summary>
    private void RequestEqIfUnknown()
    {
        if (Status == SpeakerStatus.Connected && Eq is null && Codec is { } codec) Enqueue(codec.ReadRequests());
    }

    /// <summary>A connect that hasn't finished in 10 s is abandoned and scanning resumes.</summary>
    private async Task WatchdogAsync(ulong address, int attempt)
    {
        await Task.Delay(TimeSpan.FromSeconds(10));
        if (attempt != connectAttempt || Status == SpeakerStatus.Connected || activeAddress != address) return;
        Fail(attempt, "connect stalled; rescanning");
    }

    private void Fail(int attempt, string reason)
    {
        if (attempt != connectAttempt) return;
        Debug.WriteLine($"[ble] {reason}");
        connectAttempt++;
        Teardown();
        activeAddress = null;
        Status = SpeakerStatus.Searching;
        Scan();
    }

    private void OnConnectionStatusChanged(BluetoothLEDevice sender, object args)
    {
        var state = sender.ConnectionStatus;
        Post(() =>
        {
            if (sender != device || state != BluetoothConnectionStatus.Disconnected || Status != SpeakerStatus.Connected) return;
            Debug.WriteLine("[ble] disconnected");
            ClearDeviceInfo();
            if (activeAddress is { } address) Connect(address);
            Scan();
        });
    }

    private void Teardown()
    {
        pollTimer.Stop();
        if (rx is not null) rx.ValueChanged -= OnValueChanged;
        if (device is not null) device.ConnectionStatusChanged -= OnConnectionStatusChanged;
        service?.Dispose();
        session?.Dispose();
        device?.Dispose();
        rx = null;
        tx = null;
        service = null;
        session = null;
        device = null;
        writeQueue.Clear();
        eqInFlight = false;
        eqNext = null;
        eqTimeout?.Cancel();
    }

    /// <summary>Forget what the last speaker reported, so none of it shows for whichever speaker connects next.</summary>
    private void ClearDeviceInfo()
    {
        Name = null;
        ColorCode = null;
        Battery = null;
        Charging = false;
        Firmware = null;
        Eq = null;
    }

    private void SetProductId(ushort pid)
    {
        if (ProductId == pid) return;
        ProductId = pid;
        if (Model is { } model && customGains.Length != model.CustomBands.Count)
        {
            customGains = new float[model.CustomBands.Count];
            OnPropertyChanged(nameof(CustomGains));
        }
    }

    /// <summary>Notifies once when the level drops to the threshold; re-arms after it recovers a little.</summary>
    private void BatteryChanged(int level, bool isCharging)
    {
        Battery = level;
        Charging = isCharging;
        if (isCharging || level > Notifier.LowBatteryThreshold + 5) lowBatteryNotified = false;
        if (isCharging || level > Notifier.LowBatteryThreshold || lowBatteryNotified || !prefs.LowBatteryAlert) return;
        lowBatteryNotified = true;
        Notifier.LowBattery(Name ?? Model?.Name ?? "JBL speaker", level);
    }

    // MARK: Writes

    private void Enqueue(List<byte[]> packets, bool eqWrite = false)
    {
        foreach (var p in packets) writeQueue.Enqueue(new Outgoing(p, eqWrite));
        Pump();
    }

    private async void Pump()
    {
        if (writing || tx is not { } characteristic || writeQueue.Count == 0) return;
        writing = true;
        try
        {
            while (writeQueue.Count > 0 && tx == characteristic)
            {
                var next = writeQueue.Dequeue();
                Record(Direction.Sent, next.Data);
                var result = await characteristic.WriteValueWithResultAsync(next.Data.AsBuffer(), GattWriteOption.WriteWithResponse);
                if (result.Status != GattCommunicationStatus.Success)
                    Debug.WriteLine($"[ble] write failed: {result.Status}");
                if (next.IsEqWrite && Codec is { WriteRepliesWithState: false } && !writeQueue.Any(o => o.IsEqWrite))
                {
                    // Acknowledged at the ATT layer; give the speaker a moment before reading back.
                    _ = Task.Delay(300).ContinueWith(_ => Post(EqWriteFinished), TaskScheduler.Default);
                }
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[ble] write error: {ex.Message}");
        }
        writing = false;
        if (tx is not null && writeQueue.Count > 0) Pump();
    }

    private void SendEq(List<byte[]> packets)
    {
        if (packets.Count == 0) return;
        if (eqInFlight)
        {
            eqNext = packets;
            return;
        }
        eqInFlight = true;
        Enqueue(packets, eqWrite: true);
        eqTimeout?.Cancel();
        var cts = new CancellationTokenSource();
        eqTimeout = cts;
        _ = Task.Delay(TimeSpan.FromSeconds(2), cts.Token).ContinueWith(t =>
        {
            if (!t.IsCanceled) Post(EqWriteFinished);
        }, TaskScheduler.Default);
    }

    private void EqWriteFinished()
    {
        eqTimeout?.Cancel();
        if (!eqInFlight) return;
        eqInFlight = false;
        if (eqNext is { } next)
        {
            eqNext = null;
            SendEq(next);
        }
        else if (Codec is { WriteRepliesWithState: false } codec)
        {
            // These families acknowledge without state; read it back to confirm.
            Enqueue(codec.ReadRequests());
        }
    }

    // MARK: Incoming

    private void OnValueChanged(GattCharacteristic sender, GattValueChangedEventArgs args)
    {
        byte[] bytes = args.CharacteristicValue.ToArray();
        Post(() =>
        {
            if (sender != rx) return;
            Record(Direction.Received, bytes);
            foreach (var message in decoder.Feed(bytes)) Handle(message);
        });
    }

    private void Handle(Incoming message)
    {
        if (Codec is { } codec && codec.Parse(message) is { } snapshot)
        {
            bool superseded = eqNext is not null;
            if (eqInFlight) EqWriteFinished();
            // A reply to an older write would undo a newer optimistic change; wait for the last one.
            if (!superseded)
            {
                if (snapshot.Gains is { } gains)
                {
                    customGains = gains.ToArray();
                    OnPropertyChanged(nameof(CustomGains));
                }
                Eq = new EQSnapshot(snapshot.ActiveCategory, customGains.ToArray());
            }
            return;
        }
        if (message is not Incoming.Legacy { Value: var frame }) return;
        switch ((Command)frame.CommandByte)
        {
            case Command.Info:
                switch (InfoToken.Parse(frame.Payload))
                {
                    case InfoToken.Name n: Name = n.Value; break;
                    case InfoToken.ProductId p: SetProductId(p.Value); break;
                    case InfoToken.Color c: ColorCode = c.Value; break;
                    case InfoToken.Battery b: BatteryChanged(b.Level, b.Charging); break;
                    case InfoToken.Firmware f: Firmware = f.Value; break;
                }
                break;
            case Command.Version:
                Firmware = FirmwareVersion.Format(frame.Payload);
                break;
            case Command.NotifyEqChange:
                if (Codec is { } c2) Enqueue(c2.ReadRequests());
                break;
            case Command.Unsupported:
                byte rejected = frame.Payload.Length > 0 ? frame.Payload[0] : (byte)0;
                Debug.WriteLine($"[ble] speaker rejected command 0x{rejected:X2}");
                if (rejected == (byte)Command.SetAdvancedEq || rejected == 0x6E) EqWriteFinished();
                break;
        }
    }

    // MARK: Diagnostics

    private void Record(Direction direction, byte[] data)
    {
        traffic.Add(new TrafficEntry(DateTimeOffset.Now, direction, data));
        if (traffic.Count > 200) traffic.RemoveRange(0, traffic.Count - 200);
    }

    /// <summary>Sends every read-only request we know of, so the report shows how this speaker answers.</summary>
    public async Task RunDiagnosticProbeAsync()
    {
        if (Status != SpeakerStatus.Connected) return;
        if (GattSummary.Count == 0 && device is not null) await DescribeGattAsync(device);
        var requests = new List<byte[]>
        {
            Frame.RequestInfo.Encoded, Frame.RequestVersion.Encoded, new Frame(0x61).Encoded,
            new Frame(0x6C, new byte[] { 0x00 }).Encoded, Frame.RequestEq.Encoded,
        };
        requests.AddRange(P4Message.Set(new[] { (P4EQ.Query, new byte[] { 0xFF }) }).Packets);
        Enqueue(requests);
        await Task.Delay(TimeSpan.FromSeconds(3));
    }

    /// <summary>Every service and characteristic, like the Mac app collects during discovery (done lazily here
    /// to keep connecting fast).</summary>
    private async Task DescribeGattAsync(BluetoothLEDevice d)
    {
        try
        {
            var services = await d.GetGattServicesAsync(BluetoothCacheMode.Cached);
            foreach (var s in services.Services)
            {
                GattSummary.Add($"service {s.Uuid.ToString().ToUpperInvariant()}");
                var chars = await s.GetCharacteristicsAsync(BluetoothCacheMode.Cached);
                foreach (var c in chars.Characteristics)
                    GattSummary.Add($"  char {c.Uuid.ToString().ToUpperInvariant()} props=0x{(uint)c.CharacteristicProperties:x}");
            }
        }
        catch (Exception ex)
        {
            GattSummary.Add($"(couldn't read GATT: {ex.Message})");
        }
    }

    public Dictionary<string, string> CurrentAdvertisement =>
        discovered.FirstOrDefault(s => s.Address == activeAddress)?.Advertisement ?? new();

    public static string Hex(byte[] data) => string.Join(" ", data.Select(b => b.ToString("X2")));

    public ValueTask DisposeAsync()
    {
        connectAttempt++;
        pruneTimer.Stop();
        StopScan();
        Teardown();
        return ValueTask.CompletedTask;
    }
}
