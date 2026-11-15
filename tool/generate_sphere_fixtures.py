"""Generates portrait 3:4 JPEG fixtures for the sphere stitcher test.

Each of the 38 fixtures is a textured portrait 768x1024 (3:4) frame whose
dominant hue encodes its target id, so a projected panorama's colours reveal
which photograph supplied each region. The content does not need to be
geometrically consistent — the sphere stitcher is orientation-driven, so the
frames only have to decode and contribute real pixels.

Usage:
    python tool/generate_sphere_fixtures.py
"""

from __future__ import annotations

import colorsys
import os
import random

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "test", "fixtures", "sphere"))

W, H = 768, 1024  # portrait 3:4


def frame(target_id: int) -> Image.Image:
    rng = random.Random(1000 + target_id)
    hue = (target_id * 137.508) % 360.0  # golden-angle spread
    r, g, b = colorsys.hsv_to_rgb(hue / 360.0, 0.45, 0.85)
    base = (int(r * 255), int(g * 255), int(b * 255))
    img = Image.new("RGB", (W, H), base)
    draw = ImageDraw.Draw(img)
    # Dense texture so the projection has real pixels everywhere.
    for _ in range(W * H // 120):
        x, y = rng.randrange(W), rng.randrange(H)
        v = rng.randrange(0, 255)
        draw.point((x, y), fill=(v, v, v))
    for _ in range(90):
        x, y = rng.randrange(W - 60), rng.randrange(H - 60)
        w, h = rng.randint(12, 60), rng.randint(12, 60)
        shade = rng.randint(0, 255)
        if rng.random() < 0.5:
            draw.ellipse((x, y, x + w, y + h), outline=(shade,) * 3, width=2)
        else:
            draw.rectangle((x, y, x + w, y + h), outline=(shade,) * 3, width=2)
    # The target id, large and unmistakable.
    draw.text((24, 24), f"T{target_id:02d}", fill=(255, 255, 255))
    return img


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    for target_id in range(1, 39):
        frame(target_id).save(
            os.path.join(OUT, f"target_{target_id:02d}.jpg"), quality=78
        )
    print(f"38 portrait 3:4 fixtures written to {OUT}")


if __name__ == "__main__":
    main()
