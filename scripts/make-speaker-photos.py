#!/usr/bin/env python3
"""Builds the bundled speaker photos in Resources/SpeakerPhotos from scripts/speaker-photos.json.

Each photo is downloaded from JBL's image CDN, turned so cylinder speakers lie on their side, scaled to
256x256 and compressed with pngquant. index.json maps product ID and color code to a file name; both apps
read it. Needs ImageMagick (magick) and pngquant: brew install imagemagick pngquant.

    scripts/make-speaker-photos.py           # only photos not built yet
    scripts/make-speaker-photos.py --force   # rebuild all
"""
import json
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "scripts" / "speaker-photos.json"
OUT = ROOT / "Resources" / "SpeakerPhotos"
CDN = "https://www.jbl.com/dw/image/v2/BFND_PRD/on/demandware.static/-/Sites-masterCatalog_Harman/default/"
SIZE = 256  # The artwork is 104 pt; this covers 2x displays with room for the cylinder zoom.


def file_name(path: str) -> str:
    """dwf90f0f82/JBL_FLIP_7_HERO_BLACK_060_x2.png -> jbl_flip_7_hero_black_060_x2.png"""
    return path.split("/", 1)[1].lower()


def run(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def build(path: str, form_factor: str, dest: Path) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        original = Path(tmp) / "original.png"
        request = urllib.request.Request(CDN + path, headers={"User-Agent": "JBLControl-build"})
        with urllib.request.urlopen(request, timeout=60) as response:
            original.write_bytes(response.read())

        # Cylinder speakers are drawn lying down. Some product shots stand them upright; turn those.
        rotate = []
        if form_factor == "cylinder":
            width, height = (int(v) for v in run("magick", str(original), "-trim", "-format", "%w %h", "info:").split())
            if height > width:
                rotate = ["-rotate", "90"]

        resized = Path(tmp) / "resized.png"
        run("magick", str(original), "-background", "none", *rotate, "-resize", f"{SIZE}x{SIZE}",
            "-gravity", "center", "-extent", f"{SIZE}x{SIZE}", "-strip", str(resized))
        run("pngquant", "--quality=70-95", "--speed=1", "--strip", "--force", "--output", str(dest), str(resized))


def main() -> None:
    force = "--force" in sys.argv
    sources = json.loads(SOURCES.read_text())
    OUT.mkdir(parents=True, exist_ok=True)

    index: dict[str, dict[str, str]] = {}
    wanted: dict[str, tuple[str, str]] = {}
    for product_id, entry in sources.items():
        index[product_id] = {}
        for color, path in entry["colors"].items():
            name = file_name(path)
            index[product_id][color] = name
            wanted[name] = (path, entry["formFactor"])

    for name, (path, form_factor) in sorted(wanted.items()):
        dest = OUT / name
        if dest.exists() and not force:
            continue
        print("building", name)
        build(path, form_factor, dest)

    for stale in OUT.glob("*.png"):
        if stale.name not in wanted:
            print("removing", stale.name)
            stale.unlink()

    (OUT / "index.json").write_text(json.dumps(index, indent=1, sort_keys=True) + "\n")
    total = sum(f.stat().st_size for f in OUT.glob("*.png"))
    print(f"{len(wanted)} photos, {total / 1024:.0f} KB")


if __name__ == "__main__":
    main()
