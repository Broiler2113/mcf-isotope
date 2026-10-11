"""Render every furniture texture into res://textures/furniture (0.11 art pass).

    /root/.venvs/mcf-rl/bin/python tools/art/build_furniture.py   # from the project root
    godot --headless --import

Per id: <id>.png (the tile / palette icon), plus for joined pieces <id>_autotile.png (16-tile
sheet, mask N1 E2 S4 W8, back at the top) and, for pieces with one fixed size,
<id>_piece.png (the whole piece as one picture). sample.png is the marked-up template.
"""
import json, os, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from core import *
import furniture as F

OUT = "textures/furniture"


def defs():
    run = subprocess.run(["godot", "--headless", "--script", "res://tools/art/furniture_defs.gd"],
                         capture_output=True, text=True, check=True)
    line = next(l for l in run.stdout.splitlines() if l.startswith("@@"))
    return json.loads(line[2:])


def render(fn, w, h, colour, joined):
    cv = Canvas(w, h, seed=3)
    fn(cv, w, h, colour) if joined else fn(cv, colour)
    return cv.image()


def icon_of(piece):
    """The whole piece shrunk into one tile, centred (palette icon)."""
    k = T / max(piece.width, piece.height)
    small = piece.resize((max(1, round(piece.width * k)), max(1, round(piece.height * k))), Image.LANCZOS)
    out = Image.new("RGBA", (T, T), (0, 0, 0, 0))
    out.alpha_composite(small, ((T - small.width) // 2, (T - small.height) // 2))
    return out


def main():
    for d in defs():
        fid, base = d["id"], d["base"]
        colour = rgb(d["tint"]) if d["tint"] else None
        folder = os.path.join(OUT, fid)
        os.makedirs(folder, exist_ok=True)
        save = lambda img, name: img.save(os.path.join(folder, name + ".png"))
        if base in F.SINGLE:
            img = render(F.SINGLE[base], 1, 1, colour, False)
            save(img, fid)
            save(sample_of(img, False), "sample")
            continue
        fn = F.JOINED[base]
        sheet = sheet_from(lambda cv, w, h: fn(cv, w, h, colour), seed=3)
        save(sheet, fid + "_autotile")
        save(sample_of(sheet, True), "sample")
        sizes = d["sizes"]
        if d["join"] == "whole" and len(sizes) == 1:
            piece = render(fn, int(sizes[0][0]), int(sizes[0][1]), colour, True)
            save(piece, fid + "_piece")
            save(icon_of(piece), fid)
        else:
            save(slice_cell(sheet, 0, 0), fid)
        print(fid)


if __name__ == "__main__":
    main()
