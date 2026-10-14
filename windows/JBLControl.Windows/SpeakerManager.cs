using System.Runtime.InteropServices.WindowsRuntime;
using JBLControlKit.Windows;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;

namespace JBLControl.Windows;

/// <summary>A JBL speaker seen advertising nearby, keyed by its (rotating) BLE address.</summary>
public sealed class DiscoveredSpeaker
{
    public required ulong BluetoothAddress { get; init; }
    public string Name { get; set; } = "";
    public ushort? ProductId { get; set; }
    public short Rssi { get; set; }
    public DateTimeOffset LastSeen { get; set; }
    public SpeakerModel? Model => Catalog.Model(ProductId);
}

/// <summary>
/// Owns the BLE link to one JBL speaker. Phase 2 scope: scan, connect, enable notifications,
/// print info/EQ as it arrives. Ported from the shape of Sources/JBLControl/SpeakerManager.swift,
/// trimmed to console output — reconnect watchdogs, the full write-coalescing queue, and UI
/// bindings land in Phase 4 once this is proven against real hardware.
/// </summary>
public sealed class SpeakerManager : IAsyncDisposable
{
    private readonly BluetoothLEAdvertisementWatcher watcher = new() { ScanningMode = BluetoothLEScanningMode.Active };
    private readonly Dictionary<ulong, DiscoveredSpeaker> discovered = new();
    private readonly MessageDecoder decoder = new();
    private readonly Queue<byte[]> writeQueue = new();
    private readonly object writeLock = new();
    private bool writing;
    private bool connecting;

    private BluetoothLEDevice? device;
    private GattDeviceService? service;
    private GattCharacteristic? tx;
    private GattCharacteristic? rx;

    public ushort? ProductId { get; private set; }
    public string? Name { get; private set; }
    public byte? ColorCode { get; private set; }
    public int? Battery { get; private set; }
    public bool Charging { get; private set; }
    public string? Firmware { get; private set; }

    private SpeakerModel? Model => Catalog.Model(ProductId);
    private EQCodec? Codec => Model is { } m ? new EQCodec(m) : null;

    public void Start()
    {
        watcher.Received += OnAdvertisementReceived;
        watcher.Start();
        Console.WriteLine("Scanning for JBL speakers... (Ctrl+C to quit)");
    }

    private void OnAdvertisementReceived(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementReceivedEventArgs args)
    {
        var ad = args.Advertisement;

        ushort? pid = null;
        foreach (var m in ad.ManufacturerData)
        {
            var bytes = new byte[2 + m.Data.Length];
            bytes[0] = (byte)(m.CompanyId & 0xFF);
            bytes[1] = (byte)(m.CompanyId >> 8);
            m.Data.ToArray().CopyTo(bytes, 2);
            pid = Jbl.ProductId(bytes);
            if (pid is not null) break;
        }

        bool hasJblServiceData = false;
        foreach (var section in ad.GetSectionsByType(0x16)) // Service Data - 16-bit UUID
        {
            var data = section.Data.ToArray();
            if (data.Length < 2) continue;
            string uuid16 = $"{data[1]:X2}{data[0]:X2}"; // little-endian on the wire
            if (Jbl.AdvertisedServiceIds.Contains(uuid16)) { hasJblServiceData = true; break; }
        }

        string name = ad.LocalName ?? "";
        bool alreadyTracked = discovered.ContainsKey(args.BluetoothAddress);
        bool looksLikeJbl = pid is not null || hasJblServiceData || name.Contains("JBL", StringComparison.OrdinalIgnoreCase);
        if (!looksLikeJbl && !alreadyTracked) return;

        if (!discovered.TryGetValue(args.BluetoothAddress, out var speaker))
        {
            speaker = new DiscoveredSpeaker { BluetoothAddress = args.BluetoothAddress };
            discovered[args.BluetoothAddress] = speaker;
        }
        if (!string.IsNullOrEmpty(name)) speaker.Name = name;
        if (pid is not null) speaker.ProductId = pid;
        speaker.Rssi = args.RawSignalStrengthInDBm;
        speaker.LastSeen = DateTimeOffset.Now;

        if (!connecting && device is null && speaker.Model is { Support: not SupportLevel.Unsupported } model)
        {
            connecting = true;
            Console.WriteLine($"Found '{speaker.Name}' ({model.Name}, {model.Support.Label()}), connecting...");
            _ = ConnectAsync(speaker);
        }
    }

    private async Task ConnectAsync(DiscoveredSpeaker speaker)
    {
        try
        {
            watcher.Stop();
            ProductId = speaker.ProductId;

            device = await BluetoothLEDevice.FromBluetoothAddressAsync(speaker.BluetoothAddress);
            if (device is null)
            {
                Console.WriteLine("Connect failed: could not resolve the device from its BLE address.");
                return;
            }

            var servicesResult = await device.GetGattServicesForUuidAsync(Guid.Parse(Jbl.ServiceUuid), BluetoothCacheMode.Uncached);
            if (servicesResult.Status != GattCommunicationStatus.Success || servicesResult.Services.Count == 0)
            {
                Console.WriteLine($"GATT service discovery failed: {servicesResult.Status}");
                return;
            }
            service = servicesResult.Services[0];

            var txResult = await service.GetCharacteristicsForUuidAsync(Guid.Parse(Jbl.WriteUuid), BluetoothCacheMode.Uncached);
            var rxResult = await service.GetCharacteristicsForUuidAsync(Guid.Parse(Jbl.NotifyUuid), BluetoothCacheMode.Uncached);
            if (txResult.Characteristics.Count == 0 || rxResult.Characteristics.Count == 0)
            {
                Console.WriteLine("Write/notify characteristics not found under the JBL control service.");
                return;
            }
            tx = txResult.Characteristics[0];
            rx = rxResult.Characteristics[0];

            rx.ValueChanged += OnValueChanged;
            var notifyStatus = await rx.WriteClientCharacteristicConfigurationDescriptorAsync(
                GattClientCharacteristicConfigurationDescriptorValue.Notify);
            if (notifyStatus != GattCommunicationStatus.Success)
            {
                Console.WriteLine($"Failed to enable notifications: {notifyStatus} "
                    + "(if this persists, the speaker may be requiring pairing Windows' GATT stack doesn't need on macOS).");
                return;
            }

            Console.WriteLine("Connected. Requesting info and EQ state...");
            Enqueue(Frame.RequestInfo.Encoded);
            Enqueue(Frame.RequestVersion.Encoded);
            if (Codec is { } codec) foreach (var r in codec.ReadRequests()) Enqueue(r);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Connect failed: {ex.Message}");
        }
    }

    private void OnValueChanged(GattCharacteristic sender, GattValueChangedEventArgs args)
    {
        byte[] bytes = args.CharacteristicValue.ToArray();
        foreach (var message in decoder.Feed(bytes)) Handle(message);
    }

    private void Handle(Incoming message)
    {
        if (Codec is { } codec && codec.Parse(message) is { } snapshot)
        {
            string gains = snapshot.Gains is null ? "-" : string.Join(", ", snapshot.Gains.Select(g => g.ToString("+0.0;-0.0;0")));
            Console.WriteLine($"EQ: active=0x{snapshot.ActiveCategory:X2} gains=[{gains}]");
            return;
        }
        if (message is not Incoming.Legacy { Value: var frame }) return;
        switch ((Command)frame.CommandByte)
        {
            case Command.Info:
                switch (InfoToken.Parse(frame.Payload))
                {
                    case InfoToken.Name n:
                        Name = n.Value;
                        Console.WriteLine($"Name: {Name}");
                        break;
                    case InfoToken.ProductId p:
                        ProductId = p.Value;
                        Console.WriteLine($"Product ID: 0x{p.Value:X4} ({Model?.Name ?? "unknown model"})");
                        break;
                    case InfoToken.Color c:
                        ColorCode = c.Value;
                        Console.WriteLine($"Color: {Model?.Color(c.Value).Name ?? $"0x{c.Value:X2}"}");
                        break;
                    case InfoToken.Battery b:
                        Battery = b.Level;
                        Charging = b.Charging;
                        Console.WriteLine($"Battery: {b.Level}%{(b.Charging ? " (charging)" : "")}");
                        break;
                    case InfoToken.Firmware f:
                        Firmware = f.Value;
                        Console.WriteLine($"Firmware: {f.Value}");
                        break;
                }
                break;
            case Command.Version:
                Firmware = FirmwareVersion.Format(frame.Payload);
                Console.WriteLine($"Firmware: {Firmware}");
                break;
            case Command.Unsupported:
                Console.WriteLine($"Speaker rejected command 0x{(frame.Payload.Length > 0 ? frame.Payload[0] : 0):X2}");
                break;
        }
    }

    private void Enqueue(byte[] data)
    {
        lock (writeLock) writeQueue.Enqueue(data);
        _ = PumpAsync();
    }

    private async Task PumpAsync()
    {
        lock (writeLock)
        {
            if (writing || tx is null) return;
            writing = true;
        }
        try
        {
            while (true)
            {
                byte[]? data;
                lock (writeLock)
                {
                    if (writeQueue.Count == 0) { writing = false; return; }
                    data = writeQueue.Dequeue();
                }
                var result = await tx!.WriteValueWithResultAsync(data.AsBuffer(), GattWriteOption.WriteWithResponse);
                if (result.Status != GattCommunicationStatus.Success)
                    Console.WriteLine($"Write failed: {result.Status}");
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Write error: {ex.Message}");
            lock (writeLock) writing = false;
        }
    }

    public async ValueTask DisposeAsync()
    {
        watcher.Received -= OnAdvertisementReceived;
        watcher.Stop();
        if (rx is not null) rx.ValueChanged -= OnValueChanged;
        service?.Dispose();
        device?.Dispose();
        await Task.CompletedTask;
    }
}
