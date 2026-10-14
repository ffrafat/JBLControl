#!/usr/bin/env python3
"""Generate Sources/JBLControlKit/Catalog+Generated.swift from openjbl's copy of the
JBL Portable app's model data (MIT, https://github.com/NiceDayZc/openjbl).

Usage: scripts/generate-catalog.py /path/to/openjbl
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources/JBLControlKit/Catalog+Generated.swift"
WIN_OUT = ROOT / "windows/JBLControlKit.Windows/Catalog.Generated.cs"
DOC = ROOT / "docs/SUPPORTED_MODELS.md"

FAMILY_EQ = {
    "legacyParametric": "7-band parametric + presets",
    "legacyLevels": "Band levels + presets",
    "legacySimple": "Bass / mid / treble",
    "protocol4Parametric": "7-band parametric + presets (Protocol 4)",
    "protocol4Quantized": "7-band custom (Protocol 4)",
    "infoOnly": "None (battery and info only)",
}
SUPPORT_LABEL = {"verified": "✅ Verified", "beta": "🟠 Beta", "experimental": "🟣 Experimental", "unsupported": "⛔ Unsupported"}

# Models whose wire format has been confirmed byte for byte on real hardware.
VERIFIED = {"2107", "20e3"}  # Flip 7 (this project), Charge 6 (openjbl)
# Protocol 4 models that take quantized 0E7F EQ instead of 0E02 parametric.
QUANTIZED_P4 = {"2132", "2168", "2185", "218a"}

CATEGORIES = {
    "BALANCE": 0x00, "BASS_BOOST_1": 0x01, "BASS_BOOST_2": 0x02, "VOCAL": 0x03, "METAL": 0x04,
    "CLASSICAL": 0x05, "SIGNATURE": 0x06, "RELAXING": 0x07, "ENERGETIC": 0x08, "EXTREME": 0x09,
    "RESERVED_2": 0x22,
}
FILTERS = {"LOW_SHELF_FILTER": ".lowShelf", "PEAKING_EQ": ".peaking", "HIGH_SHELF_FILTER": ".highShelf",
           "LOW_PASS_FILTER": ".lowPass", "HIGH_PASS_FILTER": ".highPass"}
WITH_PRESETS = {"legacyParametric", "legacyLevels", "protocol4Parametric"}

# camelCase (Swift) -> PascalCase (C#) for the enum cases emitted into both generated catalogs.
FAMILY_CS = {
    "legacyParametric": "LegacyParametric", "legacyLevels": "LegacyLevels", "legacySimple": "LegacySimple",
    "protocol4Parametric": "Protocol4Parametric", "protocol4Quantized": "Protocol4Quantized", "infoOnly": "InfoOnly",
}
SUPPORT_CS = {"verified": "Verified", "beta": "Beta", "experimental": "Experimental", "unsupported": "Unsupported"}
FORM_CS = {"cylinder": "Cylinder", "compact": "Compact", "boombox": "Boombox"}
FILTERS_CS = {"LOW_SHELF_FILTER": "FilterType.LowShelf", "PEAKING_EQ": "FilterType.Peaking",
              "HIGH_SHELF_FILTER": "FilterType.HighShelf", "LOW_PASS_FILTER": "FilterType.LowPass",
              "HIGH_PASS_FILTER": "FilterType.HighPass"}


def family(model):
    f = set(model.get("features", []))
    if "PROTOCOL_4" in f:
        return "protocol4Quantized" if model["pid"].lower() in QUANTIZED_P4 else "protocol4Parametric"
    if "7_BANDS_EQ" in f:
        return "legacyParametric"
    if "PRESET_EQ" in f:
        return "legacyLevels"
    if "EQ_BALANCE_SUPPORT" in f:
        return "legacySimple"
    return "infoOnly"


def support(model, fam):
    name, transport = model["deviceName"], model.get("protocol", "")
    if "Wi-Fi" in name or transport == "PROTOCOL_SPP":
        return "unsupported"
    if model["pid"].lower() in VERIFIED:
        return "verified"
    if fam.startswith("protocol4") or fam == "infoOnly" or transport != "PROTOCOL_BLE":
        return "experimental"
    return "beta"


def clean_name(raw):
    name = re.sub(r"\((CSR|QCC|GM)\)", "", raw).strip()
    name = re.sub(r"^JBLGo4DUO([LR])$", r"JBL Go 4 Duo (\1)", name)
    name = re.sub(r"\bBoomBox\b", "Boombox", name)
    name = re.sub(r"\bGO\b", "Go", name)
    name = re.sub(r"\bCLIP\b", "Clip", name)
    return name


def form_factor(name):
    if "Boombox" in name:
        return "boombox"
    if any(k in name for k in ("Go", "Clip", "Grip", "Tuner")):
        return "compact"
    return "cylinder"


def preset_name(p):
    if p["categoryId"] == "RESERVED_2":
        return (p.get("displayName") or "Chill").title()
    return p["categoryId"].replace("_", " ").title()


def swift_presets(path):
    presets = json.loads(path.read_text())
    out = []
    for p in presets:
        cat = CATEGORIES.get(p["categoryId"])
        if cat is None:
            continue
        bands = ", ".join(
            f"EQBand({FILTERS[b['type']]}, {float(b['frequency'])}, {float(b['gain'])}, q: {float(b['qValue'])})"
            for b in p["params"]
        )
        out.append(f'        EQPreset(category: 0x{cat:02X}, name: "{preset_name(p)}", bands: [{bands}]),')
    return out


def csharp_presets(path):
    presets = json.loads(path.read_text())
    out = []
    for p in presets:
        cat = CATEGORIES.get(p["categoryId"])
        if cat is None:
            continue
        bands = ", ".join(
            f"new EQBand({FILTERS_CS[b['type']]}, {float(b['frequency'])}f, {float(b['gain'])}f, q: {float(b['qValue'])}f)"
            for b in p["params"]
        )
        out.append(f'        new EQPreset(category: 0x{cat:02X}, name: "{preset_name(p)}", bands: [{bands}]),')
    return out


def hex_color(s):
    return "0x" + s.lstrip("#").upper()


def main():
    data = Path(sys.argv[1]) / "src/openjbl/data"
    models = json.loads((data / "product_list_config.json").read_text())["productList"]

    preset_sets = {}
    cs_preset_sets = {}
    lines = []
    cs_lines = []
    rows = []
    for m in models:
        fam = family(m)
        sup = support(m, fam)
        name = clean_name(m["deviceName"])
        cfg = m.get("eqConfig") or m.get("presetEqPath")
        presets = "[]"
        cs_presets = "Array.Empty<EQPreset>()"
        if fam in WITH_PRESETS and cfg and (data / cfg).is_file():
            key = re.sub(r"\W", "_", cfg.removesuffix(".json"))
            preset_sets.setdefault(key, swift_presets(data / cfg))
            cs_preset_sets.setdefault(key, csharp_presets(data / cfg))
            presets = key
            cs_presets = key
        colors = ", ".join(
            f'0x{int(code, 16):02X}: SpeakerColor("{c["colorName"].strip().title()}", {hex_color(c["gradientS"])}, {hex_color(c["gradientE"])})'
            for code, c in sorted(m.get("productImageUrls", {}).items(), key=lambda kv: int(kv[0], 16))
            if c.get("gradientS") and c.get("gradientE")
        )
        cs_colors = ", ".join(
            f'[0x{int(code, 16):02X}] = new SpeakerColor("{c["colorName"].strip().title()}", {hex_color(c["gradientS"])}, {hex_color(c["gradientE"])})'
            for code, c in sorted(m.get("productImageUrls", {}).items(), key=lambda kv: int(kv[0], 16))
            if c.get("gradientS") and c.get("gradientE")
        )
        rows.append((["verified", "beta", "experimental", "unsupported"].index(sup), name, m["pid"].upper(), sup, fam))
        lines.append(
            f'        SpeakerModel(productID: 0x{int(m["pid"], 16):04X}, name: "{name}", family: .{fam}, '
            f'support: .{sup}, formFactor: .{form_factor(name)}, presets: {presets},\n'
            f'                     colors: [{colors or ":"}]),'
        )
        cs_colors_block = (f"new Dictionary<byte, SpeakerColor> {{ {cs_colors} }}" if cs_colors
                            else "new Dictionary<byte, SpeakerColor>()")
        cs_lines.append(
            f'        new SpeakerModel(productId: 0x{int(m["pid"], 16):04X}, name: "{name}", '
            f'family: ProtocolFamily.{FAMILY_CS[fam]}, support: SupportLevel.{SUPPORT_CS[sup]}, '
            f'formFactor: FormFactor.{FORM_CS[form_factor(name)]}, presets: {cs_presets},\n'
            f'                     colors: {cs_colors_block}),'
        )

    swift = ["// Generated by scripts/generate-catalog.py from the JBL Portable app's model data.",
             "// Do not edit by hand.", "", "enum GeneratedCatalog {"]
    for key, presets in sorted(preset_sets.items()):
        swift += [f"    static let {key}: [EQPreset] = [", *presets, "    ]", ""]
    swift += ["    static let models: [SpeakerModel] = [", *lines, "    ]", "}", ""]
    OUT.write_text("\n".join(swift))

    csharp = ["// Generated by scripts/generate-catalog.py from the JBL Portable app's model data.",
              "// Do not edit by hand.", "", "namespace JBLControlKit.Windows;", "",
              "public static class GeneratedCatalog", "{"]
    for key, presets in sorted(cs_preset_sets.items()):
        csharp += [f"    public static readonly EQPreset[] {key} = {{", *presets, "    };", ""]
    csharp += ["    public static readonly SpeakerModel[] Models = {", *cs_lines, "    };", "}", ""]
    WIN_OUT.write_text("\n".join(csharp))

    doc = [
        "# Supported models", "",
        "Generated by `scripts/generate-catalog.py`. Don't edit by hand.", "",
        "| Model | PID | Support | EQ |", "|---|---|---|---|",
    ]
    for _, name, pid, sup, fam in sorted(rows):
        doc.append(f"| {name} | `{pid}` | {SUPPORT_LABEL[sup]} | {FAMILY_EQ[fam]} |")
    doc += [
        "",
        "- **Verified**: reads and EQ writes confirmed byte for byte on real hardware.",
        "- **Beta**: protocol from the JBL Portable app. Battery/info and EQ reads are safe; EQ changes need",
        "  *Allow Experimental EQ* until someone confirms them.",
        "- **Experimental**: newer frame format or transport nobody has tested from a Mac yet.",
        "- **Unsupported**: Wi-Fi models and classic-Bluetooth-only speakers can't be reached over BLE.",
        "",
        "Own one of the non-verified models? Open JBLControl, choose **••• → Copy Diagnostics**, and paste it into a",
        "[device report](../.github/ISSUE_TEMPLATE/device-report.yml). That's usually all it takes to verify a model.",
        "",
    ]
    DOC.write_text("\n".join(doc))
    print(f"wrote {OUT.relative_to(ROOT)} and {WIN_OUT.relative_to(ROOT)}: {len(lines)} models, {len(preset_sets)} preset sets")


if __name__ == "__main__":
    main()
