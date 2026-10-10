#!/usr/bin/env python3
"""Generate Resources/AppIcon.icon, the app's Liquid Glass icon (Icon Composer format).

A black Flip-style speaker seen at three-quarters, passive radiator on its end cap and an
orange logo plate carrying EQ bars, on a sunset gradient. Usage: scripts/make-icon.py
The result opens in Icon Composer for fine-tuning; build-app.sh compiles it with actool.
"""

import json, os

TILT = 'transform="rotate(-10 512 520)"'
XL, XR, CY, RY, RX = 196, 806, 520, 172, 78   # cylinder axis ends, center y, radius, end-face perspective

def svg(inner):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><g {TILT}>{inner}</g></svg>'

def make(name, d_out, body, face, radiator, hub, badge, gradient):
    d = os.path.join(d_out, f"{name}.icon"); os.makedirs(f"{d}/Assets", exist_ok=True)
    top, bot = CY - RY, CY + RY
    files = {
        # Fabric-covered body: straight top/bottom, rounded far end.
        "body.svg": svg(f'<path d="M{XL},{top} L{XR},{top} L{XR},{bot} L{XL},{bot} A{RX},{RY} 0 0 1 {XL},{top} Z" fill="{body}"/>'),
        # Near end cap: rubber bumper face with the passive radiator.
        "endcap.svg": svg(f'<ellipse cx="{XR}" cy="{CY}" rx="{RX}" ry="{RY}" fill="{face}"/>'),
        "radiator.svg": svg(f'<ellipse cx="{XR}" cy="{CY}" rx="{RX*0.66:.0f}" ry="{RY*0.66:.0f}" fill="{radiator}"/>'),
        "hub.svg": svg(f'<ellipse cx="{XR}" cy="{CY}" rx="{RX*0.28:.0f}" ry="{RY*0.28:.0f}" fill="{hub}"/>'),
        # Logo plate on the side, with EQ bars instead of a wordmark.
        "badge.svg": svg(f'<rect x="{(XL+XR)/2-148:.0f}" y="{CY-78}" width="296" height="156" rx="38" fill="{badge}"/>'),
        "bars.svg": svg("".join(
            f'<rect x="{(XL+XR)/2-108+i*48:.0f}" y="{CY+48-h}" width="28" height="{h}" rx="14" fill="#FFFFFF"/>'
            for i, h in enumerate((42, 72, 100, 62, 84)))),
        # Rubber bumper on the far end.
        "bumper.svg": svg(f'<path d="M{XL+34},{top-2} L{XL+6},{top-2} A{RX},{RY+2} 0 0 0 {XL+6},{bot+2} L{XL+34},{bot+2} Z" fill="{face}"/>'),
    }
    for f, c in files.items(): open(f"{d}/Assets/{f}", "w").write(c)
    shadow = {"kind": "neutral", "opacity": 0.5}
    icon = {
        "fill": {"linear-gradient": gradient},
        "groups": [
            {"layers": [{"image-name": "bars.svg", "name": "bars", "glass": False},
                        {"image-name": "badge.svg", "name": "badge", "glass": True}],
             "shadow": shadow, "translucency": {"enabled": False, "value": 0}},
            {"layers": [{"image-name": "hub.svg", "name": "hub", "glass": True},
                        {"image-name": "radiator.svg", "name": "radiator", "glass": True},
                        {"image-name": "endcap.svg", "name": "endcap", "glass": True}],
             "shadow": shadow, "translucency": {"enabled": True, "value": 0.2}},
            {"layers": [{"image-name": "bumper.svg", "name": "bumper", "glass": True},
                        {"image-name": "body.svg", "name": "body", "glass": True}],
             "shadow": shadow, "translucency": {"enabled": True, "value": 0.2}},
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    json.dump(icon, open(f"{d}/icon.json", "w"), indent=2)
    return d

p3 = lambda r, g, b: f"display-p3:{r:.5f},{g:.5f},{b:.5f},1.00000"
SUNSET = [p3(1.00, 0.58, 0.16), p3(0.90, 0.18, 0.20)]

if __name__ == "__main__":
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources")
    path = make("AppIcon", root, body="#1E1E22", face="#3A3A40", radiator="#121214", hub="#4A4A52",
                badge="#FF5A1F", gradient=SUNSET)
    print("wrote", os.path.relpath(path))
