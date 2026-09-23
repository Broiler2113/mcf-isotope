#!/usr/bin/env python
"""Build the town training map for the RL pool (spec 8.2.2) from the shipped maps/town.json.

The shipped map carries terrain, twelve civilians and three deployment zones but no army:
a human picks the squad in Placement. A training map cannot ask anybody anything, so this
writes the same terrain with both armies already on it — the composition below, mirrored
across the map's horizontal axis so neither side gets the better half of the town.

    python rl/tools/make_town_map.py [--out rl/maps/town_50x50.json] [--scale 1.0] [--inset 0]

`--scale` shrinks every infantry count by the same factor (rounded up, so every unit type
stays on the map; vehicles are never scaled). The full army is ~8800 legal intents per
decision point and a match runs ~2900 env steps, of which the policy learns from maybe a
hundred and forty a day — a smaller cut is the one to train on first, and `--scale 0.25`
is the measured sweet spot: every type present, matches ~4x shorter.

`--inset` moves BOTH armies that many rows towards the middle of the map. The shipped
zones sit at the two edges, 39 rows apart: fine for 176 units a side, but with a platoon
the first third of every match is walking, and walking is exactly the part we are trying
to stop paying for. The terrain is untouched — only where the armies stand changes.

Deployment zones are dropped: the env server spawns straight from `spawns`, and a neutral
zone left in the file would materialise 144 more civilians on load (MapData
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
# (id, width, height, preferred anchor x).
VEHICLES = [("tank", 3, 3, 10), ("shuttle", 2, 2, 20), ("borg", 1, 1, 30)]

# How many rows BEHIND the front rank the vehicles park.
#
# Vehicles spawn empty and rl/env_server.gd crews them at reset from whoever stands next to
# them, so a vehicle with no infantry in reach stays at crew 0 and ap 0 — permanently
# unusable. The old layout parked them on the back row of the zone, which worked only
# because 173 infantry filled the zone right up to it; at --scale 0.25 the 47 infantry fit
# in the front rank alone and every vehicle would have spawned crewless. Parking them one
# row behind the front rank makes adjacency hold at ANY scale: the front rank fills first,
# so there is always somebody to climb in.
#
# NOTE: the committed rl/maps/town_50x50.json predates this and still parks its vehicles on
# the back rank. It is left as it is on purpose — town-3's 24-hour baseline was measured on
# that exact file, and regenerating it would silently change what those numbers mean.
# Re-running this tool with --scale 1.0 produces the new layout, not that file.
VEH_ROW_OFFSET = 1


def free_cell(m: dict, x: int, y: int) -> bool:
    if not (0 <= x < m["width"] and 0 <= y < m["height"]):
        return False
    i = y * m["width"] + x
    return (m["is_space"][i] == 0 and m["feature_id"][i] == ""
            and float(m["cover_height"][i]) == 0.0)


def band(m: dict, owner: int, inset: int) -> list[int]:
    """The rows this side deploys in, front rank first, read off the map's own zones."""
    w, h = m["width"], m["height"]
    mid = (h - 1) / 2
    rows = sorted({i // w for i, o in enumerate(m["zone_owner"]) if o == owner})
    if not rows:
        raise SystemExit(f"{SRC} has no deployment zone for owner {owner}")
    # Front = the row nearest the middle of the map; `inset` slides the whole band that way.
    rows.sort(key=lambda y: abs(y - mid))
    toward = 1 if rows[0] < mid else -1
    rows = [y + toward * inset for y in rows]
    if not all(0 <= y < h for y in rows):
        raise SystemExit(f"inset {inset} pushes owner {owner}'s band off the map")
    return rows


def place_vehicles(m: dict, owner: int, rows: list[int], taken: set) -> list[dict]:
    """Park the vehicles one row behind the front rank, searching sideways for room."""
    front = rows[0]
    step = 1 if rows[-1] > front else -1        # front -> back
    out = []
    for vid, vw, vh, pref in VEHICLES:
        near = front + step * VEH_ROW_OFFSET
        far = front + step * (VEH_ROW_OFFSET + vh - 1)
        if far not in rows:
            raise SystemExit(f"owner {owner}'s band is too shallow for {vid} ({vh} rows)")
        top = min(near, far)
        # Preferred anchor first, then alternate outwards — the town rows are broken up by
        # buildings, so a fixed x is not guaranteed to have room for a 3x3 hull.
        for dx in [0] + [d for k in range(1, m["width"]) for d in (-k, k)]:
            ax = pref + dx
            cells = [(ax + cx, top + cy) for cx in range(vw) for cy in range(vh)]
            if all(free_cell(m, x, y) and (x, y) not in taken for x, y in cells):
                taken.update(cells)
                out.append({"stats_id": vid, "owner": owner, "x": ax, "y": top})
                break
        else:
            raise SystemExit(f"no room for {vid} in owner {owner}'s band at row {top}")
    return out


def place(m: dict, owner: int, roster: list[tuple[str, int]], inset: int,
          reserved: set) -> list[dict]:
    w = m["width"]
    rows = band(m, owner, inset)
    taken: set[tuple[int, int]] = set(reserved)
    out = place_vehicles(m, owner, rows, taken)
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
    p.add_argument("--inset", type=int, default=0,
                   help="rows to move BOTH armies towards the middle of the map")
    a = p.parse_args()

    with open(a.src) as f:
        m = json.load(f)
    roster = [(sid, max(1, math.ceil(n * a.scale))) for sid, n in INFANTRY]
    # The map's own civilians only wake when a config sets civilians: true, but their cells
    # are reserved either way — an army standing on top of them would be a latent conflict
    # that only shows up the day somebody flips that flag.
    civ = {(s["x"], s["y"]) for s in m["spawns"]}

    spawns = (place(m, 0, roster, a.inset, civ)
              + place(m, 1, roster, a.inset, civ))
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
    fronts = [band(m, o, a.inset)[0] for o in (0, 1)]
    print(f"{a.out}: {m['width']}x{m['height']}, {per_side} per side, "
          f"{len(spawns)} spawns (+{len(m['spawns'])} civilians)")
    print("  roster: " + ", ".join(f"{sid} {n}" for sid, n in roster)
          + ", " + ", ".join(vid for vid, _, _, _ in VEHICLES) + " 1 each")
    print(f"  front ranks: row {fronts[0]} vs row {fronts[1]} "
          f"({abs(fronts[0] - fronts[1])} rows apart, inset {a.inset})")


if __name__ == "__main__":
    main()
