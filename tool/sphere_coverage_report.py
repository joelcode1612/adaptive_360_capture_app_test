"""Reproducible geometry check for the 3DoF sphere capture.

Calculates, for a target layout and a camera field of view, the spherical
coverage the layout actually produces. This is the evidence behind the claim
that 38 directions cover the sphere at the device's measured FOV, and the
sensitivity table shows how much margin there is on a narrower lens.

It is deliberately independent of the Dart code: it re-derives the layout from
the same table and the same `sphereDirection` convention, so a change to one
without the other shows up as a disagreement rather than passing silently.

Usage:
    python tool/sphere_coverage_report.py

Output columns
    single   area-weighted share of the sphere covered by >= 1 photograph
    double   ... by >= 2      triple ... by >= 3
    redund.  the worst frame's own area that is *also* covered by another frame
    PASS/FAIL is single >= 99.5 % and redund. >= 5 %

Area weighting matters: an equirectangular row at latitude phi covers cos(phi)
of what an equatorial row covers, so an unweighted pixel count overstates
coverage near the poles — exactly where a sparse layout leaves holes.
"""

import math
import sys

import numpy as np

# ── layouts ────────────────────────────────────────────────────────────────
# The 38-target layout the app builds: 12 per ring at 30 deg, rings at 0/+45/
# -45, zenith at id 13, nadir at 38.
def layout38():
    middle = [0, 30, 60, 90, 120, 150, 180, -150, -120, -90, -60, -30]
    upper = [-30, -60, -90, -120, -150, 180, 150, 120, 90, 60, 30, 0]
    lower = list(middle)
    out = [(y, 0) for y in middle]
    out.append((0, 90))
    out += [(y, 45) for y in upper]
    out += [(y, -45) for y in lower]
    out.append((0, -90))
    return out


# The 26-target template, kept only as a mathematical baseline for comparison.
def layout26():
    yaws = [0, 45, 90, 135, 180, -135, -90, -45]
    out = [(y, 0) for y in yaws]
    out += [(y, 30) for y in yaws]
    out += [(y, -30) for y in yaws]
    out += [(0, 90), (0, -90)]
    return out


# ── geometry ───────────────────────────────────────────────────────────────
def qmat(yaw_deg, pitch_deg):
    """Rotation taking the camera frame into the sphere frame.

    Matches `Quat.fromYawPitch(-yaw, -pitch)`: it maps the camera's optical
    axis (0, 0, -1) onto `sphereDirection(yaw, pitch)`.
    """
    y = math.radians(-yaw_deg)
    p = math.radians(-pitch_deg)
    Ry = np.array(
        [[math.cos(y), 0, math.sin(y)], [0, 1, 0], [-math.sin(y), 0, math.cos(y)]]
    )
    Rx = np.array(
        [[1, 0, 0], [0, math.cos(p), -math.sin(p)], [0, math.sin(p), math.cos(p)]]
    )
    return Ry @ Rx


def sphere_dirs(width=720, height=360):
    lon = (np.arange(width) + 0.5) / width * 2 * math.pi - math.pi
    lat = math.pi / 2 - (np.arange(height) + 0.5) / height * math.pi
    coslat = np.cos(lat)[:, None]
    dirs = np.stack(
        [
            np.sin(lon)[None, :] * coslat,
            np.broadcast_to(np.sin(lat)[:, None], (height, width)),
            -np.cos(lon)[None, :] * coslat,
        ],
        axis=-1,
    )
    return dirs, np.cos(lat)


def contains(R, dirs, hfov_deg, vfov_deg):
    """Which sphere directions fall inside a frame with this FOV."""
    v = dirs @ R  # world -> camera (R^T applied on the right)
    depth = -v[..., 2]
    tx = math.tan(math.radians(hfov_deg) / 2)
    ty = math.tan(math.radians(vfov_deg) / 2)
    safe = np.maximum(depth, 1e-6)
    return (
        (depth > 0.05)
        & (np.abs(v[..., 0] / safe) <= tx)
        & (np.abs(v[..., 1] / safe) <= ty)
    )


def frame_footprint(R, hfov_deg, vfov_deg, n=33):
    """Sample directions inside one frame, for the redundancy check."""
    tx = math.tan(math.radians(hfov_deg) / 2)
    ty = math.tan(math.radians(vfov_deg) / 2)
    xs = np.linspace(-tx, tx, n)
    ys = np.linspace(-ty, ty, n // 2 + 1)
    gx, gy = np.meshgrid(xs, ys)
    cam = np.stack([gx.ravel(), gy.ravel(), -np.ones(gx.size)], axis=-1)
    cam /= np.linalg.norm(cam, axis=-1, keepdims=True)
    return cam @ R.T


def report(name, layout, hfov, vfov, quiet=False):
    dirs, row_w = sphere_dirs()
    hits = np.zeros(dirs.shape[:2], np.uint8)
    mats = [qmat(y, p) for (y, p) in layout]
    for R in mats:
        hits += contains(R, dirs, hfov, vfov).astype(np.uint8)

    total = row_w.sum() * dirs.shape[1]
    single = (row_w[:, None] * (hits >= 1)).sum() / total
    double = (row_w[:, None] * (hits >= 2)).sum() / total
    triple = (row_w[:, None] * (hits >= 3)).sum() / total

    # Redundancy per frame: how much of its own footprint another frame covers.
    worst, worst_id = 1.0, 0
    for i, R in enumerate(mats):
        pts = frame_footprint(R, hfov, vfov)
        covered_by_others = np.zeros(len(pts), bool)
        for j, R2 in enumerate(mats):
            if i == j:
                continue
            covered_by_others |= contains(R2, pts, hfov, vfov)
        frac = covered_by_others.mean()
        if frac < worst:
            worst, worst_id = frac, i + 1

    ok = single >= 0.995 and worst >= 0.05
    if not quiet:
        print(
            f"{name:<10} {len(layout):>3}  {hfov:5.2f}x{vfov:5.2f}  "
            f"{single * 100:6.2f}  {double * 100:6.2f}  {triple * 100:6.2f}  "
            f"{worst * 100:6.1f} (#{worst_id:<2})  "
            f"{'PASS' if ok else 'FAIL: ' + ('hole' if single < 0.995 else 'thin overlap')}"
        )
    return ok, single, double, triple, worst


def main():
    cases = [
        (53.13, 67.38),  # measured still (3072x4096, 26 mm-equivalent)
        (45.0, 65.0),
        (40.0, 55.0),
        (35.0, 50.0),
        (30.0, 40.0),
    ]
    print(
        f"{'layout':<10} {'n':>3}  {'FOV h x v':>11}  "
        f"{'single':>6}  {'double':>6}  {'triple':>6}  {'redund.':>9}  verdict"
    )
    failures = 0
    for layout_name, layout in (("38-target", layout38()), ("26-baseline", layout26())):
        for hfov, vfov in cases:
            ok, *_ = report(layout_name, layout, hfov, vfov)
            if not ok:
                failures += 1
        print()
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
