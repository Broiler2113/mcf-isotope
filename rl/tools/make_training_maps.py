#!/usr/bin/env python
"""Build the synthesised RL training maps: the drone map and the sapper map.

    python rl/tools/make_training_maps.py [--out-dir rl/maps]

Unlike rl/tools/make_town_map.py, which dresses the shipped maps/town.json in an army,
these two need terrain that does not exist anywhere in the project: the drone map needs
rooms and doorways to make enemies bunch up, and the sapper map needs walled compounds
with countable entrances. So the terrain is generated here, in the same schema the game
loads (width/height/is_space/feature_id/cover_height/floor_type/zone_owner/spawns).

WHY BOTH MAPS ARE MIRRORED, INCLUDING THE SAPPER ONE.

The sapper map was asked for as "the policy defends a compound against a larger
attacker". It is built symmetric instead — each side gets its own compound — and the
reason is in the trainer, not in taste. The policy does not have a fixed side: rollout
uses `side = episode_seed % 2` and evaluation uses `side = k % 2` (train.py 411, 656),
so it plays attacker and defender in alternating games. Meanwhile the score is
`value_diff = my army value - theirs` (env_server._value_diff).

Put those together on an asymmetric map and a 10-game evaluation becomes five games that
start well ahead and five that start well behind — a bimodal mixture whose mean is not a
measurement of anything. That is the same failure that the round_cap 12 -> 20 change
caused, and it cost this project two nights of misread evaluations. Mirrored compounds
keep the scoring symmetric while still creating what makes engineers and sappers worth
anything: ground worth holding, a small number of approaches worth mining, and time to
prepare before contact.

KNOWN RISK, stated rather than hidden: two symmetric compounds can both turtle, ending at
the round cap on head count with a differential near zero. That is a BETTER outcome than
the ~-0.19 the policy currently averages, so turtling is a real attractor here. Watch the
`by=` split on this map — if it goes overwhelmingly `count` with rounds pinned at the cap
and value_diff hugging zero, the map is teaching stalling, not fortifying, and the
compounds need to be moved closer or the cap shortened.
"""
from __future__ import annotations

import argparse
import json
import os

WALL = "wall"
WALL_H = 2.0
SANDBAGS = "sandbags"
TRENCH = "trench"
MAP_VERSION = 2


class Grid:
    """A blank board plus the few terrain edits these maps need."""

    def __init__(self, w: int, h: int) -> None:
        self.w, self.h = w, h
        n = w * h
        self.feature = [""] * n
        self.cover = [0.0] * n
        self.floor = [0] * n
        self.space = [0] * n

    def i(self, x: int, y: int) -> int:
        return y * self.w + x

    def inside(self, x: int, y: int) -> bool:
        return 0 <= x < self.w and 0 <= y < self.h

    def wall(self, x: int, y: int) -> None:
        if self.inside(x, y):
            self.feature[self.i(x, y)] = WALL
            self.cover[self.i(x, y)] = WALL_H

    def cover_at(self, x: int, y: int, feature: str, height: float) -> None:
        if self.inside(x, y) and self.feature[self.i(x, y)] == "":
            self.feature[self.i(x, y)] = feature
            self.cover[self.i(x, y)] = height

    def scatter_cover(self, x0: int, y0: int, x1: int, y1: int, every: int = 4) -> None:
        """Sprinkle sandbags and trench across an area.

        Not decoration. The first cut of these maps had walls and nothing else, and a
        do-nothing policy was wiped to value_diff -1.000 by round 6 — a third to an
        eighth of the steps the town map survives. Troops in bare rooms have nowhere to
        be except in the open, so every exchange is lethal and a match is over before it
        contains any decisions worth learning from.
        """
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if (x + y) % every == 0:
                    self.cover_at(x, y, SANDBAGS, 1.0)
                elif (x * 3 + y) % (every * 3) == 0:
                    self.cover_at(x, y, TRENCH, 0.0)

    def clear(self, x: int, y: int) -> None:
        if self.inside(x, y):
            self.feature[self.i(x, y)] = ""
            self.cover[self.i(x, y)] = 0.0

    def free(self, x: int, y: int) -> bool:
        return self.inside(x, y) and self.feature[self.i(x, y)] == ""

    def border(self) -> None:
        for x in range(self.w):
            self.wall(x, 0)
            self.wall(x, self.h - 1)
        for y in range(self.h):
            self.wall(0, y)
            self.wall(self.w - 1, y)

    def rect(self, x0: int, y0: int, x1: int, y1: int) -> None:
        """Hollow rectangle of wall."""
        for x in range(x0, x1 + 1):
            self.wall(x, y0)
            self.wall(x, y1)
        for y in range(y0, y1 + 1):
            self.wall(x0, y)
            self.wall(x1, y)

    def to_map(self, spawns: list[dict]) -> dict:
        return {
            "version": MAP_VERSION, "width": self.w, "height": self.h,
            "feature_id": self.feature, "cover_height": self.cover,
            "floor_type": self.floor, "is_space": self.space,
            "zone_owner": [-1] * (self.w * self.h), "spawns": spawns,
        }


def fill_block(g: Grid, x0: int, y0: int, x1: int, y1: int, owner: int,
               queue: list[str], spawns: list[dict], clump: int = 3) -> None:
    """Lay units out in small clumps with gaps between them.

    `clump` cells of troops, then a gap. Solid shoulder-to-shoulder packing was the first
    attempt and it was far too lethal: one burst or blast caught a whole rank, and a
    do-nothing policy lost its entire army by round 6 (value_diff -1.000) instead of the
    -0.78 the town map gives it. Clumps keep what the drone map actually needs — several
    bodies close enough for one detonation to pay its combo multiplier — without making
    the entire army one target.
    """
    taken = {(s["x"], s["y"]) for s in spawns}
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if not queue:
                return
            if (x // clump + y) % 2 == 1:      # every other clump-column left empty
                continue
            if not g.free(x, y) or (x, y) in taken:
                continue
            taken.add((x, y))
            spawns.append({"stats_id": queue.pop(0), "owner": owner, "x": x, "y": y})


def roster(pairs: list[tuple[str, int]]) -> list[str]:
    return [sid for sid, n in pairs for _ in range(n)]


# --- drone map ---------------------------------------------------------------------
#
# Rooms and doorways, so that an advancing force is funnelled and arrives clumped. Nine
# rooms in a 3x3 arrangement; each interior wall carries a two-cell doorway, so there is
# always a way through but never a broad front.
DRONE_ROSTER = [("drone_operator", 8), ("light_infantry", 22),
                ("heavy_infantry", 8), ("machinegunner", 4), ("shield_bearer", 3)]


def drone_map(w: int = 44, h: int = 44) -> dict:
    g = Grid(w, h)
    g.border()
    xs = [0, w // 3, 2 * w // 3, w - 1]
    ys = [0, h // 3, 2 * h // 3, h - 1]
    for x in xs[1:-1]:
        for y in range(1, h - 1):
            g.wall(x, y)
    for y in ys[1:-1]:
        for x in range(1, w - 1):
            g.wall(x, y)
    # Doorways: two cells per interior wall segment, centred on each room's span.
    for x in xs[1:-1]:
        for a, b in zip(ys, ys[1:]):
            mid = (a + b) // 2
            g.clear(x, mid)
            g.clear(x, mid + 1)
    for y in ys[1:-1]:
        for a, b in zip(xs, xs[1:]):
            mid = (a + b) // 2
            g.clear(mid, y)
            g.clear(mid + 1, y)

    g.scatter_cover(1, 1, w - 2, h - 2)
    spawns: list[dict] = []
    # Owner 0 packs the bottom row of rooms, owner 1 the top row — a full room-width
    # apart, so contact happens in the doorways rather than at spawn.
    fill_block(g, 2, h - 12, w - 3, h - 3, 0, roster(DRONE_ROSTER), spawns)
    fill_block(g, 2, 2, w - 3, 11, 1, roster(DRONE_ROSTER), spawns)
    return g.to_map(spawns)


# --- sapper map --------------------------------------------------------------------
#
# Two mirrored compounds with three entrances each and open ground between them. The
# entrances are what make engineers and sappers worth their cost: three cells to mine and
# three cells to fortify, instead of a forty-cell front nobody can prepare.
SAPPER_ROSTER = [("engineer", 8), ("sapper", 7), ("light_infantry", 20),
                 ("heavy_infantry", 7), ("machinegunner", 4), ("shield_bearer", 3)]
SAPPER_GATES = 3


def _compound(g: Grid, x0: int, y0: int, x1: int, y1: int, gate_side: str) -> None:
    g.rect(x0, y0, x1, y1)
    span = x1 - x0
    gate_y = y0 if gate_side == "top" else y1
    for k in range(1, SAPPER_GATES + 1):
        gx = x0 + span * k // (SAPPER_GATES + 1)
        g.clear(gx, gate_y)
        g.clear(gx + 1, gate_y)


def sapper_map(w: int = 44, h: int = 44) -> dict:
    g = Grid(w, h)
    g.border()
    # Compounds hug their own edge; the gates face the middle, so the only way at an
    # enemy is through ground the defender had time to prepare.
    _compound(g, 4, h - 13, w - 5, h - 4, "top")
    _compound(g, 4, 3, w - 5, 12, "bottom")
    # Cover inside the compounds AND across the open middle: the approach has to be
    # survivable enough to be worth mining, or nobody ever crosses it.
    g.scatter_cover(1, 1, w - 2, h - 2)
    spawns: list[dict] = []
    fill_block(g, 5, h - 12, w - 6, h - 5, 0, roster(SAPPER_ROSTER), spawns)
    fill_block(g, 5, 4, w - 6, 11, 1, roster(SAPPER_ROSTER), spawns)
    return g.to_map(spawns)


def check(m: dict, name: str, want_per_side: int) -> None:
    """Refuse to write a map that cannot do its job."""
    problems = []
    counts = {0: 0, 1: 0}
    for s in m["spawns"]:
        counts[s["owner"]] = counts.get(s["owner"], 0) + 1
    for owner, n in counts.items():
        if n != want_per_side:
            problems.append(f"owner {owner} got {n} units, expected {want_per_side}")
    if counts.get(0) != counts.get(1):
        problems.append("the two sides are not mirrored")
    seen = set()
    for s in m["spawns"]:
        xy = (s["x"], s["y"])
        if xy in seen:
            problems.append(f"two units share {xy}")
        seen.add(xy)
        if m["feature_id"][s["y"] * m["width"] + s["x"]] != "":
            problems.append(f"unit standing inside terrain at {xy}")
    if problems:
        raise SystemExit(f"{name}: " + "; ".join(problems[:6]))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out-dir", default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "maps"))
    a = p.parse_args()
    os.makedirs(a.out_dir, exist_ok=True)

    for name, builder, per_side in (
            ("drone_44x44", drone_map, sum(n for _, n in DRONE_ROSTER)),
            ("sapper_44x44", sapper_map, sum(n for _, n in SAPPER_ROSTER))):
        m = builder()
        check(m, name, per_side)
        path = os.path.join(a.out_dir, f"{name}.json")
        with open(path, "w") as f:
            json.dump(m, f, indent="\t")
        walls = sum(1 for v in m["feature_id"] if v)
        print(f"{path}: {m['width']}x{m['height']}, {per_side} per side, "
              f"{len(m['spawns'])} spawns, {walls} wall cells")


if __name__ == "__main__":
    main()
