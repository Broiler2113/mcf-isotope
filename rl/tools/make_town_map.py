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

# --- presets -------------------------------------------------------------------------
#
# A preset is just (infantry roster, vehicle list). "platoon" is the historical default and
# reproduces exactly what --scale/--inset always produced; anything else is a training map
# built to teach one thing.
#
# "tank": five tanks a side and nothing but light infantry to crew them. The point is
# SAMPLING, not flavour. On the platoon map one tank sits among fifty units, so vehicle
# intents are ~3% of the action mix and the policy sees a few hundred of them a day — far
# too thin a signal to learn gunnery from. Here every unit is either driving a tank or
# riding in one, so essentially every decision is a vehicle decision.
#
# Crew comes for free: rl/env_server.gd `_crew_vehicles()` boards adjacent infantry into
# every vehicle at reset, both sides, up to capacity. So the roster only has to put enough
# light infantry NEXT TO the hulls; 5 tanks x 3 crew = 15 is the floor, and the spares
# become a small screen. Pair this map with the disembark mask — without it the policy can
# simply park and walk away, which is the behaviour the map exists to prevent.
# Third field is `seat`: place the crew against the hulls before filling the rest of the
# band. It is OFF for "platoon" on purpose and must stay off. rl/maps/town_50x50_s25.json
# is the map town-7 has trained on for 2400+ updates, and this tool has to keep
# reproducing that exact file; seating changes the order the roster is consumed in and
# moves units (the anti-tank section jumps from x=38 to x=14). The platoon band does not
# need seating anyway — 47 infantry fill the front rank and reach the hulls on their own.
PRESETS: dict[str, tuple[list[tuple[str, int]], list[tuple[str, int, int, int]], bool]] = {
    "platoon": (INFANTRY, VEHICLES, False),
    "tank": (
        [("light_infantry", 20)],
        [("tank", 3, 3, 6), ("tank", 3, 3, 14), ("tank", 3, 3, 22),
         ("tank", 3, 3, 30), ("tank", 3, 3, 38)],
        True,
    ),
}

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


def place_vehicles(m: dict, owner: int, rows: list[int], taken: set,
                   vehicles: list[tuple[str, int, int, int]]) -> list[dict]:
    """Park the vehicles one row behind the front rank, searching sideways for room."""
    front = rows[0]
    step = 1 if rows[-1] > front else -1        # front -> back
    out = []
    for vid, vw, vh, pref in vehicles:
        # Preferred row offset first, then deeper into the band. One row is enough for the
        # platoon preset's three hulls, but five 3x3 tanks need ~15 clear columns and the
        # town rows are broken up by buildings, so at most insets they simply do not fit
        # abreast. Falling back to deeper rows is safe now that seat_crew() puts the crew
        # against the hull wherever it ends up, instead of relying on the front rank.
        placed = False
        # Deeper rows first, then the front rank itself as a last resort. Offset 0 used to
        # be forbidden outright so that infantry filling the front rank would end up
        # against the hulls; seat_crew() now guarantees that directly, so the ban only
        # costs us room. It matters here: in the town band the ONLY rows with space for
        # five 3x3 hulls are the front three, and excluding offset 0 made the map
        # ungeneratable at every inset that mattered.
        for off in list(range(VEH_ROW_OFFSET, len(rows))) + [0]:
            near = front + step * off
            far = front + step * (off + vh - 1)
            if far not in rows:
                continue        # this offset runs off the band; a shallower one may not
            top = min(near, far)
            # Preferred anchor first, then alternate outwards.
            for dx in [0] + [d for k in range(1, m["width"]) for d in (-k, k)]:
                ax = pref + dx
                cells = [(ax + cx, top + cy) for cx in range(vw) for cy in range(vh)]
                if all(free_cell(m, x, y) and (x, y) not in taken for x, y in cells):
                    taken.update(cells)
                    out.append({"stats_id": vid, "owner": owner, "x": ax, "y": top,
                                "_w": vw, "_h": vh})
                    placed = True
                    break
            if placed:
                break
        if not placed:
            raise SystemExit(f"no room for {vid} anywhere in owner {owner}'s band")
    return out


def seat_crew(m: dict, owner: int, hulls: list[dict], rows: list[int], taken: set,
              queue: list[str], per_hull: int = 3) -> list[dict]:
    """Put infantry in the cells touching each hull, before filling anything else.

    Vehicles spawn EMPTY and rl/env_server.gd `_crew_vehicles()` crews them from whoever
    is standing adjacent at reset; a hull with nobody in reach stays crew 0 / ap 0 and is
    dead weight for the whole episode. The old row-scan filled the band left to right and
    only happened to reach the hulls because 47+ infantry covered the front rank. On a map
    built AROUND its vehicles that coincidence is gone — the tank preset has 20 infantry on
    a 50-wide map, so a left-to-right fill seats nobody and all five tanks start crewless.

    Seating the ring first makes crewing hold for any preset, inset and terrain.

    Seating is capped per hull and done in TWO passes. A single greedy pass drains the
    whole roster into the first hull's ring — the tank preset's 20 infantry all fit around
    hulls one and two (12 + 8), leaving the other three tanks with nobody in reach and
    crewless for the entire episode, which is the exact failure this function exists to
    prevent. So pass one gives every hull `per_hull` bodies, and only then does pass two
    hand out whatever is left.
    """
    out: list[dict] = []

    def ring(h: dict) -> list[tuple[int, int]]:
        return [(h["x"] + dx, h["y"] + dy)
                for dx in range(-1, h["_w"] + 1) for dy in range(-1, h["_h"] + 1)
                if dx in (-1, h["_w"]) or dy in (-1, h["_h"])]

    for cap in (per_hull, len(queue)):
        for h in hulls:
            seated = 0
            for x, y in ring(h):
                if not queue or seated >= cap:
                    break
                if y not in rows or (x, y) in taken or not free_cell(m, x, y):
                    continue
                taken.add((x, y))
                out.append({"stats_id": queue.pop(0), "owner": owner, "x": x, "y": y})
                seated += 1
    return out


def place(m: dict, owner: int, roster: list[tuple[str, int]], inset: int,
          reserved: set, vehicles: list[tuple[str, int, int, int]],
          seat: bool) -> list[dict]:
    w = m["width"]
    rows = band(m, owner, inset)
    taken: set[tuple[int, int]] = set(reserved)
    hulls = place_vehicles(m, owner, rows, taken, vehicles)
    queue = [sid for sid, n in roster for _ in range(n)]
    out = hulls + (seat_crew(m, owner, hulls, rows, taken, queue) if seat else [])
    for y in rows:
        for x in range(w):
            if not queue:
                return [strip(s) for s in out]
            if (x, y) in taken or not free_cell(m, x, y):
                continue
            out.append({"stats_id": queue.pop(0), "owner": owner, "x": x, "y": y})
    raise SystemExit(f"owner {owner}'s zone is {len(queue)} cells short for this army")


def strip(spawn: dict) -> dict:
    """Drop the internal hull-size keys — they are scaffolding, not map format."""
    return {k: v for k, v in spawn.items() if not k.startswith("_")}


def check_crewable(m: dict, vehicles: list[tuple[str, int, int, int]],
                   need: int = 3) -> None:
    """Fail the build if any hull has nobody in reach to crew it.

    A crewless vehicle is not a visibly broken map — it loads, the match runs, and the
    hull simply sits at crew 0 / ap 0 for the whole episode while the action mix quietly
    shows no vehicle intents. That is indistinguishable from "the policy chose not to use
    its tanks", which is the exact question these maps exist to answer, so it has to be
    impossible to ship rather than something somebody notices later.
    """
    size = {vid: (vw, vh) for vid, vw, vh, _ in vehicles}
    infantry = {}
    for s in m["spawns"]:
        if s["stats_id"] not in size and s["owner"] != NEUTRAL:
            infantry.setdefault(s["owner"], set()).add((s["x"], s["y"]))
    bad = []
    for s in m["spawns"]:
        if s["stats_id"] not in size:
            continue
        vw, vh = size[s["stats_id"]]
        ring = {(s["x"] + dx, s["y"] + dy)
                for dx in range(-1, vw + 1) for dy in range(-1, vh + 1)
                if dx in (-1, vw) or dy in (-1, vh)}
        n = len(ring & infantry.get(s["owner"], set()))
        if n < need:
            bad.append(f"{s['stats_id']} owner {s['owner']} at ({s['x']},{s['y']}): "
                       f"{n} infantry in reach, needs {need}")
    if bad:
        raise SystemExit("crewless vehicles would ship:\n  " + "\n  ".join(bad))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--src", default=SRC)
    p.add_argument("--out", default=OUT)
    p.add_argument("--scale", type=float, default=1.0, help="multiply every infantry count")
    p.add_argument("--inset", type=int, default=0,
                   help="rows to move BOTH armies towards the middle of the map")
    p.add_argument("--preset", default="platoon", choices=sorted(PRESETS),
                   help="which army to put on the terrain (see PRESETS)")
    a = p.parse_args()

    with open(a.src) as f:
        m = json.load(f)
    infantry, vehicles, seat = PRESETS[a.preset]
    roster = [(sid, max(1, math.ceil(n * a.scale))) for sid, n in infantry]
    # The map's own civilians only wake when a config sets civilians: true, but their cells
    # are reserved either way — an army standing on top of them would be a latent conflict
    # that only shows up the day somebody flips that flag.
    civ = {(s["x"], s["y"]) for s in m["spawns"]}

    spawns = (place(m, 0, roster, a.inset, civ, vehicles, seat)
              + place(m, 1, roster, a.inset, civ, vehicles, seat))
    for s in m["spawns"]:
        spawns.append({"stats_id": s["stats_id"], "owner": NEUTRAL, "x": s["x"], "y": s["y"]})

    out = dict(m)
    out["version"] = MAP_VERSION
    out["spawns"] = spawns
    out["zone_owner"] = [-1] * (m["width"] * m["height"])
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(out, f, indent="\t")

    check_crewable(out, vehicles)

    per_side = sum(n for _, n in roster) + len(vehicles)
    fronts = [band(m, o, a.inset)[0] for o in (0, 1)]
    print(f"{a.out}: {m['width']}x{m['height']}, preset {a.preset}, {per_side} per side, "
          f"{len(spawns)} spawns (+{len(m['spawns'])} civilians)")
    veh_counts: dict[str, int] = {}
    for vid, _, _, _ in vehicles:
        veh_counts[vid] = veh_counts.get(vid, 0) + 1
    print("  roster: " + ", ".join(f"{sid} {n}" for sid, n in roster)
          + ", " + ", ".join(f"{vid} {n}" for vid, n in veh_counts.items()))
    print(f"  front ranks: row {fronts[0]} vs row {fronts[1]} "
          f"({abs(fronts[0] - fronts[1])} rows apart, inset {a.inset})")


if __name__ == "__main__":
    main()
