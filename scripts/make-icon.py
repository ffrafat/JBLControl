#!/usr/bin/env python3
"""Generate Resources/AppIcon.icon, the app's Liquid Glass icon (Icon Composer format).

A graphite speaker (Resources/Icon/speaker-shape.svg) with the gap under its handle cut through, three
EQ sliders with orange knobs on its front, on the sunset gradient. Usage: scripts/make-icon.py
The result opens in Icon Composer for fine-tuning; build-app.sh compiles it with actool.
"""

import json
import os
import re

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SOURCE = os.path.join(ROOT, "Resources/Icon/speaker-shape.svg")
OUT = os.path.join(ROOT, "Resources/AppIcon.icon")

# The source is a 1200×592 stencil: a rectangle with the speaker cut out (path 1), plus the handle gap (path 2).
outer, handle_gap = re.findall(r'<path d="([^"]+)"', open(SOURCE).read())
outline = outer[outer.index("M", 1):]  # drop the surrounding rectangle, keep the speaker outline

SCALE = 0.80
TX, TY = (1024 - 1200 * SCALE) / 2, (1024 - 592 * SCALE) / 2 + 10


def doc(inner):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">{inner}</svg>'


def canvas(x, y):
    """Artwork coordinates → icon canvas."""
    return TX + x * SCALE, TY + y * SCALE


def eq_sliders():
    cx, cy = canvas(600, 345)  # centre of the speaker's front
    parts = []
    for i, knob in enumerate((-44, 50, -11)):
        x = cx + (i - 1) * 122
        parts.append(f'<rect x="{x - 10:.0f}" y="{cy - 105:.0f}" width="20" height="210" rx="10" fill="#FFFFFF" fill-opacity="0.85"/>')
        parts.append(f'<circle cx="{x:.0f}" cy="{cy + knob:.0f}" r="33" fill="#FF6A1F"/>')
    return "".join(parts)


def main():
    os.makedirs(os.path.join(OUT, "Assets"), exist_ok=True)
    body = f'<g transform="translate({TX:.1f} {TY:.1f}) scale({SCALE})">' \
           f'<path d="{outline} {handle_gap}" fill="#4A4A50" fill-rule="evenodd"/></g>'
    open(os.path.join(OUT, "Assets/body.svg"), "w").write(doc(body))
    open(os.path.join(OUT, "Assets/controls.svg"), "w").write(doc(eq_sliders()))

    p3 = lambda r, g, b: f"display-p3:{r:.5f},{g:.5f},{b:.5f},1.00000"
    icon = {
        "fill": {"linear-gradient": [p3(1.00, 0.58, 0.16), p3(0.90, 0.18, 0.20)]},
        "groups": [
            {"layers": [{"image-name": "controls.svg", "name": "eq", "glass": True}],
             "shadow": {"kind": "neutral", "opacity": 0.4}, "translucency": {"enabled": False, "value": 0}},
            {"layers": [{"image-name": "body.svg", "name": "speaker", "glass": True}],
             "shadow": {"kind": "neutral", "opacity": 0.5}, "translucency": {"enabled": True, "value": 0.15}},
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    json.dump(icon, open(os.path.join(OUT, "icon.json"), "w"), indent=2)
    print("wrote", os.path.relpath(OUT, ROOT))


if __name__ == "__main__":
    main()
