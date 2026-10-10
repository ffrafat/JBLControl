# JBL Flip 7 BLE control protocol — verified notes

Verified against a real Flip 7 (PID `2107`, firmware `0.7.2.0`) from macOS CoreBluetooth on 2026-10-10.
Builds on [openjbl](https://github.com/NiceDayZc/openjbl) (APK analysis, Charge 6 hardware tests) and
[jbl-charge5](https://github.com/hudsonbrendon/jbl-charge5) (info tokens).

## Transport

- Advertises service data key `FDDF`, name truncated (e.g. `FFR JBL Fli`).
- Manufacturer data `57 00 | PID LE | …` — `57 00 07 21 …` → company `0x0057`, PID `0x2107`.
- No pairing or app-level handshake needed for reads or EQ writes.

GATT services seen:

| Service | Characteristics |
|---|---|
| `65786365-6C70-6F69-6E74-2E636F6D0000` (control) | `…0001` notify+read (speaker → app), `…0002` write (app → speaker), `…2E636F6A0001` |
| `65786365-6C70-6F69-6E74-2E636E6C0000` (secondary) | `…0001`, `…0002` |
| `FE2C` (Google Fast Pair) | `FE2C1234…123A` |

Negotiated max write length: 512.

## Framing

`AA | cmd | len | payload`; commands `92 96 97 98 99` use a 2-byte big-endian length. No checksum.

## Speaker info — write `AA 11 00`

Answered by a burst of `AA 12` frames, payload `00 | token | value` (`AA 11` without the length byte is ignored).

| Token | Value seen | Meaning |
|---|---|---|
| `C1` | len + `FFR JBL Flip 7` | device name |
| `42` | `21 07` | product ID |
| `43` | `01` | color code (01 = Black) |
| `44` | `1E`, `8A` | battery: low 7 bits are the % (30), high bit set while charging (`8A` = charging, 10%) |
| `46` | `00` | audio channel |
| `47` | `00` | Bluetooth audio source connected |
| `48` | 6 bytes | MAC address |
| `49` `4B` `4F` `53` | `00` | unknown (candidates: feedback tones, Playtime Boost, auto standby) |
| `4A` | `20 31` | unknown |
| `4C` | `01` | unknown |
| `C2` | len + string | serial number |
| `4D` | `00 07 02 00` | firmware version |

## Firmware — write `AA 41 00`

`AA 42 04 | 00 07 02 00` → `0.7.2.0`. Followed by an unsolicited `AA 9C 01 00` (unknown).

## EQ

- `AA 61 00` (EQ mode) → `AA EE 01 61` — unsupported on Flip 7.
- `AA 98 00 00` → `AA 99 00 62 | active | C2 | 07 | 0000BB80 | 7 × band`.
  `active` is the selected preset; the bands are **always the stored custom curve**.
- Band (13 bytes): `type | gain f32be | freq f32be | Q f32be`; type 0 low shelf, 1 peaking, 2 high shelf, 3 low pass.

Write: `AA 97 00 62 | cat | cat | 07 | 0000BB80 | 7 × band`, answered by `AA 99` with the new state.

| Category | Preset |
|---|---|
| `06` | JBL Signature |
| `08` | Energetic |
| `22` | Chill |
| `03` | Vocal |
| `C2` | Custom |

Verified behaviour:

- Writing a preset category (`08 08` + preset bands) switches the preset and leaves the stored custom curve untouched.
- Writing `C2 C2` + bands selects Custom and stores those bands (band 7 4.5 → 4.0 → 4.5 round-tripped exactly).

Custom editor limits (from the JBL app): band 1 −9…+6 dB (0.75 dB steps below 0, 0.5 above), bands 2–7 ±6 dB in 0.5 dB steps.
Frequencies 125/250/500/1k/2k/4k/8k, Q 0.707 on the shelves and 2 on the peaks.

## Not yet mapped

Playtime Boost, feedback tones, Auracast, auto standby. Next step: capture JBL Portable on an iPhone with
Apple's Bluetooth logging profile + PacketLogger while toggling each one, then diff the `AA 12` tokens above.
