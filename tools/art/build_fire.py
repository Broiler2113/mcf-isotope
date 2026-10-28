#!/usr/bin/env python3
"""Fire seen from above for the battle screen (issues-12 #18), in the first-person pipeline's
look: modelled at 8x, lit by its own heat, averaged down to 32 px a metre.

    <venv with numpy + pillow>/bin/python tools/art/build_fire.py      # from the project root

Writes textures/decals/fire/fire.png: one burning cell, periodic so a spreading fire joins up
without seams. Hot white-yellow cores where the fuel burns, orange tongues licking outward
and curling, dark red at their tips, the floor showing through the gaps; a few embers.
The first-person flames stay textures/first_person/fire.png (build_first_person.py).
"""
import os, sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))
from build_first_person import noise, blur, sstep, mix, col, rgb, down, M, SS, PX  # noqa: E402

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]


def wrapped_blob(x, y, cx, cy, r):
    """A soft round heap of heat centred at (cx, cy) on a 1 m torus."""
    dx = np.minimum(np.abs(x - cx), 1 - np.abs(x - cx))
    dy = np.minimum(np.abs(y - cy), 1 - np.abs(y - cy))
    return np.exp(-(dx * dx + dy * dy) / (2 * r * r))


def fire_top():
    h = w = PX * SS
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    x, y = (xs + 0.5) / M, (ys + 0.5) / M
    # Where it burns: a dozen flames of every size scattered over the cell, each a hot core in
    # an orange halo, nudged about by turbulence; ragged edges let the floor show between them.
    # Neighbouring cells are turned their own ways by the board, so a spread fire never tiles.
    wx = noise(h, w, 1801, 0.1) * 0.05
    wy = noise(h, w, 1802, 0.1) * 0.05
    rng = np.random.default_rng(1810)
    heat = np.zeros((h, w), np.float32)
    for i in range(13):
        cx, cy = rng.uniform(0.18, 0.82, 2)
        r = rng.uniform(0.05, 0.13)
        heat += rng.uniform(0.45, 1.0) * wrapped_blob(x + wx, y + wy, cx, cy, r)
    ragged = 0.6 * noise(h, w, 1803, 0.06) + 0.4 * noise(h, w, 1804, 0.025)
    heat = heat * 0.95 + 0.14 * ragged - 0.22
    heat = blur(heat, 0.006)
    t = np.clip(heat / 1.4, 0, 1)
    stops = [(0.0, "4a0a03"), (0.18, "a8260a"), (0.4, "e0561a"), (0.62, "f8962a"), (0.82, "ffd35a"), (1.0, "fff6c8")]
    c = col(rgb(stops[0][1]), h, w)
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        inside = (t >= t0) & (t <= t1)
        c = np.where(inside[..., None], mix(col(rgb(c0), h, w), col(rgb(c1), h, w), (t - t0) / (t1 - t0)), c)
    # The floor shows between the tongues; their thin red tips are half see-through.
    a = sstep(0.04, 0.16, heat) * (0.6 + 0.4 * sstep(0.15, 0.45, heat))
    # Embers: bright specks where the heat is low, glowing on their own.
    rng = np.random.default_rng(1806)
    ember = (rng.random((h, w)) < 0.0005).astype(np.float32)
    ember = np.clip(blur(ember, 0.005) * 70, 0, 1) * (1 - sstep(0.1, 0.4, heat))
    c = mix(c, rgb("ffb040"), ember)
    a = np.maximum(a, ember * 0.95)
    return np.concatenate([c, a[..., None]], -1)


def main():
    a = down(fire_top())
    out = ROOT / "textures/decals/fire/fire.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA").save(out)
    print("fire written to", out)


if __name__ == "__main__":
    main()
