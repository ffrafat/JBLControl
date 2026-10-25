# Windows port of JBLControl (WinUI 3 / Fluent)

## Context

JBLControl is a macOS menu-bar app that talks directly to JBL portable Bluetooth
speakers over BLE GATT (no phone, no JBL app). The protocol work — two frame
generations, five EQ encoding families, a 37-model catalog, address-rotation
identity matching — is fully reverse-engineered, implemented in the
`JBLControlKit` Swift package, and pinned by byte-exact unit tests against real
hardware captures. The goal now is a **separate Windows 11 app with full feature
parity**, built with C# + WinUI 3 so it can use Mica/Acrylic and the current
Fluent Design System, living in the same repo so both platforms share docs,
protocol notes, and (eventually) one GitHub Release per version.

Decisions already made: C# + WinUI 3; new `windows/` folder in this repo;
protocol/catalog logic **ported** to an equivalent C# library (not interop) and
verified against the same hex fixtures; v1 ships full parity (EQ, Keep Awake,
diagnostics, settings) rather than a cut-down first pass.

## Status (2026-10-25)

- ✅ **Phase 0** — solution/project scaffolding. `windows/JBLControl.Windows.slnx`
  (the SDK now defaults to the `.slnx` XML format, not `.sln`) with three
  projects.
- ✅ **Phase 1** — `JBLControlKit.Windows` is a complete file-for-file port of
  `JBLControlKit` (frame codecs, EQ math, 37-model catalog). `scripts/generate-catalog.py`
  extended to emit the C# catalog alongside the Swift one from the same openjbl
  source data (untested against a real openjbl checkout — worth a dry run before
  the next catalog refresh). **29/29** tests passing in `JBLControlKit.Windows.Tests`
  (mirrors every Swift test byte-for-byte, including the Charge 5 hardware
  captures from issue #1).
- 🚧 **Phase 2 in progress** — `JBLControl.Windows` is currently a **console**
  harness (`SpeakerManager.cs`, plain methods, not yet `ObservableObject`) using
  `Windows.Devices.Bluetooth` to scan/connect/stream info+EQ to stdout. Builds
  clean and runs against real Bluetooth hardware (confirmed: `BluetoothLEAdvertisementWatcher`
  starts without error, no permission prompts on this machine). **Verified
  against a real JBL Flip 7** (PID `0x2107`, firmware 0.7.2.0) on a second
  Windows 11 machine (Intel Wireless Bluetooth): discovered as Verified,
  connected with **no pairing/bonding prompt**, and read name, product ID,
  color, battery, firmware and EQ state (`active=0x03`, 7 bands) correctly.
  Known nit: the `Firmware:` line prints twice per connect — likely two info
  responses each carrying the firmware token; dedupe before this output feeds
  the UI. Remaining Phase 2 work: reconnect handling and multi-speaker/address-rotation
  dedup (§2). The TFM
  (`net8.0-windows10.0.19041.0`) was adopted here already rather than deferred
  to Phase 4.
- ⬜ Phases 3–7 not started.

To resume: `cd windows && dotnet test JBLControl.Windows.slnx` should show
29/29 passing. Then turn a JBL speaker on nearby and
`dotnet run --project JBLControl.Windows/JBLControl.Windows.csproj` to continue
Phase 2 work.

New-machine setup: .NET 10 SDK (reads `.slnx`, builds the `net8.0` targets)
plus the .NET 8 runtime. If Windows 11 **Smart App Control** is on, it blocks
the unsigned local build outputs ("An Application Control policy has blocked
this file") — both the test DLL and the harness exe — so it has to be off on
a dev machine.

## 1. Project layout

New `windows/` folder, sibling to `Sources/`, `Tests/`, `docs/`, `scripts/`.
SwiftPM only does convention-based discovery under `Sources/`/`Tests/`, so
**nothing in `Package.swift` needs to change**.

```
windows/
  JBLControl.Windows.slnx
  Directory.Build.props
  JBLControlKit.Windows/            # class library, mirrors Sources/JBLControlKit
    JBLProtocol.cs  Protocol4.cs  EQ.cs  EQCodec.cs  Models.cs  Catalog.Generated.cs
  JBLControlKit.Windows.Tests/      # xunit, mirrors Tests/JBLControlKitTests
    ProtocolTests.cs  CodecTests.cs  TestFixtures.cs
  JBLControl.Windows/               # console harness today; WinUI 3 app from Phase 4
    Program.cs  SpeakerManager.cs
    # Phase 4 additions (not yet present):
    App.xaml(.cs)  KeepAwakeService.cs  DiagnosticsReport.cs  TrayIconController.cs
    Preferences.cs  UpdateChecker.cs  LoginItem.cs  PhotoStore.cs  AppInfo.cs
    Views/
      MainFlyoutPage.xaml(.cs)      # ← PanelView.swift
      HeaderView.xaml(.cs)          # ← HeaderView.swift
      EqualizerView.xaml(.cs) + EqResponseCurve.cs (Win2D)
      PresetPicker.xaml(.cs)  SpeakerSwitcher.xaml(.cs)  SearchingView.xaml(.cs)
      SpeakerArtwork.xaml(.cs)      # ← SpeakerArtwork.swift (see §5)
      SettingsWindow.xaml(.cs)      # ← SettingsView.swift
    Styles/Shared.xaml
```

Add `windows/**/bin,obj` and `windows/build/` to `.gitignore` (done).
`scripts/build-windows.ps1` sits next to `scripts/build-app.sh` (not yet written).

## 2. BLE layer (Windows.Devices.Bluetooth)

- **Discovery**: `BluetoothLEAdvertisementWatcher`, `ScanningMode.Active`.
  Windows fires advertisement and scan-response as separate `Received` events
  (`AdvertisementType == ScanResponse`) — mirror the Mac app's own "merge
  rather than lose fields" handling in `didDiscover`. OS-level
  `AdvertisementFilter.ServiceUuids` won't match JBL's service-*data* keys
  (FDDF/FC69/DFFD), so filter manually per event exactly like today:
  `Advertisement.ManufacturerData` (company `0x0057`, PID from first 2 bytes —
  ported as `Jbl.ProductId`), `GetSectionsByType(0x16)` for service data, and
  the `LocalName` "contains JBL" fallback. **Done** in `SpeakerManager.cs`,
  minus the advertisement/scan-response merge nuance and silent-speaker pruning
  (single-speaker connect only so far).
- **Identity**: key discovered speakers by `args.BluetoothAddress` (a raw
  `UInt64`, unlike `CBPeripheral.identifier`'s OS-hidden UUID).
  `SpeakerIdentity.Matches` is ported in the library; the manager-level
  `isSameSpeaker` / `isActiveSpeaker` / `pruneSilentSpeakers` dedup logic is
  **not yet ported** (Phase 2 remainder — needed once more than one speaker
  or address rotation shows up in testing).
- **Connect**: `BluetoothLEDevice.FromBluetoothAddressAsync`, then
  `GetGattServicesForUuidAsync(serviceUuid, BluetoothCacheMode.Uncached)` →
  `GetCharacteristicsForUuidAsync(..., Uncached)` for write/notify chars. **Done.**
- **Notify**: `GattCharacteristic.WriteClientCharacteristicConfigurationDescriptorAsync(Notify)`
  then `characteristic.ValueChanged += ...`. **Must hold strong references**
  to the whole `BluetoothLEDevice → GattDeviceService → GattCharacteristic`
  chain for the connection's lifetime — a known WinRT pitfall is notifications
  silently stopping if any link gets collected. **Done**, fields held on the manager.
- **Write**: `WriteValueWithResultAsync(buffer, GattWriteOption.WriteWithResponse)`.
  A basic async queue is in place; the Swift app's EQ-write coalescing
  (`eqInFlight`/`eqNext`, one write per round trip while dragging a slider) is
  **not yet ported** — needed before Phase 3 EQ writes feel responsive.
- **Disconnect**: `BluetoothLEDevice.ConnectionStatusChanged` reconnect handling
  is **not yet ported** (current harness connects once and doesn't retry).
- No appxmanifest capability needed for an unpackaged exe — just the user's
  Bluetooth toggle + radio on. No pairing/bonding needed for the Flip 7
  (verified on real hardware); still unconfirmed for other models.

## 3. Protocol/catalog C# library — ✅ done (Phase 1)

File-for-file port, same types, idiomatic C# substitutions where Swift has no
equivalent (closed `record` hierarchies for `InfoToken`/`Incoming` instead of
enums-with-associated-values; explicit lowerCamel-parameter constructors
instead of record positional syntax, to avoid a named-argument casing trap
with Swift-style `q:`/`category:` call sites):

| Swift | C# |
|---|---|
| `JBLProtocol.swift` | `JBLProtocol.cs` — `Frame`, `FrameDecoder`, `InfoToken` record hierarchy, `FirmwareVersion.Format` |
| `Protocol4.swift` | `Protocol4.cs` — `P4Message`, `Incoming` record hierarchy, `MessageDecoder` |
| `EQ.swift` | `EQ.cs` — `EQBand`, `EQState.TryParse`, `EQResponse.Gain` (same RBJ biquad formulas) |
| `EQCodec.swift` | `EQCodec.cs` — `EQSnapshot`, per-family dispatch, `P4EQ` step tables |
| `Models.swift` | `Models.cs` — enums, `SpeakerModel`, `EQLayouts`, `Catalog`, `SpeakerIdentity` |
| `Catalog+Generated.swift` | `Catalog.Generated.cs` — generated |

**Catalog generation**: `scripts/generate-catalog.py` now has a
`csharp_presets`/C# emission path alongside the Swift one, called from the
same `main()`, writing both `Sources/JBLControlKit/Catalog+Generated.swift`
and `windows/JBLControlKit.Windows/Catalog.Generated.cs` from one openjbl
checkout. **Not yet dry-run against real openjbl JSON** — do that before
trusting it over hand-editing.

## 4. App-side architecture (SpeakerManager equivalent)

Target: port `SpeakerManager.swift` to `SpeakerManager : ObservableObject`
(CommunityToolkit.Mvvm), bindable for WinUI 3. **Current state**: `SpeakerManager.cs`
is plain C# with public properties and `Console.WriteLine`, built for Phase 2
BLE verification, not yet wired to any UI framework.

Key porting detail still ahead: Swift's `@MainActor` auto-hops BLE delegate
callbacks onto the main run loop; **WinRT events fire on background/COM threads
with no automatic hop**, so once a UI exists, every state mutation from
`watcher.Received`, `characteristic.ValueChanged`, `device.ConnectionStatusChanged`
must be explicitly re-dispatched via a captured `DispatcherQueue.TryEnqueue(...)`.
Not an issue yet since the console harness has no UI thread to protect.

Port the connect watchdog, 60s info poll, and silent-speaker pruning as
`Task`s with `PeriodicTimer` + `CancellationTokenSource` (not yet done — see §2).

MVVM target: bind XAML directly to `SpeakerManager` via `x:Bind`, no separate
ViewModel layer, matching the Swift app. Register `SpeakerManager`,
`KeepAwakeService`, `Preferences`, `UpdateChecker` as singletons via
`Microsoft.Extensions.DependencyInjection` in `App.xaml.cs` (Phase 4).

## 5. UI architecture (Phase 4, not started)

- **Tray icon**: WinUI 3 has no first-party tray support. Use
  **H.NotifyIcon.WinUI** (`TaskbarIcon` control) rather than hand-rolled
  `Shell_NotifyIconW` P/Invoke. Biggest new third-party dependency — spike first.
- **Popover equivalent**: a secondary borderless `Window`
  (`OverlappedPresenter`, non-resizable, `ExtendsContentIntoTitleBarArea`).
  Unlike `NSPopover`, it won't auto-size to content — call
  `AppWindow.ResizeClient(...)` on layout changes. Position via the tray icon's
  rect; dismiss on deactivate, falling back to `WS_EX_NOACTIVATE`/`WS_EX_TOOLWINDOW`
  HWND tweaks if that's unreliable.
- **Material**: `DesktopAcrylicBackdrop` for the flyout, `MicaBackdrop` for
  Settings. Collapse `AdaptiveGlass.swift`'s per-OS-material abstraction into a
  couple of shared `Style` resources (`PillBorderStyle`, `ChipButtonStyle`) in
  `Styles/Shared.xaml`. Icons via `FontIcon FontFamily="Segoe Fluent Icons"`.
- **View mapping**: `PanelView`→`MainFlyoutPage`, `HeaderView`→`HeaderView`,
  `PresetPicker`/`SpeakerSwitcher`→`ItemsRepeater`-based controls,
  `SearchingView`→direct port, `SettingsView`→`SettingsWindow` with a `TabView`
  (General/Speaker/Updates/About) on Mica.
- **EqualizerView**: each vertical band as a custom `UserControl` using raw
  `PointerPressed/Moved/Released` on a `Grid` (not a rotated `Slider`). The
  response curve as a **Win2D `CanvasControl`** (`EqResponseCurve`), since it
  resamples `EQResponse.Gain` across log-frequency on every drag frame.
- **SpeakerArtwork**: the Swift version draws vector silhouettes (`Capsule`,
  `RoundedRectangle`, `Circle` with gradient fills, grille texture, highlight)
  per form factor, falling back from a cached JBL.com photo. Maps directly to
  plain XAML shapes (`Rectangle` with `RadiusX/Y`, `Ellipse`) with
  `LinearGradientBrush` fills — no Win2D needed here. Port `PhotoStore`'s
  cache-to-`%LOCALAPPDATA%` + fetch logic with `HttpClient`/`StorageFolder`.

## 6. Keep Awake (Windows audio) — Phase 5, not started

- **Default output + name**: NAudio `MMDeviceEnumerator.GetDefaultAudioEndpoint
  (DataFlow.Render, Role.Multimedia).FriendlyName` — direct analog of
  `kAudioHardwarePropertyDefaultOutputDevice`/`...PropertyName`. 30s poll
  (`PeriodicTimer`), matching the existing architecture.
- **Match**: port `isSpeaker(deviceName)` verbatim (prefix match either way,
  else case-insensitive "JBL" substring).
- **Tone**: NAudio `WasapiOut` against the **specific** `MMDevice` found above.
  Port `TonePlayer`'s exact signal (2s, 30Hz, amplitude 0.01 ≈ −40dBFS, 0.25s
  fades) as a small `ISampleProvider`. Dispose the `WasapiOut`+provider after
  each ping. Same `KeepAwakeState { Off, WaitingForOutput, Active }` state machine.

## 7. Settings, startup, updates — Phase 6, not started

- **Launch at login**: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
  registry value pointing at the published exe (matches the Mac app's
  unsigned/unpackaged distribution; MSIX + `StartupTask` would require
  packaging, out of scope for now). No "needs approval" state to model.
- **Low battery**: Windows App SDK `AppNotificationManager.Register()` +
  `AppNotificationBuilder` (works unpackaged since WinAppSDK 1.2+).
- **Update checker**: same `api.github.com/repos/ffrafat/JBLControl/releases/latest`
  endpoint, `HttpClient` + `System.Text.Json`, `isNewer` ported verbatim.
  **Gotcha**: must set `request.Headers.UserAgent` explicitly — GitHub 403s
  requests with no User-Agent, which Swift's `URLSession` sets automatically
  but .NET's `HttpClient` does not. Ship Windows builds as extra assets on the
  **same** GitHub Release (`JBLControl-win-x64-<version>.zip`, `-win-arm64-...`)
  so one version number spans both platforms.
- **Preferences**: default to a plain JSON file at
  `%LOCALAPPDATA%\JBLControl\settings.json` (simpler, no packaging-identity
  ambiguity than `ApplicationData.Current.LocalSettings` under an unpackaged identity).

## 8. Diagnostics report — Phase 7, not started

Port `Diagnostics.build(speaker)` into `DiagnosticsReport.cs` with the
identical Markdown structure (app/OS version, model/status/firmware/battery/EQ
lines, nearby-advertisements block, GATT block, traffic block with `→`/`←`
arrows and the same timestamp formatting). Port the redaction rule
byte-for-byte: `data[0]==0xAA && data[1]==0x12 && (data[4]==0x48 ||
data[4]==0xC2)` → zero from index 5 on. Clipboard via
`Windows.ApplicationModel.DataTransfer.Clipboard.SetContent`.

## 9. Testing — ✅ done for Phase 1, extend as later phases land

`JBLControlKit.Windows.Tests` (xunit, plain `net8.0`, no WinRT dependency).
Mirrors every Swift test 1:1 as a `[Fact]`/`[Theory]` (currently 29, including
the Charge 5 hardware captures from issue #1), copying the exact hex fixtures
into `TestFixtures.cs` with a `Bytes(string hex)` helper matching Swift's
`bytes(_:)`. A `windows-ci.yml` GitHub Actions workflow running `dotnet test`
alongside the existing `swift test` gate is **not yet added**.

## 10. Build & distribution — Phase 7, not started

`scripts/build-windows.ps1`, mirroring `build-app.sh`'s flag style:
1. `dotnet publish ... -r win-x64 --self-contained true -p:PublishReadyToRun=true`,
   repeated for `win-arm64` (two self-contained outputs; .NET has no
   multi-arch fat binary the way Mach-O does).
2. `Compress-Archive` each + `Get-FileHash -Algorithm SHA256`, matching the
   Mac script's `ditto`+`shasum` step.
3. No MSIX for v1 (deliberately unpackaged, matching the Mac app).
4. Leave unsigned — SmartScreen's "Windows protected your PC" is the Windows
   analog of Gatekeeper's warning; document the bypass later in a parallel README section.
5. `-Install` copies to `%LOCALAPPDATA%\Programs\JBLControl\`; `-Run` restarts
   the published exe (killing any previous instance by process name first).

## 11. Phasing

0. ✅ Solution/project scaffolding, CI skeleton.
1. ✅ Protocol/catalog library + full xunit port, catalog-generator extension.
2. 🚧 Bare BLE connect + live battery/info display — harness built and
   **verified against a real Flip 7**; reconnect/dedup logic next.
3. ⬜ EQ read/write through `EQCodec`, including the write-coalescing queue.
4. ⬜ Tray icon + borderless flyout shell + full XAML view port + Win2D curve +
   Fluent styling pass.
5. ⬜ Keep Awake (NAudio device polling + tone).
6. ⬜ Settings window, Run-key login item, low-battery toast, update checker.
7. ⬜ Diagnostics report, `build-windows.ps1` packaging, SmartScreen smoke test,
   Windows README section.

## 12. Risks / open questions

1. Tray icon (H.NotifyIcon.WinUI) screen-rect queries are known to be
   inconsistent, especially with the taskbar overflow tray — spike early in Phase 4.
2. Borderless-flyout dismiss-on-blur isn't guaranteed the way
   `NSPopover.transient` is; may need HWND style tweaks.
3. BLE address rotation is structurally different on Windows (raw address vs.
   OS-hidden UUID) — verify empirically against a real rotating-address model
   (Go5/Xtreme5); the Mac app's verified behavior is currently Flip-7/Charge-5/Charge-6-centric.
4. Confirm Windows' GATT stack doesn't require pairing/bonding that macOS
   doesn't — **confirmed not needed for the Flip 7**; other models untested.
5. Mica/Acrylic need WinAppSDK 1.3+, most reliable on Windows 11 22H2+; falls
   back to solid color on older builds (no crash risk).
6. `GattCharacteristic.ValueChanged` can silently stop firing if any object in
   the device→service→characteristic chain is garbage-collected — keep
   explicit strong references for the connection's lifetime (done so far).

## Verification

- Phase 1: `dotnet test` in `windows/` reproduces all ported fixtures green. **Passing.**
- Phase 2+: run the app against a real JBL speaker and confirm battery/model/color
  appear and update live. **Done for the Flip 7** (initial read confirmed;
  live updates over a longer session not yet observed).
- Phase 3: drag the custom EQ sliders against real hardware and confirm the
  speaker's state (read back via `AA 98`/`0E01` query) matches what was sent,
  same as the Swift round-trip tests assert.
- Phase 4+: visual check against Windows 11 with Mica/Acrylic enabled, and
  with "transparency effects" disabled in Settings (should fall back
  gracefully, not crash).
- Full parity pass: run through the Mac README's feature list end-to-end on
  Windows before calling v1 done.
