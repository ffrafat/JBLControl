# Next steps (handoff note)

Written 2026-10-27 so work can continue on another machine. Delete this file once the items are done.

## State

- **v0.9.0 is the current release (2026-10-27), Mac and Windows.** It includes the v0.8.1 Windows fixes
  (reconnect after the speaker is switched off and on, no crash when it drops out), bundled speaker photos,
  volume and mute, a larger battery number and the fitted EQ chart. The `v0.8.1` tag exists but its release
  was left as a draft and never published: everything in it shipped in v0.9.0.
- Not tried on hardware yet: the Windows reconnect/crash fixes and Windows volume and mute (the owner chose to
  release without a Windows test). The Mac volume row was checked with a Flip 7.

## Open work

1. **Speaker photos: done (2026-10-27), not yet released.** Photos are now bundled in `Resources/SpeakerPhotos`
   (81 photos at 256 px, 1.3 MB) for 18 product IDs, built by `scripts/make-speaker-photos.py` from
   `scripts/speaker-photos.json`; both apps read `index.json` and no longer go online for photos. Cylinder
   photos are pre-rotated, so the apps don't rotate them. Not on jbl.com any more (placeholder stays): Pulse
   3/4/5, Boombox 1/2, Charge 3/4, Flip 3/4, Xtreme 1/2, Go 4 Duo, Charge 5 Wi-Fi, Boombox 3 Wi-Fi. The Windows
   side was not built locally (no .NET on the Mac); check CI. Old notes, for reference: only the Flip 7 had a photo (`PhotoSources` in `windows/JBLControl.Windows/PhotoStore.cs`
   and `Sources/JBLControl/PhotoStore.swift`); every other model shows the drawn placeholder. This is GitHub
   issue 2 (Charge 5 "icon wrong") and a Reddit comment about the Charge 6 image. Add the paths to both tables.
   - Photos are fetched from the JBL image CDN at runtime and cached. Do not commit the images
     (see CONTRIBUTING.md).
   - The hash folder in the URL (`dwXXXXXXXX/`) is ignored by the CDN; only the file name matters.
   - File name shape: `[LS_]JBL_<MODEL>_[<COLOR>_]HERO_[<COLOR>_]<NUMBER>_x<N>.png`. The number (3 to 5 digits)
     and `x<N>` suffix cannot be guessed, so each color needs one URL copied from the product page
     (browser DevTools, or right-click the image, "Copy image address").
   - Names found so far: `LS_JBL_CHARGE_6_BLACK_HERO_071_x1.png`, `LS_JBL_CHARGE_6_BLUE_HERO_079_x1.png`,
     `JBL_GO_4_HERO_BLACK_48156_x4.png`. Color codes per model are in `Catalog.Generated.cs`.
   - jbl.com blocks scripted requests (bot check). Use a normal browser session; do not try to bypass the check.
   - After adding a Charge photo, check the Windows and Mac artwork code: cylinder photos are rotated 90 degrees
     (`SpeakerArtwork`), which may be wrong for Charge images.
2. **Boombox 4** (`0x214E`, Protocol 4, experimental) is reported as "not detected" on Windows. Ask the reporter
   (Reddit user Wass_uppppp) for a Copy Diagnostics report in a GitHub issue before changing anything.
3. **Reddit requests done (2026-10-27), not yet released:** larger battery number; EQ chart scale fitted to the
   bands' real limits (no empty headroom above +6 dB); volume slider and mute (controls the speaker's audio
   output on the computer, since JBL's protocol has no volume command; Windows uses Core Audio COM, not yet
   compiled or tried on hardware). Not planned: power on/off and firmware updates (no way to wake an off
   speaker over Bluetooth; flashing is risky).
4. **Reddit:** reply to the Windows reconnect and crash reports with "fixed in v0.8.1" once the release is published.
