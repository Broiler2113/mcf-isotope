"""Build the game's UI fonts from the Handjet variable font (release 0.12.1).

Handjet draws every letter as a grid of separate square "pixel" components that only touch.
At fractional sizes (Retina scaling, interface scale) anti-aliasing leaves a faint seam where
two rows meet, which players saw as "a line in the center of each word". This script pins the
variation axes, decomposes the components and merges each glyph into solid outlines, so no
internal edge is left to seam. The zero also gets a diagonal slash so it can't be misread as 8.

    python tools/font/build_handjet_ui.py [Handjet variable .ttf, default tools/font/handjet_ui_source.ttf]

Writes fonts/handjet_ui.ttf (wght 400) and fonts/handjet_ui_bold.ttf (wght 650). Needs
fonttools and skia-pathops. The source is the variable font the game shipped before 0.12.1
(kept as tools/font/handjet_ui_source.ttf so this can be re-run).
"""
import os
import sys

from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont
from fontTools.ttLib.removeOverlaps import removeOverlaps
from fontTools.varLib.instancer import instantiateVariableFont

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "fonts")
PIXEL = 480
# Slashed zero: the O plus a diagonal through its 3×9 interior, bottom-left to top-right.
SLASH = [(960, 960), (960, 1440), (1440, 1920), (1440, 2400), (1440, 2880), (1920, 3360), (1920, 3840)]


def slashed_zero(font: TTFont) -> None:
    glyf = font["glyf"]
    zero = glyf[font.getBestCmap()[ord("0")]]
    o = glyf[font.getBestCmap()[ord("O")]]
    if not (zero.isComposite() and o.isComposite()):
        raise SystemExit("unexpected glyph structure: 0 / O are not pixel composites")
    template = o.components[0]
    comps = []
    for c in o.components:
        comps.append(c)
    for x, y in SLASH:
        c = type(template)()
        c.glyphName = template.glyphName
        c.x, c.y = x, y
        c.flags = template.flags
        comps.append(c)
    zero.components = comps


def decompose(font: TTFont) -> None:
    glyf = font["glyf"]
    gs = font.getGlyphSet()
    for name in font.getGlyphOrder():
        g = glyf[name]
        if not g.isComposite():
            continue
        rec = DecomposingRecordingPen(gs)
        gs[name].draw(rec)
        pen = TTGlyphPen(None)
        rec.replay(pen)
        glyf[name] = pen.glyph()


def build(src: str, weight: int, name: str, style: str) -> None:
    font = TTFont(src)
    if "fvar" in font:
        font = instantiateVariableFont(font, {"wght": weight, "ELGR": 1, "ELSH": 2})
    slashed_zero(font)
    decompose(font)
    # Touching (not overlapping) squares are exactly the seam case, so every glyph is first
    # flattened to plain contours; the union then merges the shared edges away.
    removeOverlaps(font)
    for rec in font["name"].names:
        if rec.nameID == 2:
            rec.string = style
        elif rec.nameID == 4:
            rec.string = "Handjet UI " + style
        elif rec.nameID == 6:
            rec.string = "HandjetUI-" + style
        elif rec.nameID == 1:
            rec.string = "Handjet UI"
    out = os.path.join(OUT, name)
    font.save(out)
    print("wrote", os.path.normpath(out))


if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "handjet_ui_source.ttf")
    build(src, 400, "handjet_ui.ttf", "Regular")
    build(src, 650, "handjet_ui_bold.ttf", "Bold")
