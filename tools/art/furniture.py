"""Furniture and lamps (0.11 art pass). Everything is drawn from above with the BACK of the
piece (headboard, backrest, the wall side) at the TOP; the game turns it to the wall.

Joined pieces are drawn at any size w x h (their middle cells repeat per cell) and cut into
the 16-tile sheet; fixed-size pieces also get one "<id>_piece.png" picture.
Lamp bulbs are near-white so the editor's colour menu can recolour them (tint_lamp).
"""
import math
import numpy as np
from core import *

M = 0.09   # margin on open sides (3 px of 32)

STEEL = rgb("#8c9196")
STEEL_D = rgb("#4a4f55")
CHROME = rgb("#c4c9ce")
BLACK = rgb("#202224")
WOOD = rgb("#7a4e2d")
WOOD_L = rgb("#a57a4f")
WOOD_D = rgb("#4f321d")
BULB = rgb("#fff3da")
WHITE = rgb("#e8e6df")


def body(cv, w, h, z, mat, r=0.04, bevel=0.04, m=M, **kw):
    return cv.rect(m, m, w - m, h - m, z, mat, r=r, bevel=bevel, **kw)


def cells(w, h):
    for i in range(w):
        for j in range(h):
            yield i, j


def knob(cv, x, y, z, col=CHROME, r=0.025):
    cv.circle(x, y, r, z, metal(col, gloss=0.8), bevel=r * 0.8, dome=0.01)


# --- residential --------------------------------------------------------------------------
def chair(cv, c):
    c = c if c is not None else WOOD
    for (x, y) in ((0.26, 0.36), (0.74, 0.36), (0.26, 0.82), (0.74, 0.82)):
        cv.circle(x, y, 0.035, 0.25, wood(c * 0.7), bevel=0.02)
    cv.rect(0.22, 0.34, 0.78, 0.84, 0.42, wood(c, freq=12), r=0.06, bevel=0.04)
    cv.rect(0.27, 0.39, 0.73, 0.79, 0.46, fabric(rgb("#8c3a30")), r=0.07, bevel=0.06, dome=0.03)
    for x in (0.26, 0.74):
        cv.rect(x - 0.035, 0.16, x + 0.035, 0.36, 0.7, wood(c * 0.85), r=0.02, bevel=0.02)
    cv.rect(0.2, 0.12, 0.8, 0.22, 0.8, wood(c * 0.9, freq=12), r=0.04, bevel=0.03)

def armchair(cv, c):
    c = c if c is not None else rgb("#8a6a4c")
    f = fabric(c)
    cv.rect(0.1, 0.12, 0.9, 0.9, 0.45, f, r=0.12, bevel=0.08)
    cv.rect(0.1, 0.1, 0.9, 0.32, 0.8, fabric(c * 0.92), r=0.1, bevel=0.1, dome=0.04)
    cv.rect(0.1, 0.2, 0.26, 0.9, 0.65, fabric(c * 0.95), r=0.08, bevel=0.07, dome=0.03)
    cv.rect(0.74, 0.2, 0.9, 0.9, 0.65, fabric(c * 0.95), r=0.08, bevel=0.07, dome=0.03)
    cv.rect(0.27, 0.33, 0.73, 0.86, 0.52, fabric(c * 1.06), r=0.08, bevel=0.08, dome=0.04)


def sofa(cv, w, h, c):
    c = c if c is not None else rgb("#5c6670")
    body(cv, w, h, 0.45, fabric(c), r=0.1, bevel=0.08)
    cv.rect(M, M, w - M, 0.34, 0.85, fabric(c * 0.9), r=0.1, bevel=0.1, dome=0.04)
    cv.rect(M, 0.2, M + 0.17, h - M, 0.68, fabric(c * 0.94), r=0.08, bevel=0.07, dome=0.03)
    cv.rect(w - M - 0.17, 0.2, w - M, h - M, 0.68, fabric(c * 0.94), r=0.08, bevel=0.07, dome=0.03)
    for i, j in cells(w, h):
        x0 = max(i + 0.02, M + 0.18)
        x1 = min(i + 0.98, w - M - 0.18)
        cv.rect(x0, max(j + 0.02, 0.36), x1, min(j + 0.98, h - M - 0.03), 0.55, fabric(c * 1.07), r=0.08, bevel=0.08, dome=0.04)
    for i in range(w):
        x0, x1 = max(i + 0.04, M + 0.2), min(i + 0.96, w - M - 0.2)
        cv.rect(x0, 0.13, x1, 0.32, 0.9, fabric(c * 0.98), r=0.08, bevel=0.08, dome=0.04)


def bed(cv, w, h, c):
    c = c if c is not None else rgb("#40618e")
    cv.rect(0.05, 0.03, w - 0.05, h - 0.05, 0.3, wood(WOOD_D, angle=math.pi / 2), r=0.04, bevel=0.03)
    cv.rect(0.05, 0.03, w - 0.05, 0.14, 0.6, wood(WOOD_D * 1.1), r=0.03, bevel=0.03)
    cv.rect(0.1, 0.14, w - 0.1, h - 0.1, 0.42, fabric(WHITE), r=0.06, bevel=0.06)
    for i in range(w):
        cv.rect(i + 0.17, 0.2, i + 0.83, 0.46, 0.55, fabric(rgb("#f4f1ea")), r=0.1, bevel=0.1, dome=0.05)
    cv.rect(0.1, 0.62, w - 0.1, h - 0.1, 0.5, fabric(c), r=0.06, bevel=0.07, dome=0.02)
    cv.rect(0.1, 0.56, w - 0.1, 0.7, 0.53, fabric(WHITE * 0.97), r=0.04, bevel=0.05, dome=0.02)
    for j in range(h):
        y = j + 0.5 if j else 0.95
        if y < h - 0.2:
            cv.groove(0.14, y - 0.006, w - 0.14, y + 0.006, depth=0.015, dark=0.88)


def bunk_bed(cv, w, h, c):
    c = c if c is not None else rgb("#5d6b54")
    m = metal(STEEL_D, gloss=0.5)
    cv.rect(0.08, 0.05, w - 0.08, h - 0.05, 0.9, m, r=0.03, bevel=0.03)
    cv.rect(0.13, 0.1, w - 0.13, h - 0.1, 0.92, fabric(c), r=0.04, bevel=0.05, dome=0.02)
    cv.rect(0.2, 0.15, w - 0.2, 0.42, 0.98, fabric(WHITE), r=0.08, bevel=0.08, dome=0.04)
    cv.rect(0.13, 0.6, w - 0.13, 0.72, 0.95, fabric(c * 0.85), r=0.03, bevel=0.03)
    for (x, y) in ((0.08, 0.05), (w - 0.08, 0.05), (0.08, h - 0.05), (w - 0.08, h - 0.05)):
        cv.rect(x - 0.05, y - 0.05, x + 0.05, y + 0.05, 1.0, metal(STEEL, gloss=0.6), r=0.01, bevel=0.02)
    for k in range(4):
        y = h - 0.75 + k * 0.14
        cv.rect(w - 0.16, y - 0.015, w - 0.04, y + 0.015, 1.0, metal(STEEL, gloss=0.6), r=0.01, bevel=0.01)


def nightstand(cv, c):
    cv.rect(0.16, 0.14, 0.84, 0.86, 0.5, wood(WOOD, freq=14), r=0.04, bevel=0.04)
    cv.groove(0.18, 0.5, 0.82, 0.512, depth=0.01, dark=0.7)
    knob(cv, 0.5, 0.7, 0.52)
    cv.circle(0.36, 0.33, 0.1, 0.58, ceramic(rgb("#d9cfb8")), bevel=0.04)
    cv.circle(0.36, 0.33, 0.05, 0.62, solid(BULB, var=0), bevel=0.02, emit=0.6)


def desk(cv, w, h, c):
    c = c if c is not None else WOOD
    cv.rect(0.05, 0.08, w - 0.05, h - 0.14, 0.75, wood(c, freq=8), r=0.03, bevel=0.03)
    cv.rect(w - 0.6, h - 0.3, w - 0.08, h - 0.1, 0.6, wood(c * 0.85), r=0.02, bevel=0.02)
    cv.rect(0.25, 0.2, 0.8, 0.55, 0.8, solid(rgb("#ece8dc"), var=0.02), r=0.005, bevel=0.005)
    cv.rect(0.3, 0.25, 0.85, 0.6, 0.79, solid(rgb("#f4f1e8"), var=0.02), r=0.005, bevel=0.005)
    cv.line(0.95, 0.3, 1.25, 0.45, 0.02, 0.8, solid(rgb("#20304a")), bevel=0.01)
    cv.circle(w - 0.35, 0.3, 0.07, 0.82, ceramic(rgb("#d8d4cc")), bevel=0.02)
    cv.circle(w - 0.35, 0.3, 0.045, 0.8, solid(rgb("#3a2414")), bevel=0.01)


def office_desk(cv, w, h, c):
    cv.rect(0.05, 0.08, w - 0.05, h - 0.14, 0.75, solid(rgb("#b8b2a6"), var=0.02, gloss=0.2), r=0.03, bevel=0.03)
    cv.rect(0.55, 0.12, 1.45, 0.26, 0.95, plastic(BLACK), r=0.02, bevel=0.02)
    cv.rect(0.6, 0.14, 1.4, 0.24, 0.97, screen(rgb("#3b6fb0")), r=0.01, bevel=0.005, emit=0.65)
    cv.rect(0.92, 0.26, 1.08, 0.36, 0.85, plastic(BLACK), r=0.02, bevel=0.02)
    cv.rect(0.62, 0.48, 1.3, 0.66, 0.8, plastic(rgb("#2b2d30")), r=0.02, bevel=0.01)
    for i in range(5):
        cv.groove(0.65, 0.51 + i * 0.03, 1.27, 0.513 + i * 0.03, depth=0.003, dark=0.7)
    cv.rect(1.4, 0.5, 1.48, 0.62, 0.8, plastic(rgb("#2b2d30")), r=0.03, bevel=0.02)
    cv.rect(0.12, 0.3, 0.42, 0.7, 0.77, solid(rgb("#f1eee6")), r=0.005, bevel=0.005)


def dining_table(cv, w, h, c):
    c = c if c is not None else WOOD_L
    body(cv, w, h, 0.75, wood(c, freq=6), r=0.06, bevel=0.03, m=0.06)
    for i, j in cells(w, h):
        cv.circle(i + 0.5, j + 0.5, 0.15, 0.78, ceramic(WHITE), bevel=0.05)
        cv.circle(i + 0.5, j + 0.5, 0.09, 0.765, ceramic(WHITE * 0.95), bevel=0.04)


def coffee_table(cv, c):
    cv.rect(0.12, 0.22, 0.88, 0.78, 0.4, wood(WOOD_D * 1.15, freq=8), r=0.05, bevel=0.03)
    cv.rect(0.18, 0.28, 0.82, 0.72, 0.42, glass(rgb("#95aeb8")), r=0.03, bevel=0.01)
    cv.rect(0.3, 0.38, 0.55, 0.58, 0.45, solid(rgb("#b4392e"), var=0.03), r=0.01, bevel=0.01)
    cv.circle(0.68, 0.48, 0.06, 0.47, ceramic(WHITE), bevel=0.02)


def wardrobe(cv, w, h, c):
    c = c if c is not None else rgb("#6b4428")
    cv.rect(0.04, 0.06, w - 0.04, h - 0.12, 1.0, wood(c, freq=10), r=0.03, bevel=0.03)
    cv.rect(0.04, 0.06, w - 0.04, 0.16, 1.05, wood(c * 0.85, freq=10), r=0.02, bevel=0.02)
    for i in range(1, w * 2):
        x = i * w / (w * 2)
        cv.groove(x - 0.006, 0.17, x + 0.006, h - 0.13, depth=0.02, dark=0.55)
    for i in range(w):
        for x in (i + 0.44, i + 0.56):
            cv.rect(x - 0.012, 0.42, x + 0.012, 0.6, 1.03, metal(rgb("#c8a85c"), gloss=0.8), r=0.01, bevel=0.005)


def dresser(cv, w, h, c):
    body(cv, w, h, 0.75, wood(WOOD, freq=10), r=0.03, bevel=0.03, m=0.06)
    for i in range(w):
        for k in range(3):
            y = 0.3 + k * 0.2
            cv.groove(i + 0.1, y, i + 0.9, y + 0.012, depth=0.01, dark=0.6)
            knob(cv, i + 0.5, y + 0.1, 0.77, rgb("#c8a85c"), 0.02)
    cv.rect(0.12, 0.1, 0.4, 0.22, 0.8, ceramic(rgb("#5f7f9a")), r=0.04, bevel=0.02)


def bookshelf(cv, w, h, c):
    cv.rect(0, M, w, h - M + 0.02, 1.0, wood(WOOD_D, freq=12), r=0.0, bevel=0.03)
    rng = np.random.default_rng(cv.seed + 2)
    spines = [rgb("#7a2c26"), rgb("#2c4a6e"), rgb("#2f5a3a"), rgb("#8c6a2c"), rgb("#4e3a5e"), rgb("#c2b28e"), rgb("#1f2a30")]
    for i, j in cells(w, h):
        x = i + 0.05
        while x < i + 0.93:
            bw = 0.05 + rng.random() * 0.05
            col = spines[rng.integers(len(spines))]
            d = 0.2 + rng.random() * 0.15
            cv.rect(x, j + M + 0.06, min(x + bw, i + 0.95), j + M + 0.06 + d * 2.1, 0.75 + rng.random() * 0.1,
                    solid(col, var=0.05, gloss=0.2), r=0.005, bevel=0.01)
            x += bw + 0.005
        cv.rect(i - 0.01, j + M, i + 0.03, j + 1 - M, 1.02, wood(WOOD_D * 1.1), r=0.0, bevel=0.01)


def cabinet(cv, c):
    cv.rect(0.1, 0.1, 0.9, 0.82, 0.75, wood(WOOD_L * 0.9, freq=12), r=0.03, bevel=0.03)
    cv.groove(0.494, 0.14, 0.506, 0.8, depth=0.02, dark=0.55)
    knob(cv, 0.44, 0.62, 0.77)
    knob(cv, 0.56, 0.62, 0.77)


def kitchen_counter(cv, w, h, c):
    cv.rect(0, M, w, h - M, 0.8, solid(rgb("#d9d4c8"), var=0.03, gloss=0.35), r=0.0, bevel=0.03)
    cv.rect(0, M, w, M + 0.08, 0.95, ceramic(rgb("#e6e1d4")), r=0.0, bevel=0.02)
    for i, j in cells(w, h):
        cv.groove(i - 0.004, j + M + 0.08, i + 0.004, j + 1 - M, depth=0.005, dark=0.85)
    # The sheet repeats ONE middle section for every inner cell: sink and board sit on the
    # end sections, the middle stays a plain worktop.
    i = 0
    cv.rect(i + 0.18, 0.28, i + 0.82, 0.78, 0.7, metal(CHROME, gloss=0.8), r=0.06, bevel=0.05, base=0.8)
    cv.circle(i + 0.5, 0.55, 0.03, 0.68, metal(STEEL_D), bevel=0.01)
    cv.rect(i + 0.47, 0.13, i + 0.53, 0.3, 0.95, metal(CHROME, gloss=0.9), r=0.03, bevel=0.02)
    if w > 1:
        i = w - 1
        cv.rect(i + 0.2, 0.3, i + 0.45, 0.48, 0.84, solid(rgb("#7a5634")), r=0.01, bevel=0.01)
        cv.circle(i + 0.65, 0.5, 0.08, 0.86, ceramic(rgb("#c33a2e")), bevel=0.03)


def refrigerator(cv, c):
    cv.rect(0.1, 0.06, 0.9, 0.88, 1.0, painted(rgb("#e4e5e2"), gloss=0.45), r=0.05, bevel=0.04)
    cv.groove(0.12, 0.38, 0.88, 0.392, depth=0.02, dark=0.6)
    cv.rect(0.7, 0.45, 0.76, 0.8, 1.04, metal(CHROME, gloss=0.9), r=0.02, bevel=0.01)
    cv.rect(0.7, 0.14, 0.76, 0.32, 1.04, metal(CHROME, gloss=0.9), r=0.02, bevel=0.01)
    cv.rect(0.22, 0.5, 0.36, 0.6, 1.01, solid(rgb("#d64a3a")), r=0.01, bevel=0.005)


def potted_plant(cv, c):
    cv.circle(0.5, 0.52, 0.24, 0.35, ceramic(rgb("#a8573a"), gloss=0.3), bevel=0.05)
    cv.circle(0.5, 0.52, 0.19, 0.3, solid(rgb("#3b2a1c")), bevel=0.03)
    rng = np.random.default_rng(6)
    greens = [rgb("#3e6e2e"), rgb("#4f8a36"), rgb("#2f5a24"), rgb("#5f9a40")]
    for k in range(14):
        a = k * 2.39996
        L = 0.18 + rng.random() * 0.2
        x1, y1 = 0.5 + L * math.cos(a), 0.52 + L * math.sin(a)
        cv.ellipse((0.5 + x1) / 2, (0.52 + y1) / 2, L / 2, 0.07, 0.5 + rng.random() * 0.2,
                   solid(greens[k % 4], var=0.08, gloss=0.25), bevel=0.04, dome=0.03,
                   ) if abs(math.cos(a)) > 0.7 else cv.ellipse((0.5 + x1) / 2, (0.52 + y1) / 2, 0.07, L / 2,
                   0.5 + rng.random() * 0.2, solid(greens[k % 4], var=0.08, gloss=0.25), bevel=0.04, dome=0.03)


def tv_stand(cv, c):
    cv.rect(0.08, 0.3, 0.92, 0.86, 0.5, wood(WOOD_D * 1.1, freq=8), r=0.03, bevel=0.03)
    cv.rect(0.1, 0.14, 0.9, 0.28, 0.95, plastic(BLACK), r=0.02, bevel=0.02)
    cv.rect(0.12, 0.155, 0.88, 0.265, 0.97, screen(rgb("#4a7ab8")), r=0.01, bevel=0.005, emit=0.7)
    cv.rect(0.42, 0.28, 0.58, 0.42, 0.6, plastic(BLACK), r=0.02, bevel=0.02)
    cv.rect(0.2, 0.6, 0.45, 0.75, 0.55, plastic(rgb("#2a2c2e")), r=0.02, bevel=0.01)
    cv.circle(0.24, 0.67, 0.012, 0.57, solid(rgb("#3ad46b")), bevel=0.0, emit=1.0)


def stove(cv, c):
    cv.rect(0.06, 0.06, 0.94, 0.94, 0.8, metal(rgb("#d9dadb"), contrast=0.03, gloss=0.6), r=0.05, bevel=0.04)
    cv.rect(0.1, 0.1, 0.9, 0.8, 0.82, metal(rgb("#1d1f22"), gloss=0.7), r=0.03, bevel=0.01)
    for (cx, cy) in ((0.3, 0.3), (0.7, 0.3), (0.3, 0.62), (0.7, 0.62)):
        cv.circle(cx, cy, 0.14, 0.84, metal(rgb("#2a2c2f"), gloss=0.4), bevel=0.02)
        cv.circle(cx, cy, 0.08, 0.855, metal(rgb("#101113"), gloss=0.3), bevel=0.02)
        for k in range(4):
            a = k * math.pi / 2 + 0.6
            cv.line(cx + 0.06 * math.cos(a), cy + 0.06 * math.sin(a), cx + 0.15 * math.cos(a), cy + 0.15 * math.sin(a),
                    0.03, 0.87, metal(rgb("#3a3c40"), gloss=0.5), bevel=0.01)
    for k in range(4):
        cv.circle(0.2 + k * 0.2, 0.87, 0.035, 0.85, metal(rgb("#2b2b2b"), gloss=0.4), bevel=0.02, dome=0.01)


def piano(cv, w, h, c):
    c = c if c is not None else rgb("#141414")
    cv.rect(0.04, 0.06, w - 0.04, 0.62, 1.0, solid(c, var=0.02, gloss=0.85), r=0.03, bevel=0.03)
    cv.rect(0.08, 0.62, w - 0.08, 0.86, 0.65, solid(c * 0.95, var=0.02, gloss=0.8), r=0.02, bevel=0.02)
    keys = 21
    x0, x1 = 0.12, w - 0.12
    kw = (x1 - x0) / keys
    for k in range(keys):
        cv.rect(x0 + k * kw + 0.003, 0.64, x0 + (k + 1) * kw - 0.003, 0.84, 0.7, ceramic(rgb("#f2efe6"), gloss=0.5), r=0.004, bevel=0.004)
    for k in range(keys - 1):
        if k % 7 in (2, 6):
            continue
        xk = x0 + (k + 1) * kw
        cv.rect(xk - kw * 0.3, 0.64, xk + kw * 0.3, 0.74, 0.74, solid(rgb("#151515"), gloss=0.6), r=0.003, bevel=0.004)
    cv.rect(w / 2 - 0.4, 0.88, w / 2 + 0.4, 0.98, 0.45, solid(c * 1.2 + 0.05, var=0.03, gloss=0.6), r=0.02, bevel=0.02)
    cv.rect(w / 2 - 0.25, 0.2, w / 2 + 0.25, 0.4, 1.03, solid(rgb("#efe9d9"), var=0.02), r=0.005, bevel=0.005)


def toilet(cv, c):
    cv.rect(0.26, 0.06, 0.74, 0.3, 0.75, ceramic(), r=0.05, bevel=0.04)
    cv.ellipse(0.5, 0.58, 0.22, 0.3, 0.45, ceramic(), bevel=0.06)
    cv.ellipse(0.5, 0.6, 0.14, 0.2, 0.3, ceramic(rgb("#b9c9d1")), bevel=0.06, base=0.45)
    cv.circle(0.5, 0.18, 0.03, 0.78, metal(CHROME), bevel=0.01, dome=0.01)


def sink(cv, c):
    cv.rect(0.1, 0.12, 0.9, 0.92, 0.8, ceramic(), r=0.12, bevel=0.06)
    cv.rect(0.2, 0.3, 0.8, 0.84, 0.6, ceramic((0.86, 0.88, 0.9)), r=0.1, bevel=0.08, base=0.8)
    cv.circle(0.5, 0.62, 0.035, 0.58, metal(rgb("#9aa0a6"), gloss=0.7), bevel=0.01)
    cv.rect(0.46, 0.04, 0.54, 0.34, 0.95, metal(rgb("#c9ced3"), gloss=0.85), r=0.04, bevel=0.03)
    cv.circle(0.5, 0.17, 0.06, 0.98, metal(rgb("#c9ced3"), gloss=0.85), bevel=0.02, dome=0.02)


# --- office ---------------------------------------------------------------------------------
def conference_table(cv, w, h, c):
    cv.rect(0.06, 0.1, w - 0.06, h - 0.1, 0.75, wood(WOOD_D * 1.2, freq=5), r=0.4, bevel=0.03)
    for i, j in cells(w, h):
        cv.rect(i + 0.3, j + 0.38, i + 0.62, j + 0.62, 0.77, solid(rgb("#f1eee6")), r=0.005, bevel=0.005)
    cv.circle(w / 2, h / 2, 0.12, 0.8, plastic(BLACK), bevel=0.04)


def filing_cabinet(cv, w, h, c):
    cv.rect(0, M, w, h - M, 0.75, painted(rgb("#8a9096")), r=0.0, bevel=0.03)
    for i, j in cells(w, h):
        cv.groove(i - 0.006, j + M, i + 0.006, j + 1 - M, depth=0.02, dark=0.55)
        cv.rect(i + 0.35, j + 0.66, i + 0.65, j + 0.74, 0.78, metal(CHROME, gloss=0.8), r=0.02, bevel=0.01)
        cv.rect(i + 0.38, j + 0.5, i + 0.62, j + 0.58, 0.76, solid(rgb("#ece6d2")), r=0.005, bevel=0.005)


def locker(cv, w, h, c):
    c = c if c is not None else rgb("#5f7a5a")
    cv.rect(0, M, w, h - M, 1.0, painted(c), r=0.0, bevel=0.03)
    for i, j in cells(w, h):
        cv.groove(i - 0.008, j + M, i + 0.008, j + 1 - M, depth=0.03, dark=0.5)
        for k in range(3):
            cv.groove(i + 0.25, j + 0.22 + k * 0.05, i + 0.75, j + 0.235 + k * 0.05, depth=0.01, dark=0.6)
        cv.rect(i + 0.7, j + 0.55, i + 0.78, j + 0.75, 1.03, metal(CHROME, gloss=0.8), r=0.02, bevel=0.01)


def reception_desk(cv, w, h, c):
    cv.rect(0, M, w, h - M, 0.8, wood(WOOD_L, freq=6), r=0.0, bevel=0.03)
    cv.rect(0, h - M - 0.2, w, h - M, 0.95, wood(WOOD_L * 0.82, freq=6), r=0.0, bevel=0.03)
    for i in range(w):
        if i % 2 == 0:
            cv.rect(i + 0.25, 0.2, i + 0.75, 0.32, 0.95, plastic(BLACK), r=0.02, bevel=0.02)
            cv.rect(i + 0.28, 0.215, i + 0.72, 0.305, 0.97, screen(rgb("#3b6fb0")), r=0.01, bevel=0.005, emit=0.65)
            cv.rect(i + 0.3, 0.45, i + 0.7, 0.58, 0.82, plastic(rgb("#2b2d30")), r=0.02, bevel=0.01)
        else:
            cv.rect(i + 0.2, 0.3, i + 0.55, 0.6, 0.82, solid(rgb("#f1eee6")), r=0.005, bevel=0.005)


def display_shelf(cv, w, h, c):
    cv.rect(0, M, w, h - M, 0.9, metal(rgb("#b9bec4"), gloss=0.5), r=0.0, bevel=0.03)
    rng = np.random.default_rng(cv.seed + 9)
    goods = [rgb("#d8452e"), rgb("#e3b62a"), rgb("#2f78c4"), rgb("#3c9a52"), rgb("#ece9df"), rgb("#8a4ab0")]
    for i, j in cells(w, h):
        for r in range(2):
            for k in range(4):
                col = goods[rng.integers(len(goods))]
                x = i + 0.08 + k * 0.22
                y = j + M + 0.08 + r * 0.38
                cv.rect(x, y, x + 0.18, y + 0.3, 0.95 + rng.random() * 0.05, plastic(col, gloss=0.4), r=0.02, bevel=0.02)
        cv.groove(i - 0.006, j + M, i + 0.006, j + 1 - M, depth=0.02, dark=0.6)


def checkout_counter(cv, w, h, c):
    cv.rect(0, M, w, h - M, 0.8, painted(rgb("#c9c4b6")), r=0.0, bevel=0.03)
    cv.rect(0, 0.36, w, 0.62, 0.81, plastic(rgb("#232527"), gloss=0.2), r=0.0, bevel=0.01)
    for i in range(w):
        cv.groove(i + 0.1, 0.48, i + 0.9, 0.5, depth=0.005, dark=0.6)
        if i % 2 == 0:
            cv.rect(i + 0.55, 0.66, i + 0.88, 0.86, 0.9, plastic(rgb("#3a3c40")), r=0.02, bevel=0.02)
            cv.rect(i + 0.58, 0.68, i + 0.85, 0.75, 0.92, screen(rgb("#46b86b")), r=0.01, bevel=0.005, emit=0.7)


def vending_machine(cv, c):
    c = c if c is not None else rgb("#b0302a")
    cv.rect(0.08, 0.06, 0.92, 0.9, 1.0, painted(c, gloss=0.45), r=0.03, bevel=0.03)
    cv.rect(0.14, 0.5, 0.64, 0.84, 1.01, glass(rgb("#9ab8c6")), r=0.01, bevel=0.01, emit=0.35)
    goods = [rgb("#e3b62a"), rgb("#2f78c4"), rgb("#e8e4da"), rgb("#3c9a52")]
    for r in range(2):
        for k in range(4):
            cv.rect(0.17 + k * 0.115, 0.54 + r * 0.15, 0.25 + k * 0.115, 0.64 + r * 0.15, 1.02, plastic(goods[(k + r) % 4]), r=0.01, bevel=0.01)
    cv.rect(0.7, 0.52, 0.86, 0.66, 1.02, plastic(BLACK), r=0.01, bevel=0.01)
    cv.rect(0.72, 0.54, 0.84, 0.58, 1.03, screen(rgb("#4ad46b")), r=0.005, bevel=0.0, emit=0.9)
    cv.rect(0.16, 0.12, 0.84, 0.36, 1.02, solid(BULB, var=0.02), r=0.02, bevel=0.01, emit=0.75)


def water_cooler(cv, c):
    cv.rect(0.22, 0.2, 0.78, 0.84, 0.8, plastic(rgb("#dedcd6")), r=0.06, bevel=0.04)
    cv.circle(0.5, 0.48, 0.24, 1.0, glass(rgb("#5ea6d8")), bevel=0.08, dome=0.06)
    cv.circle(0.5, 0.48, 0.07, 1.05, plastic(rgb("#2d6fb0")), bevel=0.02)
    cv.rect(0.3, 0.76, 0.42, 0.82, 0.82, plastic(rgb("#2d6fb0")), r=0.01, bevel=0.01)
    cv.rect(0.58, 0.76, 0.7, 0.82, 0.82, plastic(rgb("#c43a2e")), r=0.01, bevel=0.01)


def console(cv, c):
    cv.rect(0.06, 0.1, 0.94, 0.9, 0.75, metal(rgb("#3b4148"), gloss=0.5), r=0.04, bevel=0.03)
    cv.rect(0.12, 0.14, 0.88, 0.48, 0.85, plastic(BLACK), r=0.02, bevel=0.02)
    cv.rect(0.15, 0.17, 0.85, 0.45, 0.87, screen(rgb("#36c0a8")), r=0.01, bevel=0.005, emit=0.8)
    cols = [rgb("#d64a3a"), rgb("#e3b62a"), rgb("#4ad46b"), rgb("#3a8ad6")]
    for k in range(8):
        cv.rect(0.16 + (k % 4) * 0.18, 0.56 + (k // 4) * 0.14, 0.28 + (k % 4) * 0.18, 0.64 + (k // 4) * 0.14, 0.79,
                plastic(cols[(k * 3) % 4]), r=0.015, bevel=0.01, emit=0.4)


# --- industrial ---------------------------------------------------------------------------------
def workbench(cv, w, h, c):
    cv.rect(0, M, w, h - M, 0.75, wood(WOOD_L * 0.95, freq=4), r=0.0, bevel=0.03)
    cv.rect(0, M, w, M + 0.12, 0.95, metal(rgb("#5b6066")), r=0.0, bevel=0.02)
    for i in range(w):
        for k in range(5):
            cv.circle(i + 0.12 + k * 0.19, M + 0.06, 0.012, 0.93, solid(BLACK), bevel=0.0)
        if i % 2 == 0:
            cv.rect(i + 0.15, 0.4, i + 0.4, 0.5, 0.8, metal(rgb("#c43a2e"), gloss=0.5), r=0.02, bevel=0.01)
            cv.line(i + 0.5, 0.6, i + 0.85, 0.45, 0.04, 0.78, metal(STEEL, gloss=0.7), bevel=0.01)
        else:
            cv.rect(i + 0.2, 0.35, i + 0.5, 0.75, 0.85, metal(rgb("#4a4f55"), gloss=0.5), r=0.02, bevel=0.02)
            cv.circle(i + 0.72, 0.6, 0.08, 0.8, metal(CHROME, gloss=0.8), bevel=0.03)


def tool_cabinet(cv, c):
    c = c if c is not None else rgb("#b0302a")
    cv.rect(0.1, 0.1, 0.9, 0.86, 0.8, painted(c, gloss=0.5), r=0.03, bevel=0.03)
    for k in range(5):
        y = 0.25 + k * 0.12
        cv.groove(0.12, y, 0.88, y + 0.012, depth=0.01, dark=0.55)
        cv.rect(0.38, y + 0.03, 0.62, y + 0.06, 0.82, metal(CHROME, gloss=0.8), r=0.01, bevel=0.005)
    cv.circle(0.8, 0.17, 0.03, 0.82, metal(CHROME), bevel=0.01)


def storage_shelf(cv, w, h, c):
    cv.rect(0, M, w, h - M, 0.4, metal(rgb("#6b7178"), gloss=0.4), r=0.0, bevel=0.02)
    rng = np.random.default_rng(cv.seed + 5)
    for i, j in cells(w, h):
        for (x, y) in ((i + 0.0, j + M), (i + 0.0, j + 1 - M)):
            cv.rect(x - 0.03, y - 0.03, x + 0.03, y + 0.03, 1.05, metal(rgb("#d4a62a"), gloss=0.4), r=0.005, bevel=0.01)
        k = rng.integers(3)
        if k == 0:
            cv.rect(i + 0.1, j + 0.18, i + 0.9, j + 0.82, 0.9, wood(rgb("#b88a55"), freq=7), r=0.02, bevel=0.03)
            cv.rect(i + 0.1, j + 0.47, i + 0.9, j + 0.53, 0.92, solid(rgb("#c9b48a")), r=0.0, bevel=0.0)
        elif k == 1:
            for (x, y) in ((0.3, 0.32), (0.7, 0.32), (0.3, 0.68), (0.7, 0.68)):
                cv.rect(i + x - 0.17, j + y - 0.15, i + x + 0.17, j + y + 0.15, 0.85, solid(rgb("#b9946a"), var=0.05), r=0.01, bevel=0.02)
                cv.groove(i + x - 0.17, j + y - 0.01, i + x + 0.17, j + y + 0.01, depth=0.005, dark=0.75)
        else:
            cv.circle(i + 0.32, j + 0.5, 0.2, 0.95, metal(rgb("#3d6e9a"), gloss=0.5), bevel=0.04)
            cv.rect(i + 0.58, j + 0.25, i + 0.88, j + 0.75, 0.8, plastic(rgb("#2f3a44")), r=0.02, bevel=0.02)


def server_rack(cv, w, h, c):
    cv.rect(0, M, w, h - M, 1.0, metal(rgb("#1f2226"), gloss=0.5), r=0.0, bevel=0.03)
    rng = np.random.default_rng(cv.seed + 3)
    for i, j in cells(w, h):
        cv.groove(i - 0.008, j + M, i + 0.008, j + 1 - M, depth=0.03, dark=0.5)
        for k in range(6):
            y = j + 0.17 + k * 0.115
            cv.rect(i + 0.1, y, i + 0.9, y + 0.09, 1.01, metal(rgb("#33373c"), gloss=0.5), r=0.005, bevel=0.01)
            for l in range(3):
                col = [rgb("#4ad46b"), rgb("#3a8ad6"), rgb("#e3b62a")][rng.integers(3)]
                cv.circle(i + 0.16 + l * 0.06, y + 0.045, 0.012, 1.02, solid(col, var=0), bevel=0.0, emit=1.0)


def industrial_cabinet(cv, w, h, c):
    cv.rect(0, M, w, h - M, 1.0, painted(rgb("#56606a"), gloss=0.35), r=0.0, bevel=0.03)
    for i, j in cells(w, h):
        cv.groove(i - 0.008, j + M, i + 0.008, j + 1 - M, depth=0.03, dark=0.5)
        cv.groove(i + 0.494, j + M + 0.05, i + 0.506, j + 1 - M - 0.05, depth=0.02, dark=0.6)
        cv.rect(i + 0.42, j + 0.4, i + 0.46, j + 0.62, 1.03, metal(CHROME, gloss=0.8), r=0.01, bevel=0.005)
        cv.rect(i + 0.54, j + 0.4, i + 0.58, j + 0.62, 1.03, metal(CHROME, gloss=0.8), r=0.01, bevel=0.005)
        cv.rect(i + 0.1, j + 0.2, i + 0.35, j + 0.3, 1.01, solid(rgb("#d4a62a")), r=0.005, bevel=0.0)


def pallet(cv, c):
    for k in range(5):
        x = 0.1 + k * 0.18
        cv.rect(x, 0.1, x + 0.14, 0.9, 0.3, wood(rgb("#b48a5a"), angle=math.pi / 2, freq=8), r=0.01, bevel=0.02)
        for y in (0.15, 0.5, 0.85):
            cv.circle(x + 0.07, y, 0.01, 0.31, metal(STEEL_D), bevel=0.0)


def crate(cv, c):
    cv.rect(0.1, 0.1, 0.9, 0.9, 0.6, wood(rgb("#a27a48"), freq=7), r=0.02, bevel=0.03)
    for k in range(4):
        cv.groove(0.12, 0.1 + k * 0.2 + 0.2, 0.88, 0.1 + k * 0.2 + 0.207, depth=0.01, dark=0.6)
    cv.rect(0.1, 0.1, 0.9, 0.18, 0.64, wood(rgb("#8c6638")), r=0.01, bevel=0.01)
    cv.rect(0.1, 0.82, 0.9, 0.9, 0.64, wood(rgb("#8c6638")), r=0.01, bevel=0.01)
    cv.line(0.16, 0.2, 0.84, 0.8, 0.07, 0.65, wood(rgb("#8c6638")), bevel=0.01)


def barrel(cv, c):
    c = c if c is not None else rgb("#3f6aa0")
    cv.circle(0.5, 0.5, 0.38, 0.85, painted(c, gloss=0.4), bevel=0.05)
    cv.circle(0.5, 0.5, 0.3, 0.83, painted(c * 0.95, gloss=0.4), bevel=0.02)
    cv.circle(0.36, 0.38, 0.05, 0.87, metal(STEEL), bevel=0.02)
    cv.circle(0.64, 0.62, 0.035, 0.87, metal(STEEL), bevel=0.02)


def equipment_cart(cv, c):
    cv.rect(0.16, 0.14, 0.84, 0.86, 0.6, metal(rgb("#6c7278"), gloss=0.5), r=0.03, bevel=0.03)
    cv.rect(0.2, 0.18, 0.8, 0.82, 0.55, metal(rgb("#585e64"), gloss=0.4), r=0.02, bevel=0.03, base=0.6)
    cv.rect(0.24, 0.24, 0.55, 0.5, 0.7, plastic(rgb("#c43a2e")), r=0.02, bevel=0.02)
    cv.rect(0.4, 0.55, 0.74, 0.76, 0.66, plastic(rgb("#2f3a44")), r=0.02, bevel=0.02)
    cv.rect(0.12, 0.08, 0.88, 0.12, 0.8, metal(CHROME, gloss=0.8), r=0.02, bevel=0.01)


def generator(cv, w, h, c):
    c = c if c is not None else rgb("#c9a02a")
    cv.rect(0.06, 0.1, w - 0.06, h - 0.1, 0.9, painted(c, gloss=0.4), r=0.05, bevel=0.04)
    cv.rect(0.12, 0.18, 0.95, h - 0.18, 0.95, painted(c * 0.92, gloss=0.4), r=0.04, bevel=0.03)
    for k in range(7):
        cv.groove(0.2, 0.26 + k * 0.07, 0.86, 0.275 + k * 0.07, depth=0.015, dark=0.55)
    cv.circle(1.4, 0.5, 0.22, 0.95, metal(STEEL_D, gloss=0.4), bevel=0.03)
    cv.circle(1.4, 0.5, 0.17, 0.9, metal(BLACK), bevel=0.02)
    for k in range(6):
        a = k * math.pi / 3
        cv.line(1.4, 0.5, 1.4 + 0.15 * math.cos(a), 0.5 + 0.15 * math.sin(a), 0.03, 0.93, metal(STEEL), bevel=0.01)
    cv.rect(1.7, 0.22, 1.84, 0.4, 1.0, metal(STEEL_D, gloss=0.5), r=0.03, bevel=0.02)
    cv.rect(1.0, 0.75, 1.15, 0.85, 0.97, solid(rgb("#d64a3a")), r=0.01, bevel=0.01, emit=0.5)


def toolbox(cv, c):
    cv.rect(0.16, 0.3, 0.84, 0.72, 0.4, painted(rgb("#c43a2e"), gloss=0.45), r=0.03, bevel=0.03)
    cv.groove(0.18, 0.5, 0.82, 0.512, depth=0.01, dark=0.6)
    cv.rect(0.34, 0.26, 0.66, 0.34, 0.5, metal(BLACK, gloss=0.4), r=0.03, bevel=0.02)
    cv.rect(0.2, 0.46, 0.26, 0.54, 0.43, metal(CHROME), r=0.01, bevel=0.01)
    cv.rect(0.74, 0.46, 0.8, 0.54, 0.43, metal(CHROME), r=0.01, bevel=0.01)


def ammo_crate(cv, c):
    cv.rect(0.12, 0.16, 0.88, 0.84, 0.6, painted(rgb("#55603e"), gloss=0.25), r=0.03, bevel=0.03)
    cv.rect(0.14, 0.18, 0.86, 0.3, 0.63, painted(rgb("#4a5436")), r=0.02, bevel=0.02)
    cv.rect(0.3, 0.45, 0.7, 0.6, 0.61, solid(rgb("#d9c79a"), var=0.02), r=0.005, bevel=0.0)
    for x in (0.38, 0.5, 0.62):
        cv.rect(x - 0.02, 0.49, x + 0.02, 0.56, 0.615, solid(BLACK), r=0.0, bevel=0.0)
    cv.rect(0.12, 0.66, 0.2, 0.76, 0.64, metal(STEEL), r=0.01, bevel=0.01)
    cv.rect(0.8, 0.66, 0.88, 0.76, 0.64, metal(STEEL), r=0.01, bevel=0.01)


def machinery(cv, w, h, c):
    body(cv, w, h, 0.95, painted(rgb("#5e6f5a"), gloss=0.35), r=0.04, bevel=0.04, m=0.06)
    for i, j in cells(w, h):
        k = (i * 3 + j * 5) % 3
        if k == 0:
            cv.circle(i + 0.5, j + 0.5, 0.3, 1.0, metal(STEEL_D, gloss=0.5), bevel=0.04)
            cv.circle(i + 0.5, j + 0.5, 0.12, 1.05, metal(STEEL, gloss=0.7), bevel=0.03, dome=0.02)
        elif k == 1:
            for l in range(5):
                cv.groove(i + 0.15, j + 0.2 + l * 0.13, i + 0.85, j + 0.215 + l * 0.13, depth=0.015, dark=0.55)
        else:
            cv.rect(i + 0.2, j + 0.25, i + 0.8, j + 0.6, 1.0, plastic(BLACK), r=0.02, bevel=0.02)
            cv.rect(i + 0.24, j + 0.29, i + 0.76, j + 0.56, 1.01, screen(rgb("#e3a62a")), r=0.01, bevel=0.005, emit=0.7)
    cv.line(0.3, h - 0.2, w - 0.3, h - 0.2, 0.06, 1.02, metal(rgb("#d4a62a")), bevel=0.02)


def exam_table(cv, w, h, c):
    cv.rect(0.16, 0.05, w - 0.16, h - 0.05, 0.6, metal(CHROME, gloss=0.7), r=0.04, bevel=0.03)
    cv.rect(0.2, 0.08, w - 0.2, h - 0.08, 0.7, plastic(rgb("#4a8a9a"), gloss=0.3), r=0.05, bevel=0.05, dome=0.02)
    cv.rect(0.22, 0.12, w - 0.22, 0.5, 0.74, fabric(rgb("#e9eef0")), r=0.05, bevel=0.06, dome=0.03)
    cv.groove(0.2, 0.62, w - 0.2, 0.635, depth=0.01, dark=0.7)
    cv.rect(0.26, 0.7, w - 0.26, h - 0.12, 0.72, fabric(rgb("#f4f2ec")), r=0.02, bevel=0.03)


def washing_machine(cv, c):
    cv.rect(0.1, 0.08, 0.9, 0.9, 0.8, painted(rgb("#e7e7e3"), gloss=0.5), r=0.05, bevel=0.04)
    cv.rect(0.12, 0.1, 0.88, 0.24, 0.82, painted(rgb("#d9d9d4")), r=0.03, bevel=0.02)
    cv.circle(0.75, 0.17, 0.04, 0.84, plastic(rgb("#5a5c5e")), bevel=0.02)
    cv.circle(0.5, 0.58, 0.27, 0.84, metal(CHROME, gloss=0.8), bevel=0.04)
    cv.circle(0.5, 0.58, 0.21, 0.83, glass(rgb("#7f9ba8")), bevel=0.04, dome=0.02)


def fuel_tank(cv, w, h, c):
    c = c if c is not None else rgb("#d8d6cf")
    for (x, y) in ((0.3, 0.3), (w - 0.3, 0.3), (0.3, h - 0.3), (w - 0.3, h - 0.3)):
        cv.rect(x - 0.08, y - 0.08, x + 0.08, y + 0.08, 0.6, metal(STEEL_D), r=0.01, bevel=0.02)
    cv.circle(w / 2, h / 2, min(w, h) / 2 - 0.1, 1.0, painted(c, gloss=0.5), bevel=0.3, dome=0.2)
    cv.circle(w / 2, h / 2, 0.15, 1.25, metal(STEEL, gloss=0.6), bevel=0.04)
    cv.circle(w / 2, h / 2, 0.07, 1.3, metal(rgb("#c43a2e"), gloss=0.5), bevel=0.02)
    cv.line(w / 2 + 0.3, h / 2 - 0.55, w / 2 + 0.75, h / 2 - 0.1, 0.05, 1.15, metal(rgb("#d4a62a")), bevel=0.02)


def target(cv, c):
    for (xa, ya, xb, yb) in ((0.5, 0.5, 0.18, 0.88), (0.5, 0.5, 0.82, 0.88), (0.5, 0.5, 0.5, 0.1)):
        cv.line(xa, ya, xb, yb, 0.05, 0.4, wood(rgb("#8a6a44")), bevel=0.02)
    rings = (rgb("#ece6d2"), rgb("#1d1d1d"), rgb("#ece6d2"), rgb("#1d1d1d"), rgb("#c43a2e"))
    for k, col in enumerate(rings):
        cv.circle(0.5, 0.5, 0.36 - k * 0.07, 0.8 + k * 0.004, solid(col, var=0.03), bevel=0.01 if k else 0.03)

def vent_fan(cv, c):
    cv.rect(0.08, 0.08, 0.92, 0.92, 0.3, metal(rgb("#7a8086"), gloss=0.4), r=0.04, bevel=0.03)
    cv.circle(0.5, 0.5, 0.36, 0.15, metal(rgb("#1a1c1e")), bevel=0.04, base=0.3)
    for k in range(5):
        a = k * 2 * math.pi / 5
        cv.ellipse(0.5 + 0.17 * math.cos(a), 0.5 + 0.17 * math.sin(a), 0.14, 0.14, 0.2, metal(rgb("#9aa0a6"), gloss=0.5), bevel=0.03)
    cv.circle(0.5, 0.5, 0.08, 0.25, metal(STEEL_D), bevel=0.03)
    for k in range(-3, 4):
        cv.rect(0.12, 0.5 + k * 0.1 - 0.01, 0.88, 0.5 + k * 0.1 + 0.01, 0.32, metal(rgb("#6a7076")), r=0.0, bevel=0.005,
                shape_mask=(np.hypot(cv.x - 0.5, cv.y - 0.5) < 0.37).astype(np.float32))


def steel_table(cv, w, h, c):
    body(cv, w, h, 0.75, metal(rgb("#b4b9be"), brushed=1, gloss=0.6), r=0.02, bevel=0.03, m=0.06)
    for i, j in cells(w, h):
        if (i + j) % 2 == 0:
            cv.rect(i + 0.2, j + 0.3, i + 0.6, j + 0.55, 0.78, metal(rgb("#8a9096"), gloss=0.7), r=0.02, bevel=0.02)
        else:
            cv.circle(i + 0.6, j + 0.5, 0.08, 0.8, glass(rgb("#a8c6d0")), bevel=0.03)


def lab_bench(cv, w, h, c):
    cv.rect(0, M, w, h - M, 0.8, solid(rgb("#2d3133"), var=0.03, gloss=0.35), r=0.0, bevel=0.03)
    cv.rect(0, M, w, M + 0.1, 0.95, metal(rgb("#c9ced3"), gloss=0.6), r=0.0, bevel=0.02)
    for i in range(w):
        for k, col in enumerate((rgb("#7fc4a8"), rgb("#d4a62a"), rgb("#9ab8e6"))):
            cv.circle(i + 0.25 + k * 0.2, 0.45, 0.06, 0.9, glass(col), bevel=0.03)
        cv.rect(i + 0.2, 0.62, i + 0.7, 0.78, 0.84, metal(CHROME, gloss=0.7), r=0.02, bevel=0.02)
        cv.circle(i + 0.82, 0.7, 0.05, 0.88, metal(STEEL_D), bevel=0.02)


def morgue_drawers(cv, w, h, c):
    cv.rect(0, M, w, h - M, 1.0, metal(rgb("#b9bec2"), brushed=1, gloss=0.6), r=0.0, bevel=0.03)
    for i, j in cells(w, h):
        cv.groove(i - 0.008, j + M, i + 0.008, j + 1 - M, depth=0.03, dark=0.5)
        cv.rect(i + 0.12, j + 0.18, i + 0.88, j + 0.82, 0.98, metal(rgb("#a9aeb3"), brushed=1, gloss=0.6), r=0.02, bevel=0.02)
        cv.rect(i + 0.35, j + 0.66, i + 0.65, j + 0.72, 1.02, metal(CHROME, gloss=0.9), r=0.02, bevel=0.01)
        cv.rect(i + 0.4, j + 0.3, i + 0.6, j + 0.4, 1.0, solid(rgb("#ece6d2")), r=0.005, bevel=0.0)


def biohazard_cabinet(cv, w, h, c):
    cv.rect(0, M, w, h - M, 1.0, painted(rgb("#d9d4c2"), gloss=0.4), r=0.0, bevel=0.03)
    for i, j in cells(w, h):
        cv.groove(i - 0.008, j + M, i + 0.008, j + 1 - M, depth=0.03, dark=0.5)
        cv.circle(i + 0.5, j + 0.48, 0.17, 1.01, solid(rgb("#e3b62a"), var=0.02), bevel=0.0)
        for k in range(3):
            a = k * 2 * math.pi / 3 - math.pi / 2
            cv.circle(i + 0.5 + 0.07 * math.cos(a), j + 0.48 + 0.07 * math.sin(a), 0.055, 1.02, solid(BLACK), bevel=0.0)
        cv.circle(i + 0.5, j + 0.48, 0.03, 1.03, solid(rgb("#e3b62a")), bevel=0.0)
        cv.rect(i + 0.8, j + 0.6, i + 0.85, j + 0.78, 1.03, metal(CHROME), r=0.01, bevel=0.005)


def specimen_fridge(cv, c):
    cv.rect(0.08, 0.06, 0.92, 0.9, 1.0, painted(rgb("#e4e8ea"), gloss=0.45), r=0.04, bevel=0.03)
    cv.rect(0.14, 0.16, 0.86, 0.82, 1.01, glass(rgb("#a8d6e6")), r=0.02, bevel=0.02, emit=0.4)
    for k in range(3):
        y = 0.3 + k * 0.18
        for l in range(5):
            cv.circle(0.24 + l * 0.13, y, 0.04, 1.03, glass([rgb("#c43a2e"), rgb("#7fc4a8"), rgb("#e3b62a")][(k + l) % 3]), bevel=0.02)
    cv.rect(0.74, 0.1, 0.84, 0.14, 1.02, solid(rgb("#46d0e8")), r=0.005, bevel=0.0, emit=1.0)


def gas_canister(cv, c):
    c = c if c is not None else rgb("#4a6e9a")
    cv.circle(0.5, 0.52, 0.28, 0.9, painted(c, gloss=0.5), bevel=0.1, dome=0.06)
    cv.circle(0.5, 0.52, 0.12, 1.0, metal(CHROME, gloss=0.8), bevel=0.04)
    cv.circle(0.5, 0.52, 0.05, 1.05, metal(STEEL_D), bevel=0.02)
    cv.line(0.5, 0.52, 0.7, 0.36, 0.04, 1.02, metal(rgb("#d4a62a"), gloss=0.7), bevel=0.01)


def water_bucket(cv, c):
    c = c if c is not None else rgb("#8a9096")
    cv.circle(0.5, 0.54, 0.3, 0.45, metal(c, gloss=0.6), bevel=0.04)
    cv.circle(0.5, 0.54, 0.25, 0.47, metal(c * 1.25, gloss=0.8), bevel=0.02)
    cv.circle(0.5, 0.54, 0.21, 0.36, solid(rgb("#4a86b2"), var=0.04, gloss=0.9), bevel=0.02, base=0.47)
    cv.line(0.2, 0.54, 0.38, 0.2, 0.025, 0.55, metal(STEEL_D, gloss=0.6), bevel=0.01)
    cv.line(0.38, 0.2, 0.62, 0.2, 0.025, 0.55, metal(STEEL_D, gloss=0.6), bevel=0.01)
    cv.line(0.62, 0.2, 0.8, 0.54, 0.025, 0.55, metal(STEEL_D, gloss=0.6), bevel=0.01)

def bench(cv, w, h, c):
    for i in range(w + 1):
        x = min(max(i, 0.2), w - 0.2)
        cv.rect(x - 0.05, 0.12, x + 0.05, 0.88, 0.4, metal(BLACK, gloss=0.4), r=0.02, bevel=0.02)
    for k in range(4):
        y = 0.2 + k * 0.17
        cv.rect(0.06, y, w - 0.06, y + 0.13, 0.5 + (0.15 if k == 0 else 0), wood(rgb("#9a6a3a"), freq=6), r=0.02, bevel=0.02)


def trash_bin(cv, c):
    c = c if c is not None else rgb("#3f6a46")
    cv.circle(0.5, 0.5, 0.3, 0.6, painted(c, gloss=0.4), bevel=0.04)
    cv.circle(0.5, 0.5, 0.24, 0.45, solid(rgb("#1c1d1e")), bevel=0.03, base=0.6)
    rng = np.random.default_rng(5)
    for k in range(5):
        a = rng.random() * 6.28
        cv.circle(0.5 + 0.1 * math.cos(a), 0.5 + 0.1 * math.sin(a), 0.06, 0.5, solid([rgb("#e8e4da"), rgb("#9a7a4a"), rgb("#5a6a7a")][k % 3]), bevel=0.03)


def dumpster(cv, w, h, c):
    c = c if c is not None else rgb("#3f6a46")
    cv.rect(0.05, 0.1, w - 0.05, h - 0.08, 0.95, painted(c, gloss=0.35), r=0.03, bevel=0.03)
    cv.rect(0.1, 0.14, w / 2 - 0.02, h - 0.14, 1.0, painted(c * 0.9, gloss=0.35), r=0.02, bevel=0.02)
    cv.rect(w / 2 + 0.02, 0.14, w - 0.1, h - 0.14, 1.0, painted(c * 0.9, gloss=0.35), r=0.02, bevel=0.02)
    for x in (0.4, 0.75, w - 0.75, w - 0.4):
        cv.groove(x - 0.01, 0.18, x + 0.01, h - 0.18, depth=0.01, dark=0.65)
    for x in (0.1, w - 0.1):
        cv.rect(x - 0.06, 0.35, x + 0.06, 0.65, 0.98, metal(STEEL_D), r=0.02, bevel=0.02)
    rust = np.clip(fbm(cv.h, cv.w, 5, 7, 3) - 0.35, 0, 1) * 0.6 * cv.alpha
    cv.col = cv.col * (1 - rust[..., None]) + np.asarray(rgb("#6b3e22"))[None, None, :] * rust[..., None]


def park_table(cv, w, h, c):
    for y in (0.08, 0.76):
        cv.rect(0.12, y, w - 0.12, y + 0.16, 0.45, wood(rgb("#9a6a3a"), freq=6), r=0.02, bevel=0.02)
    for k in range(3):
        y = 0.3 + k * 0.14
        cv.rect(0.05, y, w - 0.05, y + 0.12, 0.75, wood(rgb("#a8774a"), freq=6), r=0.02, bevel=0.02)


def street_cabinet(cv, c):
    cv.rect(0.12, 0.18, 0.88, 0.82, 0.9, painted(rgb("#6c7470"), gloss=0.3), r=0.03, bevel=0.03)
    cv.groove(0.494, 0.22, 0.506, 0.78, depth=0.02, dark=0.55)
    for k in range(4):
        cv.groove(0.18, 0.3 + k * 0.05, 0.42, 0.312 + k * 0.05, depth=0.01, dark=0.6)
    cv.rect(0.6, 0.42, 0.66, 0.58, 0.93, metal(CHROME), r=0.01, bevel=0.005)
    cv.rect(0.64, 0.26, 0.82, 0.34, 0.91, solid(rgb("#e3b62a")), r=0.005, bevel=0.0)


def plastic_table(cv, w, h, c):
    c = c if c is not None else rgb("#d6d3c8")
    cv.rect(0.08, 0.12, w - 0.08, h - 0.12, 0.75, plastic(c, gloss=0.35), r=0.12, bevel=0.04)
    for k in range(6):
        cv.groove(0.18 + k * (w - 0.36) / 5, 0.2, 0.19 + k * (w - 0.36) / 5, h - 0.2, depth=0.006, dark=0.85)


# --- lamps -------------------------------------------------------------------------------------------
def _glow(cv, x, y, r, z):
    cv.circle(x, y, r, z, solid(BULB, var=0.0, gloss=0.6), bevel=r * 0.8, dome=0.01, emit=0.85)


def wall_lamp(cv, c):
    cv.rect(0.18, 0.04, 0.82, 0.42, 0.6, metal(STEEL_D, gloss=0.5), r=0.08, bevel=0.04)
    cv.rect(0.24, 0.08, 0.76, 0.36, 0.65, solid(BULB, var=0.0, gloss=0.7), r=0.06, bevel=0.04, dome=0.02, emit=0.85)
    for x in (0.38, 0.62):
        cv.rect(x - 0.015, 0.08, x + 0.015, 0.36, 0.67, metal(STEEL_D, gloss=0.6), r=0.0, bevel=0.005)


def wall_strip(cv, c):
    cv.rect(0.04, 0.06, 0.96, 0.3, 0.55, metal(STEEL_D, gloss=0.5), r=0.04, bevel=0.03)
    cv.rect(0.08, 0.1, 0.92, 0.25, 0.6, solid(BULB, var=0.0, gloss=0.7), r=0.04, bevel=0.03, dome=0.01, emit=0.85)


def bulkhead_lamp(cv, c):
    cv.ellipse(0.5, 0.22, 0.33, 0.2, 0.6, metal(STEEL_D, gloss=0.5), bevel=0.05)
    cv.ellipse(0.5, 0.22, 0.25, 0.14, 0.65, solid(BULB, var=0.0, gloss=0.7), bevel=0.05, dome=0.02, emit=0.85)
    cv.rect(0.24, 0.205, 0.76, 0.235, 0.7, metal(STEEL_D, gloss=0.6), r=0.0, bevel=0.005)
    for x in (0.4, 0.6):
        cv.rect(x - 0.015, 0.09, x + 0.015, 0.35, 0.7, metal(STEEL_D, gloss=0.6), r=0.0, bevel=0.005)


def wall_beacon(cv, c):
    cv.rect(0.34, 0.05, 0.66, 0.2, 0.5, metal(STEEL_D, gloss=0.5), r=0.02, bevel=0.02)
    cv.circle(0.5, 0.3, 0.14, 0.7, metal(STEEL_D, gloss=0.5), bevel=0.03)
    cv.circle(0.5, 0.3, 0.1, 0.78, solid(BULB, var=0.0, gloss=0.8), bevel=0.06, dome=0.04, emit=0.9)


def ceiling_lamp(cv, c):
    cv.rect(0.2, 0.08, 0.8, 0.22, 0.7, metal(STEEL_D, gloss=0.5), r=0.02, bevel=0.02)
    cv.rect(0.16, 0.22, 0.84, 0.66, 0.75, metal(rgb("#3a3e43"), gloss=0.5), r=0.05, bevel=0.04)
    cv.rect(0.22, 0.28, 0.78, 0.6, 0.78, solid(BULB, var=0.0, gloss=0.7), r=0.04, bevel=0.03, emit=0.85)
    for k in range(4):
        y = 0.32 + k * 0.08
        cv.rect(0.22, y - 0.008, 0.78, y + 0.008, 0.8, metal(STEEL_D), r=0.0, bevel=0.0)


def streetlight(cv, c):
    cv.circle(0.5, 0.82, 0.1, 0.4, concrete(rgb("#8a8780")), bevel=0.03)
    cv.circle(0.5, 0.82, 0.05, 0.9, metal(STEEL_D, gloss=0.5), bevel=0.02)
    cv.line(0.5, 0.82, 0.5, 0.3, 0.05, 1.0, metal(STEEL_D, gloss=0.5), bevel=0.02)
    cv.ellipse(0.5, 0.22, 0.13, 0.17, 1.05, metal(rgb("#3a3e43"), gloss=0.5), bevel=0.04)
    cv.ellipse(0.5, 0.22, 0.09, 0.12, 1.08, solid(BULB, var=0.0, gloss=0.7), bevel=0.04, dome=0.02, emit=0.85)


def floodlight(cv, c):
    for a in (math.pi * 0.75, math.pi * 0.25, math.pi * 1.5):
        cv.line(0.5, 0.6, 0.5 + 0.38 * math.cos(a), 0.6 + 0.38 * math.sin(a), 0.04, 0.4, metal(STEEL_D), bevel=0.01)
    cv.rect(0.16, 0.1, 0.84, 0.5, 0.95, metal(rgb("#3a3e43"), gloss=0.5), r=0.04, bevel=0.04)
    cv.rect(0.21, 0.14, 0.79, 0.44, 1.0, solid(BULB, var=0.0, gloss=0.7), r=0.03, bevel=0.03, emit=0.85)
    for x in (0.4, 0.6):
        cv.rect(x - 0.01, 0.14, x + 0.01, 0.44, 1.02, metal(STEEL_D), r=0.0, bevel=0.0)


def bollard_light(cv, c):
    cv.circle(0.5, 0.5, 0.2, 0.7, metal(rgb("#3a3e43"), gloss=0.5), bevel=0.04)
    cv.circle(0.5, 0.5, 0.15, 0.75, solid(BULB, var=0.0, gloss=0.7), bevel=0.04, dome=0.02, emit=0.85)
    cv.circle(0.5, 0.5, 0.08, 0.82, metal(rgb("#3a3e43"), gloss=0.5), bevel=0.03)


def work_light(cv, c):
    for a in (math.pi * 0.6, math.pi * 0.2, math.pi * 1.4):
        cv.line(0.5, 0.55, 0.5 + 0.36 * math.cos(a), 0.55 + 0.36 * math.sin(a), 0.035, 0.35, metal(rgb("#d4a62a")), bevel=0.01)
    cv.rect(0.26, 0.2, 0.74, 0.55, 0.8, metal(rgb("#d4a62a"), gloss=0.4), r=0.04, bevel=0.03)
    cv.rect(0.3, 0.23, 0.7, 0.5, 0.85, solid(BULB, var=0.0, gloss=0.7), r=0.03, bevel=0.03, emit=0.85)
    for k in range(3):
        y = 0.29 + k * 0.08
        cv.rect(0.3, y - 0.006, 0.7, y + 0.006, 0.87, metal(BLACK), r=0.0, bevel=0.0)


def floor_lamp(cv, c):
    cv.circle(0.5, 0.5, 0.16, 0.15, metal(rgb("#2a2c2e"), gloss=0.5), bevel=0.04)
    cv.circle(0.5, 0.5, 0.32, 0.9, fabric(rgb("#c9a46a"), contrast=0.05), bevel=0.06, dome=0.03)
    cv.circle(0.5, 0.5, 0.25, 0.85, fabric(rgb("#d7b57c"), contrast=0.04), bevel=0.04, base=0.9)
    cv.circle(0.5, 0.5, 0.12, 0.95, solid(BULB, var=0.0, gloss=0.7), bevel=0.06, dome=0.04, emit=0.9)


def desk_lamp(cv, c):
    cv.rect(0.06, 0.08, 0.94, 0.82, 0.75, wood(WOOD, freq=8), r=0.03, bevel=0.03)
    cv.rect(0.4, 0.38, 0.88, 0.7, 0.77, solid(rgb("#f1eee6")), r=0.005, bevel=0.005)
    cv.circle(0.24, 0.26, 0.08, 0.8, metal(rgb("#2f5a3a"), gloss=0.5), bevel=0.02)
    cv.line(0.24, 0.26, 0.36, 0.42, 0.025, 0.95, metal(rgb("#2f5a3a"), gloss=0.5), bevel=0.01)
    cv.circle(0.36, 0.44, 0.12, 1.0, metal(rgb("#2f5a3a"), gloss=0.6), bevel=0.04)
    cv.circle(0.36, 0.44, 0.07, 1.02, solid(BULB, var=0.0, gloss=0.7), bevel=0.03, dome=0.02, emit=0.9)


def lamp(cv, c):
    cv.circle(0.5, 0.5, 0.22, 0.4, ceramic(rgb("#6a7f8f"), gloss=0.5), bevel=0.05)
    cv.circle(0.5, 0.5, 0.26, 0.85, fabric(rgb("#ece4d0"), contrast=0.04), bevel=0.05, dome=0.02)
    cv.circle(0.5, 0.5, 0.13, 0.9, solid(BULB, var=0.0, gloss=0.7), bevel=0.05, dome=0.03, emit=0.9)


SINGLE = {k: v for k, v in globals().items() if callable(v) and k in (
    "chair armchair nightstand coffee_table cabinet refrigerator potted_plant tv_stand stove toilet sink "
    "vending_machine water_cooler console tool_cabinet pallet crate barrel equipment_cart toolbox ammo_crate "
    "washing_machine target vent_fan specimen_fridge gas_canister water_bucket trash_bin street_cabinet "
    "wall_lamp wall_strip bulkhead_lamp wall_beacon ceiling_lamp streetlight floodlight bollard_light "
    "work_light floor_lamp desk_lamp lamp").split()}
JOINED = {k: v for k, v in globals().items() if callable(v) and k in (
    "sofa bed bunk_bed desk office_desk dining_table wardrobe dresser bookshelf kitchen_counter piano "
    "conference_table filing_cabinet locker reception_desk display_shelf checkout_counter workbench "
    "storage_shelf server_rack industrial_cabinet generator machinery exam_table fuel_tank steel_table "
    "lab_bench morgue_drawers biohazard_cabinet bench dumpster park_table plastic_table").split()}
