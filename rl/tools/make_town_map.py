#!/usr/bin/env python
"""Build the town training map for the RL pool (spec 8.2.2) from the shipped maps/town.json.

The shipped map carries terrain, twelve civilians and three deployment zones but no army:
a human picks the squad in Placement. A training map cannot ask anybody anything, so this
writes the same terrain with both armies already on it — the composition below, mirrored
across the map's horizontal axis so neither side gets the better half of the town.

    python rl/tools/make_town_map.py [--out rl/maps/town_50x50.json] [--scale 1.0]

`--scale` shrinks every count by the same factor (rounded up, vehicles kept) — the full
army is ~8800 legal intents per decision point, so a smaller cut is the one to train on
first. Deployment zones are dropped: the env server spawns straight from `spawns`, and a
neutral zone left in the file would materialise 144 more civilians on load (MapData
`_materialize_neutral_zones`).
"""
from __future__ import annotations

import argparse
import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(PROJECT, "maps", "town.json")
OUT = os.path.join(PROJECT, "rl", "maps", "town_50x50.json")

NEUTRAL = 26          # MCF.Owner.NEUTRAL; map version 2 writes it as this number
MAP_VERSION = 2

# One side's army. "shield barrier" is the shield_bearer unit — the barrier is what it
# carries; there is no separate barrier entity in src/data/units.
INFANTRY = [
    ("light_infantry", 50),
    ("heavy_infantry", 35),
    ("shield_bearer", 15),
    ("machinegunner", 20),
    ("sniper", 15),
    ("anti_tank", 10),
    ("marksman", 4),
    ("flamethrower", 1),
    ("engineer", 10),
    ("sapper", 8),
    ("drone_operator", 5),
]
# (id, width, height, anchor x) — anchored at the back rows of the deployment band.
VEHICLES = [("tank", 3, 3, 10), ("shuttle", 2, 2, 20), ("borg", 1, 1, 30)]


def free_cell(m: dict, x: int, y: int) -> bool:
    i = y * m["width"] + x
    return (m["is_space"][i] == 0 and m["feature_id"][i] == ""
            and float(m["cover_height"][i]) == 0.0)


def band(m: dict, owner: int) -> list[int]:
    """The rows this side deploys in, front row first, read off the map's own zones."""
    w, h = m["width"], m["height"]
    rows = sorted({i // w for i, o in enumerate(m["zone_owner"]) if o == owner})
    if not rows:
        raise SystemExit(f"{SRC} has no deployment zone for owner {owner}")
    # Front = the row nearest the middle of the map.
    return sorted(rows, key=lambda y: abs(y - (h - 1) / 2))


def place(m: dict, owner: int, roster: list[tuple[str, int]]) -> list[dict]:
    w = m["width"]
    rows = band(m, owner)
    back = rows[-1]
    taken: set[tuple[int, int]] = set()
    out: list[dict] = []
    for vid, vw, vh, ax in VEHICLES:
        # The footprint grows towards the front line, so it stays inside the band.
        top = back if back < rows[0] else back - (vh - 1)
        cells = [(ax + dx, top + dy) for dx in range(vw) for dy in range(vh)]
        if not all(free_cell(m, x, y) and (x, y) not in taken for x, y in cells):
            raise SystemExit(f"no room for {vid} at ({ax},{top}) in owner {owner}'s zone")
        taken.update(cells)
        out.append({"stats_id": vid, "owner": owner, "x": ax, "y": top})
    queue = [sid for sid, n in roster for _ in range(n)]
    for y in rows:
        for x in range(w):
            if not queue:
                return out
            if (x, y) in taken or not free_cell(m, x, y):
                continue
            out.append({"stats_id": queue.pop(0), "owner": owner, "x": x, "y": y})
    raise SystemExit(f"owner {owner}'s zone is {len(queue)} cells short for this army")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--src", default=SRC)
    p.add_argument("--out", default=OUT)
    p.add_argument("--scale", type=float, default=1.0, help="multiply every infantry count")
    a = p.parse_args()

    with open(a.src) as f:
        m = json.load(f)
    roster = [(sid, max(1, math.ceil(n * a.scale))) for sid, n in INFANTRY]

    spawns = place(m, 0, roster) + place(m, 1, roster)
    # The civilians the map already carries, re-numbered for map version 2. They only
    # appear when a config sets civilians: true.
    for s in m["spawns"]:
        spawns.append({"stats_id": s["stats_id"], "owner": NEUTRAL, "x": s["x"], "y": s["y"]})

    out = dict(m)
    out["version"] = MAP_VERSION
    out["spawns"] = spawns
    out["zone_owner"] = [-1] * (m["width"] * m["height"])
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(out, f, indent="\t")

    per_side = sum(n for _, n in roster) + len(VEHICLES)
    print(f"{a.out}: {m['width']}x{m['height']}, {per_side} per side, "
          f"{len(spawns)} spawns (+{len(m['spawns'])} civilians)")


if __name__ == "__main__":
    main()
