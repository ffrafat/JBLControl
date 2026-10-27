# Contributing

## Verify your speaker

The quickest way to help is to confirm a beta or experimental model:

1. Connect JBLControl to your speaker.
2. **••• → Copy Diagnostics**, then open a [device report](.github/ISSUE_TEMPLATE/device-report.yml) and paste it.
3. If you're up for it: turn on **••• → Allow Experimental EQ**, pick a preset, nudge one custom band, and
   say whether the sound changed. Then Copy Diagnostics again, so the report shows the write and the speaker's reply.

## Add or fix a model

Model data lives in `Sources/JBLControlKit/Catalog+Generated.swift`, generated from the JBL Portable
app's model config (via [openjbl](https://github.com/NiceDayZc/openjbl)):

```bash
git clone https://github.com/NiceDayZc/openjbl /tmp/openjbl
scripts/generate-catalog.py /tmp/openjbl
```

To promote a model to **Verified**, add its product ID to `VERIFIED` in the generator, add its captured replies
as a test in `Tests/JBLControlKitTests`, and regenerate.

Protocol work goes in `Sources/JBLControlKit/EQCodec.swift` (one case per protocol family) with tests.
`Tools/Probe` is a standalone read-only BLE prober for poking at unknown models.

## Add a speaker photo

Both apps ship small (256 px) copies of JBL's product photos from `Resources/SpeakerPhotos`. To add a model
or color, open its page on jbl.com, copy the hero image path (the `dw…/…HERO….png` part of the image
address), add it to `scripts/speaker-photos.json` under the product ID and the color code from the catalog,
then run `scripts/make-speaker-photos.py` (needs `brew install imagemagick pngquant`) and commit the result.
Color code `00` is the fallback for colors without their own photo.

## Ground rules

- Read-only by default: anything that writes to a speaker must be behind `canWrite`.
- No JBL/Harman assets (logos, firmware, APKs) in the repository, apart from the downsized product photos
  in `Resources/SpeakerPhotos`.
- `swift test` must pass.
