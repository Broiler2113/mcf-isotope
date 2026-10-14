"""Render the small items (0.12.1) into textures/items/item_<kind>/item_<kind>.png.

    /root/.venvs/mcf-rl/bin/python tools/art/build_items.py   # from the project root
    godot --headless --import

The list of kinds must match SmallItems.KINDS in src/data/SmallItems.gd.
"""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from core import *
from items import ITEMS

OUT = "textures/items"


def main():
    for kind, fn in ITEMS.items():
        cv = Canvas(1, 1, seed=7)
        fn(cv)
        img = cv.image(shadow_strength=0.45)
        name = "item_" + kind
        folder = os.path.join(OUT, name)
        os.makedirs(folder, exist_ok=True)
        img.save(os.path.join(folder, name + ".png"))
        print(name)


if __name__ == "__main__":
    main()
