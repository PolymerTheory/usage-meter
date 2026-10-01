#!/usr/bin/env python
"""Generate script/AppIcon.icns: the menu-bar glyph (four usage bars) on a dark
rounded square. Tools like Bartender show the *app* icon for a menu-bar item, so
without one UsageMeter appears as a blank square.

Usage: python script/make_icon.py   (needs Pillow and macOS `iconutil`)
"""
import os
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "AppIcon.icns")

SIZE = 1024
# Default bar colors (match MeterColors.default) and illustrative heights.
BARS = [("#34C759", 0.42), ("#FFCC00", 0.68), ("#FF3B30", 0.90), ("#34C759", 0.30)]


def render(size: int) -> Image.Image:
    scale = 4  # supersample for smooth edges
    s = size * scale
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # macOS-style rounded square with the standard inset.
    inset = s * 0.10
    d.rounded_rectangle([inset, inset, s - inset, s - inset], radius=s * 0.18, fill="#1E2230")

    left, right = s * 0.25, s * 0.75
    base, top = s * 0.74, s * 0.26
    gap = (right - left) * 0.09
    bar_w = ((right - left) - gap * (len(BARS) - 1)) / len(BARS)
    for i, (color, frac) in enumerate(BARS):
        x0 = left + i * (bar_w + gap)
        y0 = base - (base - top) * frac
        d.rounded_rectangle([x0, y0, x0 + bar_w, base], radius=bar_w * 0.22, fill=color)

    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    master = render(SIZE)
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for pts in (16, 32, 128, 256, 512):
            for mult in (1, 2):
                px = pts * mult
                name = f"icon_{pts}x{pts}{'@2x' if mult == 2 else ''}.png"
                master.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", OUT], check=True)
    master.resize((256, 256), Image.LANCZOS).save(os.path.join(HERE, "AppIcon-preview.png"))
    print("wrote", OUT)


if __name__ == "__main__":
    main()
