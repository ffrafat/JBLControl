# JBL Go 4 — protocol notes

Go 4 owners (PIDs `20E4`, `210A`, and the Duo `215C` left / `2181` right) get two things from JBL's
own app data and public reverse-engineering, and one thing nobody has published.

## EQ: legacy advanced-level (AA 97 / 98 / 99), five bands

From the JBL Portable app's model table (`presetEqPath: go4_preset.json`, `eqConfig: xtreme4_preset_eq.json`)
and openjbl's builder for it:

```text
request   AA 98 00 00
set       AA 97 | len:u16be | active_category | C1 | 06 | count | (band_index | s8 level) * count
reply     AA 99 | active_category | C1 | 06 | count | (band_index | s8 level) * count
```

For a flat custom curve on a Go 4 that is exactly:

```text
AA 97 00 0E C1 C1 06 05 01 00 02 00 03 00 04 00 05 00
```

- Five bands, at 100 Hz, 1 kHz, 2 kHz, 7 kHz and 10 kHz. Levels are integers in −6…+6.
- The level byte is an index into the firmware's own table, not a dB value, so out-of-range values are
  undefined rather than "louder".
- Presets are the four categories the model data carries: 06 Signature, 22 Chill, 08 Energetic, 03 Vocal;
  `C1` is the custom curve.
- `0x97` is acknowledged by a `99` reply, not by `DEV_ACK`. `EE` means the firmware rejected it.

Writes on Go 4 are still behind *Allow experimental EQ* until someone confirms them on hardware.

## Auracast: token 3C

JBL's app switches the broadcast with the generic "set device info" command:

```text
on    AA 13 04 00 3C 01 01
off   AA 13 04 00 3C 01 00
read  AA 13 02 00 3C      →  AA 12 03 00 3C <value>
```

The speaker answers `AA 00 02 13 00` (accepted). That frame is documented in the reverse-engineering of
JBL's app for the same AA protocol (Harman Kardon One's `AuraCastCommand`), and it is what JBLControl sends.

## What a Mac cannot do

- macOS has no LE Audio / Auracast API: CoreBluetooth is GATT only. A Mac cannot broadcast, and cannot be
  a receiver, so JBLControl cannot route audio into a pair.
- The pair itself is made on the speakers: press the Auracast button on both Go 4s, and the one with a
  Bluetooth Classic link to the computer transmits while the other receives. Duos pair by bumping them
  together (AirTouch).
- **Left and right are chosen inside the speakers.** JBL publishes no command for it and no public capture
  shows one; the persisted "stereo preference" in firmware 0.5.9.0 has no documented control surface.
  JBLControl can read every info token the speaker reports — `Copy Diagnostics` now includes the raw token
  map, so it can be diffed before and after a pair is made, which is how the token (if it exists) would be
  identified.
