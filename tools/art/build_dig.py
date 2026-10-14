"""Station and asteroid digging (0.12.1): rubble piles and trenches cut into the deck.

    /root/.venvs/mcf-rl/bin/python tools/art/build_dig.py   # from the project root
    godot --headless --import

On those maps soldiers dig through the floor plating, not ground (owner):
- textures/walls/rubble/rubble_autotile.png — the dug-out pile: crushed deck, floor-plate
  scraps, bent bars (TerrainTiles.pile_art; "Rubble Pile" in the game).
- textures/features/trench_station/ and trench_asteroid/ — the trench: a ragged cut in the
  plating over the sub-floor.
Each file is several 16-tile sheets (mask N1 E2 S4 W8, core.sheet_from) stacked top to bottom:
TerrainTiles picks one per cell, so long piles and trenches don't repeat. Anything that
crosses a cell edge — the ground bed, the ragged outline — repeats every cell, so tiles of
different variants still join without a seam; the loose pieces stay inside their cell.
"""
import math, os, sys
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(__file__))
from core import *

VARIANTS = 6
TAU = 2 * math.pi


def cells(w, h):
    for i in range(w):
        for j in range(h):
            yield i, j


def ripple(x, y, seed):
    """Smooth noise that repeats every cell (integer frequencies), about -1..1."""
    r = np.random.default_rng(seed)
    out = np.zeros_like(x)
    for fx, fy in ((1, 2), (2, 1), (3, 2), (2, 3), (4, 5), (5, 3)):
        a, b = r.uniform(0, TAU, 2)
        out += np.sin(TAU * fx * x + a) * np.cos(TAU * fy * y + b) / (fx + fy) * 2.2
    return np.clip(out, -1, 1)


def gravel(color, contrast, seed, grains=12, gloss=0.1):
    """Fine grit that repeats every cell: a grains x grains grid of random tones per cell,
    smoothed. No low frequencies, so the repetition never shows as a pattern."""
    base = np.asarray(color, np.float32)
    grid = np.random.default_rng(seed).uniform(-1, 1, (grains, grains)).astype(np.float32)

    def f(x, y, s):
        gx = (x % 1.0) * grains
        gy = (y % 1.0) * grains
        x0 = np.floor(gx).astype(int) % grains
        y0 = np.floor(gy).astype(int) % grains
        fx = gx - np.floor(gx)
        fy = gy - np.floor(gy)
        x1 = (x0 + 1) % grains
        y1 = (y0 + 1) % grains
        n = (grid[y0, x0] * (1 - fx) * (1 - fy) + grid[y0, x1] * fx * (1 - fy)
             + grid[y1, x0] * (1 - fx) * fy + grid[y1, x1] * fx * fy)
        return np.clip(base[None, None, :] * (1 + n * contrast)[..., None], 0, 1), gloss
    return f


def periodic(color, contrast, seed, gloss=0.1, fine=0.0):
    """A material whose grain repeats every cell (seamless across joined tiles)."""
    base = np.asarray(color, np.float32)

    def f(x, y, s):
        n = ripple(x, y, seed) * contrast
        if fine:
            n = n + fine * np.sin(TAU * 13 * x + 1.7) * np.sin(TAU * 11 * y + 0.4)
        return np.clip(base[None, None, :] * (1 + n)[..., None], 0, 1), gloss
    return f


def ragged(cv, x0, y0, x1, y1, r, amp, seed):
    """Signed distance of a rounded box whose border wobbles (repeats every cell)."""
    return cv._rrect_sd(x0, y0, x1, y1, r) + amp * ripple(cv.x, cv.y, seed)


def tread(color):
    """Diamond tread plate: the station's floor, broken up."""
    base = np.asarray(color, np.float32)

    def f(x, y, seed):
        u = (x * 14.0) % 1.0
        v = (y * 14.0) % 1.0
        bump = (np.abs(u - v) < 0.12) | (np.abs(u + v - 1.0) < 0.12)
        return np.clip(base[None, None, :] * (1.0 + 0.09 * bump)[..., None], 0, 1), 0.45
    return f


# --- rubble --------------------------------------------------------------------------------
PLATES = [rgb("#5c636b"), rgb("#4f565e"), rgb("#6b7076"), rgb("#535a52")]
LUMP = rgb("#4a4d52")
RUST = rgb("#6e4630")


def rubble_variant(v):
    def draw(cv, w, h):
        m = 0.08
        # The bed: crushed deck in a low heap, its outline ragged; grain repeats every cell.
        sd = ragged(cv, m, m, w - m, h - m, 0.2, 0.085, 31)
        cv.paint(sd, 0.18, gravel(rgb("#45484d"), 0.22, 7), bevel=0.16, dome=0.06)
        # Seam layer: lumps and scraps centred ON the cell edges, at the same spots in every
        # cell and every variant — the two halves of each always meet across a joint, so the
        # joints carry debris like the rest instead of a bare strip. Skipped on the outer edge.
        seam = np.random.default_rng(2024)
        seam_lumps = [(seam.uniform(0.1, 0.9), seam.uniform(0.07, 0.11), seam.uniform(0.85, 1.15)) for _ in range(4)]
        for i, j in cells(w, h):
            for (u, r, tone) in seam_lumps:
                for (x, y) in ((i, j + u), (i + u, j)):
                    if m + r < x < w - m - r and m + r < y < h - m - r:
                        cv.circle(x, y, r, 0.26, concrete(LUMP * tone, contrast=0.2, pores=0.12), bevel=r * 0.8, dome=0.03)
        for i, j in cells(w, h):
            rng = np.random.default_rng(1000 + v * 97 + (i * 7 + j * 13) % 5)
            # Lumps of broken deck and slag — inside the cell, never across its edge.
            for k in range(rng.integers(7, 11)):
                r = rng.uniform(0.05, 0.11)
                x, y = i + rng.uniform(0.1 + r, 0.9 - r), j + rng.uniform(0.1 + r, 0.9 - r)
                cv.circle(x, y, r, 0.24 + rng.uniform(0, 0.08), concrete(LUMP * rng.uniform(0.85, 1.2), contrast=0.2, pores=0.12),
                          bevel=r * 0.8, dome=0.03)
            # Torn floor-plate scraps.
            for k in range(rng.integers(2, 4)):
                L, W = rng.uniform(0.14, 0.26), rng.uniform(0.07, 0.12)
                a = rng.uniform(0, math.pi)
                dx, dy = math.cos(a) * L / 2, math.sin(a) * L / 2
                x = i + rng.uniform(0.2 + L / 2, 0.8 - L / 2)
                y = j + rng.uniform(0.2 + L / 2, 0.8 - L / 2)
                cv.line(x - dx, y - dy, x + dx, y + dy, W, 0.32 + 0.03 * k, tread(PLATES[rng.integers(len(PLATES))]), bevel=0.014)
            # A bent bar now and then, a few bolts.
            if rng.uniform() < 0.6:
                a = rng.uniform(0, math.pi)
                x, y = i + rng.uniform(0.35, 0.65), j + rng.uniform(0.35, 0.65)
                dx, dy = math.cos(a) * 0.13, math.sin(a) * 0.13
                col = RUST if rng.uniform() < 0.5 else rgb("#3a3e44")
                cv.line(x - dx, y - dy, x + dy * 0.3, y - dx * 0.3, 0.022, 0.42, metal(col, gloss=0.3), bevel=0.008)
                cv.line(x + dy * 0.3, y - dx * 0.3, x + dx, y + dy, 0.022, 0.43, metal(col, gloss=0.3), bevel=0.008)
            for k in range(rng.integers(1, 4)):
                cv.circle(i + rng.uniform(0.25, 0.75), j + rng.uniform(0.25, 0.75), 0.018, 0.4,
                          metal(rgb("#9aa0a6"), gloss=0.8), bevel=0.008)
    return draw


# --- trench --------------------------------------------------------------------------------
LIP = rgb("#3a3f46")        # the deck plating, a touch lighter than the floor tile
SUBFLOOR = rgb("#22272d")   # the structure under it, in the station's blue-grey


def trench_variant(v):
    def draw(cv, w, h):
        m = 0.09
        # The plating's cut lip (ragged), then the cut itself: its edge bevels down into the
        # sub-floor, so the light from the top-left shades the far wall of the cut.
        lip = ragged(cv, m - 0.05, m - 0.05, w - m + 0.05, h - m + 0.05, 0.03, 0.025, 11)
        cv.paint(lip, 0.14, tread(LIP), bevel=0.025)
        hole = ragged(cv, m, m, w - m, h - m, 0.03, 0.03, 17)
        cv.paint(hole, 0.0, gravel(SUBFLOOR, 0.14, 5, grains=10, gloss=0.25), bevel=0.07)
        # A few bits of cut plate fallen into the cut — differ per variant, inside the cell.
        for i, j in cells(w, h):
            rng = np.random.default_rng(500 + v * 41 + (i * 5 + j * 11) % 4)
            for k in range(rng.integers(0, 3)):
                L = rng.uniform(0.08, 0.15)
                a = rng.uniform(0, math.pi)
                dx, dy = math.cos(a) * L / 2, math.sin(a) * L / 2
                x = i + rng.uniform(0.3, 0.7)
                y = j + rng.uniform(0.3, 0.7)
                if m + 0.1 < x < w - m - 0.1 and m + 0.1 < y < h - m - 0.1:
                    cv.line(x - dx, y - dy, x + dx, y + dy, 0.05, 0.04, tread(LIP * 0.95), bevel=0.01)
    return draw


def stacked(draws, **kw):
    sheets = [sheet_from(d, **kw) for d in draws]
    out = Image.new("RGBA", (T * 4, T * 4 * len(sheets)), (0, 0, 0, 0))
    for k, sh in enumerate(sheets):
        out.paste(sh, (0, k * T * 4))
    return out, sheets[0]


def save(strip, first, folder, name):
    os.makedirs(folder, exist_ok=True)
    strip.save(os.path.join(folder, name + "_autotile.png"))
    slice_cell(first, 0, 0).save(os.path.join(folder, name + ".png"))
    sample_of(first, True).save(os.path.join(folder, "sample.png"))
    print(name)


def main():
    strip, first = stacked([rubble_variant(v) for v in range(VARIANTS)], seed=4)
    save(strip, first, "textures/walls/rubble", "rubble")
    strip, first = stacked([trench_variant(v) for v in range(3)], seed=6, shadow=False)
    save(strip, first, "textures/features/trench_station", "trench_station")
    save(strip, first, "textures/features/trench_asteroid", "trench_asteroid")


if __name__ == "__main__":
    main()
