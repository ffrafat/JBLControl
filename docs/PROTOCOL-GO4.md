# JBL Go 4 — protocol notes

Go 4 owners (PIDs `20E4`, `210A`; the Duo is `215C` left / `2181`
right) speak the same AA control protocol as the Flip 7, with two differences: EQ is the
five-band integer "advanced level" form, and the unit exposes a real stereo channel command.

Sources: an openjbl EQ audit on PID `20E4` (2026-11-14, read-back verified), this project's
Flip 7 captures, and static analysis of **JBL Portable 6.9.33** (`com.harman.ble.jbllink`)
decompiled with jadx. Class names below come from that APK.

## EQ — legacy advanced level (`AA 97 / 98 / 99`), five bands

```text
request   AA 98 00 00
set       AA 97 | len:u16be | active_category | C1 | 06 | count | (band_index | s8 level) * count
reply     AA 99 | active_category | C1 | 06 | count | (band_index | s8 level) * count
request one token   AA 13 02 00 <token>
```

A flat custom curve on a Go 4 is exactly:

```text
AA 97 00 0E C1 C1 06 05 01 00 02 00 03 00 04 00 05 00
```

- Five bands at 100 Hz, 1 kHz, 2 kHz, 7 kHz and 10 kHz; integer levels in −6…+6 dB.
- The level byte indexes the firmware's own table, so out-of-range values are undefined, not louder.
- `C1` selects the custom curve. The four presets are the model data's categories:
  06 Signature, 22 Chill, 08 Energetic, 03 Vocal.
- `0x97` is answered by `0x99` with the new state, not by a separate `DEV_ACK`; `EE`
  means the firmware rejected the write.
- Verified on hardware: openjbl wrote `AA 97 00 0E C1 C1 06 05 01 FF 02 03 03 04 04 00 05 00`
  and read every band back with `AA 98 00 00`. The Go 4 is therefore marked **Verified** in the
  catalog and needs no experimental opt-in.

JBL's app selects a **preset** with a different payload: `DefaultPresetEQPayload` turns each
preset band into five fixed-point biquad coefficients and sends

```text
AA 97 | len:u16be | active_category | (b0 | b1 | b2 | -a1 | -a2):int32le * bands
```

That is 101 bytes for the Go 4's five bands (`AA 97 00 65 …`), and the speaker replies with an
`AA 99` whose first byte is the new active category. JBLControl implements this encoder
(`PresetEQ`) and it was verified on a Go 4: Signature, Chill and Vocal each switched the active
category and echoed the coefficients. The custom curve stays untouched, as the reply's `C1`
levels show.

Xtreme 4 is the one `.legacyLevels` model that uses a different (AKM) coefficient encoder; its
presets are hidden until that encoder is ported.

## Auracast and stereo — `AA 6A`, `AA 15`, `AA A0/A1/A2`

JBL's app has an Auracast screen with a broadcast switch, a PartyBoost mode and a left/right
channel picker. The commands are:

```text
link mode on      AA 6A 01 02        (0 off, 1 PartyBoost, 2 Auracast)
link mode off     AA 6A 01 00
link mode reply   AA 6B 01 <role>     (0 normal, 1 master, 2 slave, 3 standby)
role check        AA 17 00         → AA 16 01 <role>

channel           AA 15 03 00 46 00  (00 none/mono, 01 left, 02 right)
stereo lock       AA 15 03 00 49 00  (00 unlocked, 01 locked)
set-token ack     AA 00 02 15 00

group status      AA A1 00         → AA A2 <TLV>
group create      AA A0 <len> TLV  (compact: 01 01 action | 02 01 type | 04 01 channel | 05 04 id)
```

`SetLinkModeCommand`, `SetChannelCommand`, `SetChannelLockCommand` and
`SetAuraCastGroupCommand` in the APK build exactly these frames. `SetLinkModeCommand` answers
`AA 6B` with the role the unit took; `SetChannelCommand` checks the device-info ACK
`AA 00 02 15 00`.

### Token map (`AA 12`)

| Token | Meaning | Values |
|---|---|---|
| `0x3C` | older Play Together / Auracast bit | 0 off, 1 on |
| `0x45` | linked units | count |
| `0x46` | **audio channel** | 0 none, 1 left, 2 right |
| `0x49` | stereo lock | 0 / 1 |
| `0x4C` | Auracast supported | 0 / 1 |

### Group status (`AA A2`)

TLVs are `token | length | value`:

| Token | Meaning |
|---|---|
| `01` | action: 1 create, 2 destroy, 3 prepare |
| `02` | type: 1 stereo, 2 party |
| `03` | role |
| `04` | channel |
| `05` | 4-byte group id |
| `06` | group name (UTF-8) |
| `07` | partner address (6 bytes) |
| `08` | app writes `14`; only read back |

### How the pair is formed

- Two Go 4s join each other on the speakers: press the Auracast button on the second one.
- The app then assigns each unit its half with `AA 15 03 00 46 01` (left) or `...02` (right).
- The Duo (`215C` / `2181`) uses AirTouch: bump the two units together and the firmware
  picks the halves itself. The APK deliberately ignores the channel TLV for AirTouch models, so
  JBLControl shows AirTouch models as read-only and offers the button flow instead.
- JBL's app can also create the group from the phone, because it holds a link to both units at
  once (`createStereoGroupCommandToPrimary` / `...ToSec`). JBLControl talks to one speaker at a
  time; its `AuracastGroupRequest` frame builder covers that command for a future two-link
  pairing flow.

## Hardware status (2026-11-15)

Verified on a Go 4 (`20E4`, firmware `0.6.4.0`) over BLE:

- Custom EQ: wrote a modified five-band curve, the `0x99` reply and a fresh `0x98` read both
  matched, and the original curve was restored.
- Presets: the `DefaultPresetEQPayload` frames for Signature, Chill and Vocal each switched the
  active category (`AA 99 … 06/22/03 …`) and echoed the coefficients.
- Channel: `AA 15 03 00 46 01/02/00` was ACKed (`AA 00 02 15 00`); token `0x46` still read
  `00` outside a group, which is why the app trusts the ACK over a later token read.
- Link mode: `AA 6A 01 02` answered `AA 16 01 01` (role master). The unit then stopped
  answering new BLE control connections until it left broadcast mode. The speaker's Auracast
  button is the way out if a link drops; JBLControl holds its own link, but a Mac cannot reopen
  one while the unit is broadcasting.

Not yet tested on hardware: a second Go 4, the actual left/right split, and the group
`AA A0` / `AA A2` flow. That is the next step with two units.

## What a Mac cannot do

- CoreBluetooth is GATT only. macOS has no LE Audio / ISO / BASS API, so JBLControl cannot be the
  audio source or a receiver; it only sends the control frames above.
- Left/right is a normal control-channel write, not an OS-level operation, so assigning it from
  a Mac works — that is what the Auracast card does.
