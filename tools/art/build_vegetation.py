#!/usr/bin/env python3
"""Billboards of real plants for first person and grass tufts for the board (issues-14 #6, #7).

CC0 plant scans from Poly Haven (polyhaven.com, public domain) are fetched into the git-ignored
.cache/polyhaven, rendered by Godot (tools/art/render_vegetation.gd) from three sides and from
above, then shrunk into the game's pixel look:

    textures/first_person/veg/veg_<name>.png    three side views in a row: the cards FirstPersonBoard
                                                stands round a plant's centre
    textures/first_person/veg/veg_tuft_<k>.png  a grass tuft seen from above, 32 px a metre: the board

    python3 tools/art/build_vegetation.py          (numpy + PIL; Godot and xvfb-run on PATH)
    python3 tools/art/build_vegetation.py --grass  (the drawn grass only)
"""
import json
import subprocess
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / ".cache/polyhaven"
RENDERS = ROOT / ".cache/vegetation"
OUT = ROOT / "textures/first_person/veg"
UA = {"User-Agent": "mcf-isotope-art-build"}

# name: (model, root nodes drawn (all when empty), view, pixels, look). "side" is three views 60°
# apart, `pixels` tall each: the game sets the card's height in metres, so these are ~64 px a
# metre of it (grass a little finer). "top" is one view from above, `pixels` across on the board's
# 32 px cell. look: "dry" browns the leaves, "flowers" sprinkles blossom over them.
PLANTS = {
    "pine_a": ("fir_sapling_medium", ["fir_sapling_medium_a_LOD0"], "side", 330, ""),
    "pine_c": ("fir_sapling_medium", ["fir_sapling_medium_c_LOD0"], "side", 330, ""),
    "park_a": ("tree_small_02", [], "side", 300, ""),
    "park_b": ("island_tree_02", [], "side", 300, ""),
    "bush_a": ("searsia_lucida", ["searsia_lucida_a_LOD0"], "side", 64, ""),
    "bush_b": ("searsia_lucida", ["searsia_lucida_c_LOD0"], "side", 64, ""),
    "bush_c": ("searsia_lucida", ["searsia_lucida_e_LOD0"], "side", 64, ""),
    "bush_dry_a": ("searsia_lucida", ["searsia_lucida_f_LOD0"], "side", 64, "dry"),
    "bush_dry_b": ("searsia_lucida", ["searsia_lucida_g_LOD0"], "side", 64, "dry"),
    "bush_flowering_a": ("searsia_lucida", ["searsia_lucida_b_LOD0"], "side", 64, "flowers"),
    "bush_flowering_b": ("searsia_lucida", ["searsia_lucida_d_LOD0"], "side", 64, "flowers"),
    "fern": ("fern_02", ["fern_02_a"], "side", 48, ""),
    "palm": ("potted_plant_02", [], "side", 72, ""),
    "flowering": ("potted_plant_01", [], "side", 72, "flowers"),
}


def get(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers=UA)).read()


def fetch(model):
    """The 1k glTF and, for every material that is cut out, its alpha map (the glTF's
    textures carry none) as <cache>/<model>/alpha/<material>.<ext>."""
    files = json.loads(get(f"https://api.polyhaven.com/files/{model}"))
    gl = files["gltf"]["1k"]["gltf"]
    d = CACHE / model
    for url, rel in [(gl["url"], Path(gl["url"]).name)] + [(v["url"], k) for k, v in gl["include"].items()]:
        p = d / rel
        if not p.exists():
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(get(url))
    gltf = json.loads((d / Path(gl["url"]).name).read_text())
    for m in gltf.get("materials", []):
        name = m["name"]
        key = "Alpha" if name == model else name[len(model) + 1:] + "_alpha"
        if key not in files or list((d / "alpha").glob(name + ".*")):
            continue
        res = files[key].get("1k", {})
        fmt = "png" if "png" in res else "jpg"
        p = d / "alpha" / f"{name}.{fmt}"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(get(res[fmt]["url"]))


def views_of(img, views):
    """Each view keeps its centre (the plant's axis): cut empty columns equally from both sides,
    empty rows from the top and bottom."""
    a = np.asarray(img)[..., 3] > 8
    w = img.width // views
    used = [np.nonzero(a[:, v * w:(v + 1) * w].any(0))[0] for v in range(views)]
    half = int(np.ceil(max(max(w / 2 - u.min(), u.max() + 1 - w / 2) for u in used if len(u))))
    rows = np.nonzero(a.any(1))[0]
    return [img.crop((int(v * w + w / 2 - half), int(rows.min()), int(v * w + w / 2 + half), int(rows.max()) + 1))
            for v in range(views)]


def shrink(img, height):
    """Down to `height` pixels by the average of what each pixel covers (alpha-weighted, so the
    edges do not go dark), then cut crisp like the rest of the art."""
    width = max(1, round(img.width * height / img.height))
    small = img.convert("RGBa").resize((width, height), Image.BOX).convert("RGBA")
    a = np.asarray(small, np.float32) / 255
    a[..., 3] = (a[..., 3] > 0.45).astype(np.float32)
    return a


def look(a, kind, seed):
    """Dry leaves or blossom on the leaves (not the trunk: only where it is green)."""
    green = (a[..., 1] > a[..., 0] * 1.02) & (a[..., 3] > 0)
    if kind == "dry":
        g = a[..., :3].mean(-1, keepdims=True)
        dry = np.concatenate([g * 1.25, g * 1.05, g * 0.62], -1)
        a[..., :3] = np.where(green[..., None], dry, a[..., :3])
    elif kind == "flowers":
        rng = np.random.default_rng(seed)
        pick = green & (rng.random(green.shape) < 0.07)
        petals = np.array([[0.95, 0.5, 0.68], [0.98, 0.95, 0.96], [0.96, 0.78, 0.3]], np.float32)
        a[..., :3] = np.where(pick[..., None], petals[rng.integers(0, 3, green.shape)], a[..., :3])
    return a


# Grass is drawn here, blade by blade: scanned clumps shrunk to a few dozen pixels fall apart
# into specks. Greens from the photographed turf (build_first_person.PHOTOS).
BASE, MID, TIP, DRY = (np.array(c, np.float32) for c in
                       ((0.2, 0.29, 0.09), (0.27, 0.4, 0.12), (0.5, 0.6, 0.22), (0.6, 0.56, 0.3)))


def blade_colour(rng, t):
    c = MID + (TIP - MID) * t if t > 0 else BASE
    if rng.random() < 0.18:
        c = c + (DRY - c) * rng.random() * 0.8
    return np.clip(c * (0.85 + 0.3 * rng.random()), 0, 1)


def grass_card(seed, w, h, blades, tall=False):
    """A clump from the side, w x h pixels: blades rising from a spread at the foot, leaning
    and curving, tapering to a point; heads on tall grass."""
    from PIL import ImageDraw
    k = 4
    img = Image.new("RGBa", (w * k, h * k))
    d = ImageDraw.Draw(img)
    rng = np.random.default_rng(seed)
    for _ in range(blades):
        x0 = w * k * (0.5 + 0.32 * rng.normal())
        hgt = h * k * (0.45 + 0.55 * rng.random()) * (1.0 if not tall else 0.9)
        lean = (rng.random() - 0.5) * 0.9 + (x0 / (w * k) - 0.5) * 0.8
        width = k * (1.1 + 0.9 * rng.random())
        pts = []
        for i in range(9):
            t = i / 8
            pts.append((x0 + lean * hgt * t * t, h * k - 1 - hgt * t))
        for i in range(8):
            t = i / 8
            c = blade_colour(rng, t) if i or rng.random() < 0.5 else blade_colour(rng, 0.1)
            col = tuple(int(v * 255) for v in c) + (255,)
            d.line([pts[i], pts[i + 1]], fill=col, width=max(1, int(width * (1 - t * 0.85))))
        if tall and rng.random() < 0.35:
            hx, hy = pts[-1]
            d.ellipse([hx - k * 1.2, hy - k * 3, hx + k * 1.2, hy + k * 1.5], fill=(170, 150, 90, 255))
    small = img.resize((w, h), Image.BOX).convert("RGBA")
    a = np.asarray(small, np.float32) / 255
    a[..., 3] = (a[..., 3] > 0.4).astype(np.float32)
    return a


def tuft(seed, size, blades):
    """A tuft seen from above, size x size: blades fanning out from its heart, tips lighter."""
    from PIL import ImageDraw
    k = 4
    img = Image.new("RGBa", (size * k, size * k))
    d = ImageDraw.Draw(img)
    rng = np.random.default_rng(seed)
    c0 = size * k / 2
    for _ in range(blades):
        ang = rng.random() * 2 * np.pi
        r = size * k * 0.5 * (0.45 + 0.55 * rng.random())
        bend = (rng.random() - 0.5) * 0.8
        pts = [(c0 + np.cos(ang + bend * t * t) * r * t, c0 + np.sin(ang + bend * t * t) * r * t) for t in np.linspace(0, 1, 7)]
        for i in range(6):
            t = (i + 1) / 6
            col = tuple(int(v * 255) for v in blade_colour(rng, t)) + (255,)
            d.line([pts[i], pts[i + 1]], fill=col, width=max(1, int(k * 1.6 * (1 - t * 0.7))))
    small = img.resize((size, size), Image.BOX).convert("RGBA")
    a = np.asarray(small, np.float32) / 255
    a[..., 3] = (a[..., 3] > 0.45).astype(np.float32)
    return a


def save(a, name):
    # veg_: the board's sprite scan keys pictures by file name (tall_grass is a board sprite).
    Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA").save(OUT / f"veg_{name}.png")


def main(grass_only=False):
    OUT.mkdir(parents=True, exist_ok=True)
    if not grass_only:
        scans()
    # Grass: three side cards a clump each (FirstPersonBoard crosses them), tall grass, and four
    # tufts for the board.
    for i, name in enumerate(["grass_a", "grass_b", "grass_c"]):
        save(np.concatenate([grass_card(700 + i * 3 + v, 40, 32, 46) for v in range(3)], 1), name)
    save(np.concatenate([grass_card(720 + v, 48, 64, 34, tall=True) for v in range(3)], 1), "tall_grass")
    for i, size in enumerate([14, 16, 18, 20]):
        save(tuft(740 + i, size, 18 + 3 * i), f"tuft_{i}")


def scans():
    for model in sorted({p[0] for p in PLANTS.values()}):
        fetch(model)
    RENDERS.mkdir(parents=True, exist_ok=True)
    jobs = [{"name": n, "model": m, "nodes": nodes, "view": v} for n, (m, nodes, v, _, _) in PLANTS.items()]
    (RENDERS / "jobs.json").write_text(json.dumps(jobs))
    subprocess.run(["xvfb-run", "-a", "godot", "--path", str(ROOT), "--rendering-driver", "opengl3",
                    "--script", "res://tools/art/render_vegetation.gd"], check=True)
    OUT.mkdir(parents=True, exist_ok=True)
    for k, (name, (_, _, view, pixels, kind)) in enumerate(PLANTS.items()):
        img = Image.open(RENDERS / f"{name}.png").convert("RGBA")
        parts = views_of(img, 3 if view == "side" else 1)
        strips = [look(shrink(p, pixels), kind, k) for p in parts]
        if view == "top":
            # Square, the tuft in the middle.
            t = strips[0]
            side = max(t.shape[:2])
            sq = np.zeros((side, side, 4), np.float32)
            y0, x0 = (side - t.shape[0]) // 2, (side - t.shape[1]) // 2
            sq[y0:y0 + t.shape[0], x0:x0 + t.shape[1]] = t
            strips = [sq]
        w = max(s_.shape[1] for s_ in strips)
        out = np.zeros((pixels if view == "side" else strips[0].shape[0], w * len(strips), 4), np.float32)
        for i, s_ in enumerate(strips):
            x0 = i * w + (w - s_.shape[1]) // 2
            out[out.shape[0] - s_.shape[0]:, x0:x0 + s_.shape[1]] = s_
        save(out, name)
        print(name, out.shape[1], "x", out.shape[0])


if __name__ == "__main__":
    import sys
    main("--grass" in sys.argv)   # --grass: only the drawn grass, no Godot
