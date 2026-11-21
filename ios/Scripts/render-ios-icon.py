#!/usr/bin/env python3
"""Derive the iPhone app icon from the Mac app icon, so both come from one artwork.

The Mac icon is the product artwork on a rounded tile with a transparent margin.
iOS wants a full, opaque square and rounds the corners itself. This takes the
tile, fills its corners with the tile's own background (read row by row from a
column of the tile that the artwork does not reach) and scales it to 1024.
Nothing is redrawn. Run after scripts/render-dictate-artwork.py changes the Mac icon.
"""
from pathlib import Path
import sys

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
MAC = ROOT / "VoiceInk/Assets.xcassets/AppIcon.appiconset/mac-1024.png"
OUT = ROOT / "ios/Brand/Assets.xcassets/AppIcon.appiconset/ios-1024.png"


def main():
    mac = Image.open(MAC).convert("RGBA")
    if mac.size != (1024, 1024):
        sys.exit("render-ios-icon: the Mac icon must be 1024 by 1024")
    # The opaque tile, without its margin and shadow.
    box = mac.getchannel("A").point(lambda a: 255 if a > 250 else 0).getbbox()
    if box is None or box[2] - box[0] != box[3] - box[1]:
        sys.exit("render-ios-icon: the Mac icon's tile is not square")
    tile = mac.crop(box)
    side = tile.size[0]
    # One column a fifth of the way in: left of the artwork, and opaque for all but a
    # few rows at the rounded top and bottom, which take the nearest opaque row.
    column = [tile.getpixel((side // 5, y)) for y in range(side)]
    opaque = [y for y, pixel in enumerate(column) if pixel[3] == 255]
    if not opaque or opaque[-1] - opaque[0] < side * 0.98:
        sys.exit("render-ios-icon: the Mac icon's tile background could not be read")
    ramp = Image.new("RGB", (1, side))
    ramp.putdata([column[min(max(y, opaque[0]), opaque[-1])][:3] for y in range(side)])
    square = ramp.resize((side, side)).convert("RGBA")
    square.alpha_composite(tile)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    square.convert("RGB").resize((1024, 1024), Image.LANCZOS).save(OUT, optimize=True)
    print(f"wrote {OUT.relative_to(ROOT)} from {MAC.relative_to(ROOT)} (tile {box})")


if __name__ == "__main__":
    main()
