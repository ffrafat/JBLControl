#!/usr/bin/env python3
"""Generate Resources/AppIcon.icon, the app's Liquid Glass icon (Icon Composer format).

A speaker with EQ bars rising out of it, on a sunset gradient. Usage: scripts/make-icon.py
The result opens in Icon Composer for fine-tuning; build-app.sh compiles it with actool.
"""

import json, os

def bar(x, top, w, bottom):
    r = w / 2
    # Rounded top, square bottom (the bottom is hidden inside the speaker).
    return (f'<path d="M{x},{bottom} L{x},{top + r} A{r},{r} 0 0 1 {x + w},{top + r} '
            f'L{x + w},{bottom} Z" fill="#FFFFFF"/>')

def make(name, gradient, out_dir="."):
    d = os.path.join(out_dir, f"{name}.icon")
    os.makedirs(f"{d}/Assets", exist_ok=True)
    open(f"{d}/Assets/body.svg", "w").write(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
        '<rect x="152" y="540" width="720" height="260" rx="130" fill="#FFFFFF"/></svg>')
    # End-cap seams, like the bumpers on a Flip/Charge.
    open(f"{d}/Assets/seams.svg", "w").write(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
        '<rect x="262" y="556" width="16" height="228" rx="8" fill="#000000"/>'
        '<rect x="746" y="556" width="16" height="228" rx="8" fill="#000000"/></svg>')
    w, gap, bottom = 92, 30, 560
    tops = (470, 350, 260, 390, 320)
    x0 = 512 - (5 * w + 4 * gap) / 2
    bars = "".join(bar(round(x0 + i * (w + gap)), t, w, bottom) for i, t in enumerate(tops))
    open(f"{d}/Assets/bars.svg", "w").write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">{bars}</svg>')
    icon = {
        "fill": {"linear-gradient": gradient},
        "groups": [
            {"layers": [
                {"image-name": "seams.svg", "name": "seams", "glass": False, "opacity": 0.12},
                {"image-name": "body.svg", "name": "speaker", "glass": True},
             ],
             "shadow": {"kind": "neutral", "opacity": 0.5}, "translucency": {"enabled": True, "value": 0.3}},
            {"layers": [{"image-name": "bars.svg", "name": "eq", "glass": True, "opacity": 0.9}],
             "shadow": {"kind": "neutral", "opacity": 0.4}, "translucency": {"enabled": True, "value": 0.5}},
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    json.dump(icon, open(f"{d}/icon.json", "w"), indent=2)
    return d

if __name__ == "__main__":
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources")
    p3 = lambda r, g, b: f"display-p3:{r:.5f},{g:.5f},{b:.5f},1.00000"
    path = make("AppIcon", [p3(1.00, 0.58, 0.16), p3(0.90, 0.18, 0.20)], out_dir=root)
    print("wrote", os.path.relpath(path))
