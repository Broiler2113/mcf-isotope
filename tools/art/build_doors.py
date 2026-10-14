"""Station airlock doors in the furniture renderer's style (0.12.1 resprite).

    /root/.venvs/mcf-rl/bin/python tools/art/build_doors.py   # from the project root
    godot --headless --import

Writes door_station / door_open_station (and the plain door / door_open, which are the
station hatch) into textures/doors: a strip of three 32 px variants each, drawn from the
front like every door (TerrainTiles lays it over the wall tile). The contract with the game
stays as it was in tools/gen_textures.gd: a 2 px frame at the very edge of the tile (the
service accent tints it), the leaf fills the rest, and an open doorway is transparent.
Other environments' doors still come from gen_textures.gd.
"""
import os, sys
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(__file__))
from core import *

OUT = "textures/doors"
F = 2 / 32                     # frame width in cells
FRAME = rgb("#969aa0")
LEAF = [rgb("#646a72"), rgb("#5c6470"), rgb("#4a5668")]
CHROME = rgb("#c4c9ce")
YELLOW, BLACK = rgb("#c6a628"), rgb("#1e1c18")


def hazard(freq=9.0):
    def f(x, y, seed):
        on = ((x + y) * freq) % 1.0 < 0.5
        col = np.where(on[..., None], YELLOW[None, None, :], BLACK[None, None, :])
        return col.astype(np.float32), 0.2
    return f


def frame(cv):
    for r in ((0, 0, 1, F), (0, 1 - F, 1, 1), (0, 0, F, 1), (1 - F, 0, 1, 1)):
        cv.rect(*r, 1.0, metal(FRAME, gloss=0.5), r=0.0, bevel=0.012)


def lamp(cv, on):
    col = rgb("#5ad26e") if on else rgb("#dc4632")
    cv.rect(1 - F + 0.008, 0.09, 1 - 0.008, 0.17, 1.02, solid(col, var=0.0), r=0.0, bevel=0.0, emit=0.95)


def closed(v):
    cv = Canvas(1, 1, opaque=True, seed=11 + v)
    frame(cv)
    a, b = F, 1 - F
    leaf = painted(LEAF[v], gloss=0.35)
    if v == 0:
        # Two leaves sliding apart, a narrow window in each, hazard rail along the top.
        for x0, x1 in ((a, 0.497), (0.503, b)):
            cv.rect(x0, a, x1, b, 0.9, leaf, r=0.0, bevel=0.02)
            cv.rect(x0 + 0.06, a + 0.2, x1 - 0.06, b - 0.08, 0.93, leaf, r=0.01, bevel=0.015)
        cv.rect(a, a, b, a + 0.07, 0.94, hazard(), r=0.0, bevel=0.01)
        for x in (0.35, 0.58):
            cv.rect(x, 0.22, x + 0.07, 0.4, 0.95, glass(rgb("#7fa8c2")), r=0.01, bevel=0.01, emit=0.25)
    elif v == 1:
        # One heavy hatch: porthole, two ribs, a lock bar.
        cv.rect(a, a, b, b, 0.9, leaf, r=0.0, bevel=0.025)
        for y in (0.56, 0.73):
            cv.rect(a + 0.05, y, b - 0.05, y + 0.06, 0.96, metal(rgb("#7a828c"), gloss=0.5), r=0.01, bevel=0.015)
        cv.circle(0.5, 0.3, 0.14, 0.97, metal(CHROME, gloss=0.8), bevel=0.03)
        cv.circle(0.5, 0.3, 0.095, 0.95, glass(rgb("#7fa8c2")), bevel=0.03, dome=0.02, emit=0.25)
        cv.rect(0.78, 0.38, 0.85, 0.52, 0.98, metal(CHROME, gloss=0.8), r=0.01, bevel=0.01)
    else:
        # Blast door split on the diagonal, hazard band across the middle, corner bolts.
        cv.rect(a, a, b, b, 0.9, leaf, r=0.0, bevel=0.025)
        cv.rect(a, 0.44, b, 0.56, 0.93, hazard(), r=0.0, bevel=0.01)
        cv.line(a + 0.02, b - 0.02, b - 0.02, a + 0.02, 0.022, 0.84, solid(rgb("#2a2f36")), bevel=0.0)
        for x, y in ((0.14, 0.14), (0.86, 0.14), (0.14, 0.86), (0.86, 0.86)):
            cv.circle(x, y, 0.035, 0.96, metal(CHROME, gloss=0.7), bevel=0.02, dome=0.01)
    lamp(cv, False)
    return cv.image(shadow=False)


def opened(v):
    cv = Canvas(1, 1, opaque=False, seed=21 + v)
    frame(cv)
    edge = painted(LEAF[v] * 0.85, gloss=0.3)
    # The leaves slid into the wall: only their edges show at the jambs.
    if v == 0:
        cv.rect(F, F, F + 0.06, 1 - F, 0.9, edge, r=0.0, bevel=0.01)
    cv.rect(1 - F - 0.07, F, 1 - F, 1 - F, 0.9, edge, r=0.0, bevel=0.01)
    lamp(cv, True)
    return cv.image(shadow=False)


def strip(images):
    out = Image.new("RGBA", (T * 3, T), (0, 0, 0, 0))
    for k, im in enumerate(images):
        out.paste(im, (k * T, 0))
    return out


def save(img, name):
    folder = os.path.join(OUT, name)
    os.makedirs(folder, exist_ok=True)
    img.save(os.path.join(folder, name + ".png"))
    sample_of(img, False).save(os.path.join(folder, "sample.png"))
    print(name)


def main():
    shut = strip([closed(v) for v in range(3)])
    open_ = strip([opened(v) for v in range(3)])
    for name, img in (("door_station", shut), ("door", shut), ("door_open_station", open_), ("door_open", open_)):
        save(img, name)


if __name__ == "__main__":
    main()
