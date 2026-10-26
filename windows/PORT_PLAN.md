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
- ✅ **Phase 2** — BLE connect + live info, **verified against a real JBL Flip 7**
  (PID `0x2107`, firmware 0.7.2.0) on Windows 11 with Intel Wireless Bluetooth:
  connects with **no pairing/bonding prompt**. Reconnect, the connect watchdog,
  multi-speaker switching, address-rotation dedup, silent-speaker pruning and the
  remembered speaker are ported from `SpeakerManager.swift`.
- ✅ **Phase 3** — EQ through `EQCodec` with the write-coalescing queue. Preset
  writes confirmed on the Flip 7 (written, then read back after a reconnect).
  Custom-slider writes on hardware **not yet confirmed**.
- ✅ **Phase 4** — WinUI 3 app (a different shell from §5's original plan, see
  below): main window, tray icon, tray flyout, shared `SpeakerPanel` control.
- ✅ **Phase 5** — Keep Awake (built, **not yet confirmed** to stop an auto power-off).
- ✅ **Phase 6** — Settings, launch at login, low-battery toast, update checker
  (the check works against GitHub; the toasts are untested on screen).
- ✅ **Phase 7** — diagnostics report, `scripts/build-windows.ps1` (self-contained
  x64 + arm64 builds; `-Installer` for branded Inno Setup installers, `-Zip` for
  portable zips, SHA-256 for both), README, `.github/workflows/windows.yml`
  (build + test on push, installers and zips on `v*` tags).
- ✅ **Installer** (`windows/Installer/JBLControl.iss`): per-user, no admin;
  banner art from `make-windows-icons.ps1`; optional sign-in start and desktop
  shortcut; shortcuts carry the app's AppUserModelID; closes the running app
  before upgrading or uninstalling; the uninstaller also removes what the app
  writes itself (Run value, notification registration, photo cache). Its license
  page includes the bundled runtimes' terms (the Windows App SDK's redistribution
  terms require users to accept them); full texts ship in `{app}\licenses`.
  Install, upgrade-over-running-app and uninstall verified on this PC.
- Targets **.NET 10** (LTS); .NET 8 support ends 2026-11-10.

**Ready for a preview release, not 1.0:** only the Flip 7 has been tried from
Windows, and the checklist items marked unconfirmed above need a pass first.

### How the build differs from the plan below

- **Shell:** a normal main window opens at launch (speakers listed in the
  NavigationView pane, the connected one in full, Settings and About as pages);
  closing it leaves the app in the tray. A tray click opens a compact flyout
  (`TrayPanel`, the Mac popover), a right-click the Mac panel's ••• menu, a
  double-click the window. `--background` (used by the Run key) starts tray-only.
- **Tray icon:** hand-rolled `Shell_NotifyIconW` (`TrayIcon.cs`), not
  H.NotifyIcon, so it doesn't track a third party's WinAppSDK support. The icon
  is the full-color app icon, faded while disconnected, with a dot for Keep Awake.
- **Notifications:** the classic toast API with a per-user AppUserModelID in
  `HKCU\Software\Classes\AppUserModelId`, not `AppNotificationManager` — that
  needs the Windows App SDK's shared runtime package, which a self-contained app
  doesn't have (fails with `0x8007007E`). Buttons open URLs directly (protocol
  activation), so no COM activator.
- **Keep Awake:** `MediaPlayer` playing an in-memory WAV on the chosen output
  device, not NAudio. Output matched by containment ("Speakers (FFR JBL Flip 7)").
- **EQ curve:** a XAML `Polyline`, not Win2D.
- **Packages:** the WinUI / Foundation / InteractiveExperiences / Base parts of
  the Windows App SDK 2.5.1, not the `Microsoft.WindowsAppSDK` bundle, which
  would add ~60 MB of AI/ML runtimes (ONNX Runtime, DirectML) nothing uses.
  Self-contained zips are ~75 MB; trimming (`PublishTrimmed`) could cut the 53 MB
  `Microsoft.Windows.SDK.NET.dll` but needs the JSON settings moved to source-gen first.
- **Versioning:** `Version`/`FileVersion` come from `Resources/Info.plist` at
  build time, so both apps share one version number.
- **Robustness:** every DispatcherQueue/timer/WndProc callback is guarded; an
  exception escaping one fail-fasts the process (XAML's `UnhandledException`
  never sees it). Errors go to `%LOCALAPPDATA%\JBLControl\errors.log`.

### Working on it

`dotnet test windows/JBLControl.Windows.slnx` (29/29), then
`powershell -ExecutionPolicy Bypass -File scripts/build-windows.ps1 -Install -Run`.
New machine: the .NET 10 SDK only. Windows 11 **Smart App Control** blocks
unsigned local builds ("An Application Control policy has blocked this file"),
so it has to be off on a dev machine — and end users with it on can't run the
unsigned release either (README explains). Signing (e.g. Azure Trusted Signing)
is the fix for both.

### Microsoft Store submission (MSIX)

App reserved in Partner Center as **MSIX or PWA app** (not "EXE or MSI app" —
that path needs the developer's own Trusted-Root-CA code-signing certificate;
MSIX gets re-signed by the Store for free, which also sidesteps Smart App
Control/SmartScreen for Store installs). Identity: `FaisalFRafat.JBLControl`.

`windows/JBLControl.Windows/Package.appxmanifest` is a **separate, packaged**
build from the unpackaged installer/zip (`app.manifest`); it doesn't replace
them. `scripts/build-windows.ps1 -Msix` builds
`build/JBLControl-win-<arch>-<version>.msixupload` per architecture — upload
one per architecture to Partner Center's Packages page; they don't need to be
bundled into one file. Verified on this machine for both x64 and arm64 (exit
0, valid non-corrupt zip, `PackageSuccessfullyCreated`) — **not yet actually
submitted/certified**, and Bluetooth-from-inside-the-MSIX-sandbox is
**unverified on real hardware** (risk #4 still applies, now doubly so for the
packaged build specifically).

Two non-obvious things the manifest/script work around:
- **Capabilities element order matters.** `rescap:Capability` (needed for
  `runFullTrust`, since this is a classic-Win32-execution-model Windows App
  SDK app, not a sandboxed UWP one) must come *before* `Capability`/
  `DeviceCapability` siblings in `<Capabilities>`, or `MakeAppx` rejects the
  schema. GATT client access needs `<DeviceCapability Name="bluetooth"/>`;
  network calls (update check, jbl.com photos) need `<Capability
  Name="internetClient"/>`.
- **`-p:AppxSymbolPackageEnabled=false` is required** when building via
  `dotnet publish` (not Visual Studio) on this toolchain: the WinAppSDK MSIX
  tooling's debug-symbol-package step (`WinAppSdkCreateAppStoreContainer`)
  fails under `dotnet`'s cross-platform MSBuild with a missing
  `System.Security.Permissions` assembly (`mspdbcmf.exe` isn't found either).
  The app package itself doesn't need the separate `.appxsym` to be valid —
  disabling it sidesteps the bug entirely rather than fixing the root cause.
- The Identity `Version` attribute's 4th segment is Store-reserved and must
  stay `0`; `-Msix` rewrites the first three from `Resources/Info.plist`
  using a regex anchored with `(?<![A-Za-z])` so it doesn't also corrupt
  `Dependencies`' unrelated `MinVersion="…"` attribute (a real bug caught
  and fixed during this work — the first, unanchored version matched both).

Still ahead: Store listing content (description, screenshots, age rating,
privacy policy URL — jbl.com/GitHub network use means one is required),
submitting for certification, and the hardware/sandbox verification above.

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
  JBLControl.Windows/               # the WinUI 3 app (as built; §5 was the original plan)
    App.xaml(.cs)                   # ← main.swift AppDelegate: tray, windows, startup
    MainWindow.xaml(.cs)            # speakers in the nav pane, detail, Settings, About
    TrayPanel.xaml(.cs)             # ← StatusBarController's popover
    SpeakerPanel.xaml(.cs)          # ← PanelView + HeaderView + PresetPicker + SearchingView
                                    #   (+ SpeakerArtwork, SpeakerSwitcher chips), shared by both
    EqualizerControl.cs             # ← EqualizerView (bands + response curve)
    SettingsPages.cs                # ← SettingsView (General/Speaker/Updates/About)
    SpeakerManager.cs  KeepAwake.cs  PhotoStore.cs  TrayIcon.cs
    Preferences.cs                  # Preferences, AppInfo, CrashLog, Notifier
    Services.cs                     # LoginItem, UpdateChecker, Diagnostics
    TrayIcons.Generated.cs  Assets/AppIcon.ico|png   # scripts/make-windows-icons.ps1
```

`.gitignore` covers `windows/**/bin,obj` and `build/`.
`scripts/build-windows.ps1` sits next to `scripts/build-app.sh`.

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
2. ✅ BLE connect + live battery/info, reconnect/dedup — verified on a Flip 7.
3. ✅ EQ read/write through `EQCodec` with the write-coalescing queue (presets
   verified on hardware; custom sliders not yet).
4. ✅ Main window + tray icon + flyout + full XAML view port (Polyline curve,
   not Win2D).
5. ✅ Keep Awake (MediaPlayer, not NAudio) — not yet confirmed on hardware.
6. ✅ Settings, Run-key login item, low-battery toast, update checker.
7. ✅ Diagnostics report, `build-windows.ps1` packaging, Windows CI, README
   section. Still to do: a SmartScreen smoke test of a downloaded release zip.
8. ⬜ Before 1.0: the hardware checklist on a second model, code signing.

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
