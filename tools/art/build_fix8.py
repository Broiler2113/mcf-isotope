"""Textures added in fix-8 (0.13.1), rendered with the same modelled-and-lit pipeline:

    <venv with numpy + pillow>/bin/python tools/art/build_fix8.py   # from the project root
    godot --headless --import

  * snowy outdoor plants for winter maps: textures/furniture/<id>/<id>_snow.png
  * the Czech hedgehog (alone and on sandbags) as real crossed angle irons: features/hedgehog*
  * a welded airlock and a boarded-up door, laid over the door picture: doors/weld_*.png
  * snow floors for winter maps: floors/floor_snow*, six seamless variants each
The furniture pieces themselves (botany, plants, winter decor) are in furniture.py and come
from build_furniture.py.
"""
import math, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from core import *
import furniture as F

VARIANTS = 6


def save(img, folder, name, sample_sheet=None):
    os.makedirs(folder, exist_ok=True)
    img.save(os.path.join(folder, name + ".png"))
    if sample_sheet is not None:
        sample_of(img, sample_sheet).save(os.path.join(folder, "sample.png"))


# --- snowy plants -------------------------------------------------------------------------
def snowy_plants():
    F.SNOW = True
    for fid in ["bush", "bush_dry", "bush_flowering", "park_tree", "pine_tree", "tall_grass"]:
        cv = Canvas(1, 1, seed=3)
        F.SINGLE[fid](cv, None)
        save(cv.image(), "textures/furniture/" + fid, fid + "_snow")
        print(fid + "_snow")
    for fid in ["hedge", "flower_bed"]:
        sheet = sheet_from(lambda cv, w, h, f=fid: F.JOINED[f](cv, w, h, None), seed=3)
        save(sheet, "textures/furniture/" + fid, fid + "_snow_autotile")
        save(slice_cell(sheet, 0, 0), "textures/furniture/" + fid, fid + "_snow")
        print(fid + "_snow")
    F.SNOW = False


# --- the hedgehog -------------------------------------------------------------------------
RUST = rgb("#6e4a34")
STEEL = rgb("#5d5650")


def hedgehog_on(cv, v, base=0.0):
    """Three angle-iron beams crossed at their middles, seen from above: three bars at 60°,
    each an L of a lit flange and a shaded one, the ends cut square, a gusset plate riveted
    at the crossing; each variant turned and rusted its own way."""
    a0 = v * 0.37
    rng = np.random.default_rng(40 + v)
    for k in range(3):
        a = a0 + k * math.pi / 3
        dx, dy = math.cos(a) * .42, math.sin(a) * .42
        z = base + .55 + k * .12
        col = STEEL * (0.9 + 0.2 * rng.random())
        cv.line(.5 - dx, .5 - dy, .5 + dx, .5 + dy, .1, z, metal(col, gloss=.25), bevel=.02)
        nx, ny = -math.sin(a) * .03, math.cos(a) * .03
        cv.line(.5 - dx + nx, .5 - dy + ny, .5 + dx + nx, .5 + dy + ny, .035, z + .08, metal(col * 1.15, gloss=.3), bevel=.01)
        for e in (-1, 1):
            cv.rect(.5 + e * dx - .035, .5 + e * dy - .035, .5 + e * dx + .035, .5 + e * dy + .035, z + .02,
                    metal(col * .8, gloss=.2), r=.005, bevel=.01)
    cv.circle(.5, .5, .085, base + .95, metal(STEEL * .85, gloss=.3), bevel=.02)
    for k in range(3):
        a = a0 + k * 2.094 + .5
        cv.circle(.5 + .045 * math.cos(a), .5 + .045 * math.sin(a), .014, base + .99, metal(STEEL * 1.2), bevel=.005)
    rust = np.clip(fbm(cv.h, cv.w, 5, 50 + v, 3) - 0.42, 0, 1) * 0.9 * cv.alpha
    cv.col = cv.col * (1 - rust[..., None]) + np.asarray(RUST)[None, None, :] * rust[..., None]


def bags_under(cv, v):
    rng = np.random.default_rng(60 + v)
    for row in range(3):
        for k in range(2 + row % 2):
            x0 = .04 + k * (.92 / (2 + row % 2))
            x1 = x0 + .92 / (2 + row % 2) - .03
            y0 = .08 + row * .29
            c = rgb("#a08e64") * (0.9 + 0.15 * rng.random())
            cv.rect(x0, y0, x1, y0 + .26, .3, fabric(c, contrast=.1), r=.08, bevel=.09, dome=.06)


def hedgehogs():
    for name, bags in (("hedgehog", False), ("hedgehog_sandbags", True)):
        strip = Image.new("RGBA", (T * VARIANTS, T), (0, 0, 0, 0))
        for v in range(VARIANTS):
            cv = Canvas(1, 1, seed=7 + v)
            if bags:
                bags_under(cv, v)
            hedgehog_on(cv, v, .35 if bags else 0.0)
            strip.alpha_composite(cv.image(), (v * T, 0))
        save(strip, "textures/features/" + name, name, False)
        print(name)


# --- welded and boarded doors ---------------------------------------------------------------
def welds():
    """Over a metal door picture: a rippled bead down the seam between the halves, tack welds
    across it, beads along the frame, the heat tint either side of every bead."""
    cv = Canvas(1, 1, seed=11)
    bead = metal(rgb("#9a9ca2"), gloss=.6)
    heat = [rgb("#b08a52"), rgb("#5a6aa0")]
    for side in (-1, 1):
        cv.rect(.5 + side * .045 - .02, .06, .5 + side * .045 + .02, .94, .02, solid(heat[0] * .9, var=.1), r=.01, bevel=0)
    cv.rect(.47, .05, .53, .95, .05, solid(heat[1], var=.1), r=.02, bevel=0)
    for k in range(30):
        y = .07 + k * .029
        cv.ellipse(.5, y, .03, .022, .09, bead, bevel=.015, dome=.01)
    for y in (.25, .5, .75):
        for k in range(5):
            cv.ellipse(.39 + k * .055, y, .022, .018, .1, bead, bevel=.012, dome=.01)
    for y in (.06, .94):
        for k in range(15):
            cv.ellipse(.08 + k * .06, y, .022, .016, .08, bead, bevel=.012, dome=.008)
    save(cv.image(shadow=False), "textures/doors/weld_metal", "weld_metal", False)


def boards():
    """Over a wooden door: three planks nailed across, the top and bottom slanted."""
    cv = Canvas(1, 1, seed=13)
    for (y0, y1, wcol) in ((.2, .3, "#8a6238"), (.55, .5, "#7d5733"), (.86, .78, "#93693d")):
        cv.line(.0, y0, 1.0, y1, .13, .3, wood(rgb(wcol), angle=math.atan2(y1 - y0, 1.0), freq=6), bevel=.02)
        for x in (.08, .92):
            y = y0 + (y1 - y0) * x
            cv.circle(x, y, .016, .34, metal(rgb("#3a3a3c"), gloss=.6), bevel=.005)
    save(cv.image(), "textures/doors/weld_wood", "weld_wood", False)


# --- snow floors ----------------------------------------------------------------------------
def snow_floor(kind):
    """Six seamless 32 px variants: fresh snow, snow trodden over earth, snow over a street."""
    strip = Image.new("RGBA", (T * VARIANTS, T), (0, 0, 0, 0))
    for v in range(VARIANTS):
        cv = Canvas(1, 1, opaque=True, seed=20 + v)
        drift = fbm(cv.h, cv.w, 3, 70 + v, 3)
        fine = fbm(cv.h, cv.w, 9, 80 + v, 2)
        base = np.asarray(rgb("#e4ebf3"))[None, None, :] * (0.9 + 0.1 * drift[..., None])
        if kind == "floor_snow_field":
            earth = np.asarray(rgb("#6a5440"))[None, None, :] * (0.8 + 0.3 * fine[..., None])
            k = np.clip((fine - 0.58) * 4.0, 0, 1)[..., None]
            base = base * (1 - k) + earth * k
        elif kind == "floor_town_snow":
            street = np.asarray(rgb("#5c5f63"))[None, None, :] * (0.85 + 0.25 * fine[..., None])
            k = np.clip((drift - 0.5) * 3.0, 0, 1)[..., None] * 0.85
            base = base * (1 - k) + street * k
        cv.col = np.clip(base * (1 - 0.04 * fine[..., None]), 0, 1).astype(np.float32)
        cv.hgt = (drift * .05 + fine * .015).astype(np.float32)
        strip.alpha_composite(cv.image(shadow=False), (v * T, 0))
    save(strip, "textures/floors/" + kind, kind, False)
    print(kind)


if __name__ == "__main__":
    snowy_plants()
    hedgehogs()
    welds()
    boards()
    for k in ("floor_snow", "floor_snow_field", "floor_town_snow"):
        snow_floor(k)
