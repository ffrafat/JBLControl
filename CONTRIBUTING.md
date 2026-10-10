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

Photos are fetched from jbl.com at runtime, never committed. To add a model, open its page on jbl.com,
copy the hero image paths for each color, and add them to `PhotoSources.table` in
`Sources/JBLControl/PhotoStore.swift`, keyed by the color codes in the catalog.

## Ground rules

- Read-only by default: anything that writes to a speaker must be behind `canWrite`.
- No JBL/Harman assets (photos, logos, firmware, APKs) in the repository.
- `swift test` must pass.
