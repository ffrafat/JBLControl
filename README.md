<p align="center">
  <img src="docs/images/icon.png" width="128" alt="JBLControl icon">
</p>

<h1 align="center">JBLControl</h1>

<p align="center"><b>JBL speaker control, right in your menu bar.</b></p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/github/v/release/ffrafat/JBLControl?label=download" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-universal-lightgrey" alt="Apple Silicon and Intel">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/ffrafat/JBLControl" alt="MIT license"></a>
</p>

<p align="center">
  <img src="docs/images/screenshot.png" width="400" alt="JBLControl's menu bar panel: a JBL Flip 7 with battery level, EQ presets and the Energetic response curve">
</p>

Battery level, EQ presets and a custom equalizer for JBL Flip, Charge, Xtreme, Go, Clip, Pulse, Boombox and
more, in a native macOS menu bar panel (Liquid Glass on Tahoe). No phone, no JBL Portable app.

> Unofficial. Not affiliated with or endorsed by JBL or Harman International.

## Features

- 🔋 Battery, model, color and firmware at a glance
- 🎚️ JBL's EQ presets (Signature, Chill, Energetic, Vocal…) and a custom equalizer with a live response curve
- 🔄 Auto-reconnects, even though JBL speakers rotate their Bluetooth address
- 🖼️ The speaker shown in its actual color
- 🔀 One-click switching when several JBL speakers are nearby
- ☕ Keep Awake: stops the speaker's auto power-off while your Mac is playing to it (JBL has no setting for this)
- ⚙️ Settings: launch at login, battery percentage in the menu bar, low-battery alerts, update checks
- 🧪 Built-in diagnostics report, so owners of untested models can help add support

## Supported speakers

| Status | Models |
|---|---|
| ✅ Verified | Flip 7, Charge 6, Charge 5 |
| 🟠 Beta | Xtreme 3, Xtreme 4, Go 4, Go 4 Duo, Clip 5, Tuner 3 |
| 🟣 Experimental | Go 5, Grip, Xtreme 5, Boombox 2/3/4, Flip 6, Pulse 5, Flip/Charge Essential 3 SE, older models |

Full list with product IDs: [docs/SUPPORTED_MODELS.md](docs/SUPPORTED_MODELS.md).
Beta and experimental models read battery and EQ safely. Changing their EQ needs
**••• → Allow Experimental EQ** until someone with that speaker confirms it works.

**Have a beta or experimental model?** Choose **••• → Copy Diagnostics** and paste it into a
[device report](../../issues/new?template=device-report.yml). It only sends read-only requests,
and it hides your speaker's MAC address and serial number.

## Installation

**Requirements:** macOS 14 Sonoma or later, on Apple Silicon or Intel. On macOS 26 Tahoe and later the panel uses Liquid Glass; on Sonoma and Sequoia it uses the classic translucent look.

### Install in 3 steps

1. **Download** `JBLControl-<version>.dmg` from the [latest release](../../releases/latest).
2. **Open the DMG** and drag **JBLControl** onto the **Applications** folder.

   <img src="docs/images/install-dmg.png" width="480" alt="The JBLControl installer window: drag the app onto the Applications folder">

3. **Open JBLControl** from Applications (or Spotlight). The first time, macOS will block it.
   That's expected; see [below](#if-macos-blocks-jblcontrol) for why and how to allow it.
   Then click **Allow** when it asks for **Bluetooth**.

A speaker icon appears in the menu bar. Turn your JBL speaker on and click the icon; JBLControl finds it by itself.

> Close the JBL Portable app on your phone if JBLControl can't connect: speakers accept one control
> connection at a time.

**Start at login:** ••• → **Settings…** → General → **Launch at login**.

**Update:** quit JBLControl (••• → **Quit**), then install the new DMG the same way and choose **Replace**.

**Uninstall:** quit it and drag JBLControl from Applications to the Trash. Optionally also delete
`~/Library/Caches/io.github.jblcontrol` (cached speaker photos).

### Keep Awake

JBL portables switch themselves off after roughly 10–20 minutes without sound, and JBL offers no way to
change that (except on the Go 5 and Xtreme 5). Turn on **Keep speaker awake** (Settings → Speaker, or
••• → Keep Speaker Awake) and, while the speaker is your Mac's sound output, JBLControl plays a 2-second,
inaudible 30 Hz tone every 5 minutes so the speaker never sees long enough silence.

- Works with any JBL speaker, but only when your Mac is the audio source (not a phone).
- While it's on, the menu bar speaker turns orange and the panel shows a cup; click the cup to turn it off.
- The speaker keeps using battery while it stays on.

### If macOS blocks JBLControl

The first time you open it, macOS shows **"JBLControl" Not Opened** with *"Apple could not verify
'JBLControl' is free of malware…"*.

**Why this happens.** Every app downloaded from the internet is checked by Gatekeeper, the macOS feature
that lets an app open straight away only if Apple has *notarized* it. Notarization means the developer
paid for the Apple Developer Program (US$99 a year) and Apple's servers scanned that build. JBLControl is a
free, unpaid hobby project, so it isn't notarized [yet](#support-the-project). The warning means Apple
hasn't checked this build. It doesn't mean macOS found anything wrong with it.

**Is it safe?** Only open software you trust; here's what you can check for this one:

- **All the code is public** in this repository, and each release is built from it with
  `scripts/build-app.sh`. You can read it, or [build it yourself](#build-from-source).
- **It doesn't need an account or any personal data.** It uses Bluetooth to talk to your speaker, plus the
  internet only to check GitHub for new versions and to download speaker photos from jbl.com.
- **You can check that your download wasn't tampered with.** Each release lists SHA-256 checksums; in
  Terminal, `shasum -a 256 ~/Downloads/JBLControl-<version>.dmg` should print the same value.

Allowing it is a one-time step for this app only. It doesn't turn Gatekeeper off for anything else.

#### Option A: System Settings (no Terminal)

1. Open JBLControl. When macOS says it can't be opened, click **Done** (not *Move to Trash*).
2. Open **System Settings → Privacy & Security** and scroll down to **Security**.
3. Next to *"JBLControl" was blocked to protect your Mac*, click **Open Anyway**.
4. Confirm with **Open Anyway** and your password or Touch ID.

On **macOS 14 Sonoma** you can instead right-click (or Control-click) JBLControl in Applications,
choose **Open**, then **Open** again.

#### Option B: Terminal

```bash
xattr -dr com.apple.quarantine /Applications/JBLControl.app
```

Then open JBLControl normally.

What it does: when you download a file, macOS tags it with a *quarantine* flag, and Gatekeeper only checks
apps that carry that flag. This command removes the flag from JBLControl (`-d` deletes the attribute, `-r`
applies it to everything inside the app). It changes nothing else on your Mac and doesn't turn off Gatekeeper.
Don't use commands such as `sudo spctl --master-disable` that you may see suggested online: they turn off
Gatekeeper for every app.

### Build from source

Needs Xcode 26 or later (the app itself runs on macOS 14+). Builds are universal (Apple Silicon + Intel).

```bash
git clone https://github.com/ffrafat/JBLControl.git
cd JBLControl
scripts/build-app.sh --install --run   # builds, copies to /Applications, launches
swift test                             # protocol tests, including real Flip 7 captures
```

Open `Package.swift` in Xcode to work on it. The build script signs with your Apple Development identity if
you have one, so the Bluetooth permission survives rebuilds. `scripts/build-app.sh --zip` also writes a
release zip to `build/`.

## How it works

JBL speakers expose a control service over Bluetooth LE (`65786365-6C70-6F69-6E74-2E636F6D0000`).
JBLControl speaks the same protocol as JBL's own app. There are two generations, legacy `AA` frames and
"Protocol 4" `DD 00` frames, plus four EQ encodings. See [docs/PROTOCOL-FLIP7.md](docs/PROTOCOL-FLIP7.md).

| Path | What |
|---|---|
| `Sources/JBLControlKit` | Protocol library: frame codecs, EQ codecs per family, model catalog. No UI, fully tested |
| `Sources/JBLControl` | The menu bar app: CoreBluetooth, SwiftUI panel, diagnostics |
| `scripts/generate-catalog.py` | Regenerates the model catalog from the JBL app's model data |
| `scripts/make-icon.py` | Regenerates the Liquid Glass app icon (`Resources/AppIcon.icon`, opens in Icon Composer) |
| `Tools/Probe` | Standalone read-only BLE probe for reverse-engineering new models |

## Contributing

Contributions of every size help:

- **Own a beta or experimental speaker?** Send a [device report](../../issues/new?template=device-report.yml)
  with the output of **••• → Copy Diagnostics**. This is the most useful thing you can do: it's how models
  get verified.
- **Code:** protocol work, new models, UI. See [CONTRIBUTING.md](CONTRIBUTING.md).
- **Speaker photos:** add jbl.com image paths for your model (see [CONTRIBUTING.md](CONTRIBUTING.md#add-a-speaker-photo)).
- **Bugs and ideas:** [open an issue](../../issues).

## Support the project

JBLControl is free and open source. Right now every download triggers macOS's *"cannot verify"* warning,
because shipping a properly signed and **notarized** Mac app needs an Apple Developer Program membership
(**US$99 a year**). Donations go first to that fee, then to buying the speakers people are waiting on so
they can be tested on real hardware.

- ❤️ [GitHub Sponsors](https://github.com/sponsors/ffrafat)

Can't donate? A ⭐ on GitHub or a device report helps just as much.

## Credits

JBLControl stands on the shoulders of people who reverse-engineered JBL's protocol first:

- **[openjbl](https://github.com/NiceDayZc/openjbl)** by OpenJBL contributors (MIT). The foundation of
  this project: the JBL Portable protocol analysis (frame formats, EQ command families, Protocol 4), the model
  catalog and preset data that `scripts/generate-catalog.py` turns into JBLControl's model list, and the
  hardware-verified Charge 6 profile.
- **[jbl-charge5](https://github.com/hudsonbrendon/jbl-charge5)** by Hudson Brendon (MIT). Documented the
  BLE control service and the speaker-info tokens (name, battery, color, model) that JBLControl reads.
- **[connect-plus](https://github.com/pembem22/connect-plus)** and
  **[jbl-firmware](https://github.com/pembem22/jbl-firmware)** by pembem22. Earlier open work on configuring
  JBL speakers, used as a reference only (no code from them is included).

Third-party license texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

[MIT](LICENSE).

JBLControl is an independent project, not affiliated with, endorsed or sponsored by JBL or Harman
International. JBL is a trademark of Harman International Industries, Incorporated. Speaker photos belong to
Harman; they're downloaded from jbl.com at runtime and aren't part of this repository.
