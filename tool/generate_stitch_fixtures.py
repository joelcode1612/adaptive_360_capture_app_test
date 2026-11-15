"""Generates real JPEG fixtures for the incremental-stitching tests.

The fixtures are crops of one synthetic, texture-rich scene, so the overlap
relationships are exactly known:

    pair_a / pair_b        800x640 crops sharing a 300 px band -> registration
                           and pairwise stitching must succeed.
    no_overlap_a / b       800x640 crops of *disjoint* scene regions -> no
                           shared features, registration must fail.
    blur_a / blur_b        the overlapping pair, strongly blurred -> the
                           quality gate must fail them before matching.
    strip_1..strip_5       five overlapping crops for the final-panorama
                           success test.

Re-run after changing the generator:

    python tool/generate_stitch_fixtures.py

Deterministic: the RNG is seeded, so the committed JPEGs are reproducible.
"""

from __future__ import annotations

import os
import random

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "test", "fixtures", "stitch"))

W, H = 800, 640


def build_scene(width: int, height: int, seed: int) -> Image.Image:
    """A texture-rich scene: gradients, random dots, shapes and text."""
    rng = random.Random(seed)
    scene = Image.new("RGB", (width, height))
    px = scene.load()
    # Horizontal colour gradient so every region carries low-frequency signal.
    for x in range(width):
        r = 40 + (x * 140) // max(width - 1, 1)
        g = 60 + (x * 90) // max(width - 1, 1)
        b = 100 + ((x * 60) // max(width - 1, 1))
        for y in range(height):
            px[x, y] = (r, g, b)
    draw = ImageDraw.Draw(scene)
    # Dense random dots: high-frequency corners for ORB.
    for _ in range(width * height // 55):
        x, y = rng.randrange(width), rng.randrange(height)
        v = rng.randrange(0, 255)
        draw.point((x, y), fill=(v, v, v))
    # Distinct shapes per band so disjoint regions are truly dissimilar.
    for _ in range(220):
        x, y = rng.randrange(width), rng.randrange(height)
        w, h = rng.randint(10, 60), rng.randint(10, 60)
        shade = rng.randint(0, 255)
        if rng.random() < 0.5:
            draw.ellipse((x, y, x + w, y + h), outline=(shade, shade, shade), width=2)
        else:
            draw.rectangle((x, y, x + w, y + h), outline=(shade, shade, shade), width=2)
    return scene


def crop_to(scene: Image.Image, x0: int) -> Image.Image:
    return scene.crop((x0, 0, x0 + W, min(H, scene.height)))


def laplacian_variance_estimate(image: Image.Image) -> float:
    """A rough Laplacian variance without OpenCV, for fixture sanity checks."""
    gray = image.convert("L")
    w, h = gray.size
    px = gray.load()
    acc = 0.0
    acc2 = 0.0
    n = 0
    for y in range(1, h - 1, 4):
        for x in range(1, w - 1, 4):
            lap = 4 * px[x, y] - px[x - 1, y] - px[x + 1, y] - px[x, y - 1] - px[x, y + 1]
            acc += lap
            acc2 += lap * lap
            n += 1
    mean = acc / n
    return acc2 / n - mean * mean


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    # One very wide scene for the overlapping pair and the blur pair.
    scene = build_scene(2600, H, seed=1234)
    # A second, independently generated scene for the no-overlap pair: a
    # different seed produces different texture everywhere, so nothing can
    # accidentally match even though both halves look "textured".
    other = build_scene(2600, H, seed=987654)

    def save(image: Image.Image, name: str, *, blur: int = 0) -> None:
        if blur:
            image = image.filter(ImageFilter.GaussianBlur(blur))
        image.save(os.path.join(OUT, name), quality=90)
        print(f"{name:24s} lap-var≈{laplacian_variance_estimate(image):9.1f}")

    save(crop_to(scene, 0), "pair_a.jpg")
    save(crop_to(scene, 500), "pair_b.jpg")            # 300 px overlap with pair_a
    save(crop_to(scene, 0), "blur_a.jpg", blur=14)
    save(crop_to(scene, 500), "blur_b.jpg", blur=14)
    save(crop_to(other, 0), "no_overlap_a.jpg")
    save(crop_to(other, 1300), "no_overlap_b.jpg")     # disjoint regions

    # Five-image strip for the final-panorama test: steps of 300 px give
    # 500 px overlap between neighbours, comfortably inside Stitcher's
    # confidence requirements.
    for i in range(5):
        save(crop_to(scene, 200 * i), f"strip_{i + 1}.jpg")

    print(f"\nfixtures written to {OUT}")


if __name__ == "__main__":
    main()
