"""Observation and candidate featurisation (spec Section 3, 4).

The env server ships a fog-limited observation (rl/ObsEncoder.gd) as dense per-tile
arrays plus entity lists; this module turns it into the fixed 64x64xC grid tensor, the
flat feature vector, and one feature row per legal intent (the candidate the policy
scores). Every index below is fixed: changing the layout means retraining.
"""
from __future__ import annotations

import numpy as np

CANVAS = 64  # spec 3.1 / Q2: pad every pool map to 64x64, mask the rest

N_FEATURES = 20
N_UNIT_TYPES = 16
N_VEH_TYPES = 3
N_ACTOR_TYPES = N_UNIT_TYPES + N_VEH_TYPES

# --- grid channel layout -------------------------------------------------------------
C_VALID = 0
C_FLOOR = 1            # 3: normal, flammable, grass
C_SPACE = 4
C_FEAT = 5             # 20 one-hot
C_FEAT_OWN = 25        # 3: friendly, enemy, neutral
C_COVER = 28
C_FIRE = 29
C_CORPSE = 30
C_DIRT = 31
C_FOG = 32             # 3: never seen, seen before, visible
C_VEH_FOOT = 35
C_UNIT_OWN = 36        # 3
C_UNIT_TYPE = 39       # 16
C_UNIT_AP = 55
C_UNIT_HELD = 56
C_UNIT_CORPSES = 57
C_UNIT_ITEM = 58
C_UNIT_CIV = 59
C_UNIT_PENDING = 60
C_UNIT_MC = 61
C_VEH_OWN = 62         # 3
C_VEH_TYPE = 65        # 3
C_VEH_HULL = 68
C_VEH_FX = 69
C_VEH_FY = 70
C_VEH_WRECK = 71
N_CHANNELS = 72

FLAT_DIM = 20

INTENT_KINDS = [
    "end", "move", "shoot", "capture", "release", "move_held", "item", "push",
    "spawn_drone", "drone_move", "drone_det", "build", "break", "drag", "rsp", "dig",
    "gmove", "mine", "sweep", "disarm", "build_wall", "corpse_up", "cancel_shot",
    "station_up", "corpse_down", "veh_board", "veh_out", "veh_seat", "veh_turn",
    "veh_move", "veh_cannon", "veh_melee", "veh_repair", "veh_unload", "weld",
    "undo", "redo",
]
KIND_INDEX = {k: i for i, k in enumerate(INTENT_KINDS)}
N_KINDS = len(INTENT_KINDS)

BUILD_FEATURES = ["sandbags", "wall", "glass", "airlock", "bru", "rsp", "hedgehog", "dot", "dot_open"]

# candidate feature layout
F_KIND = 0
F_ACTOR_TYPE = F_KIND + N_KINDS            # 19
F_GEOM = F_ACTOR_TYPE + N_ACTOR_TYPES      # ax, ay, tx, ty, dx, dy, dist, has_target
F_TARGET_TYPE = F_GEOM + 8                 # 16
F_MISC = F_TARGET_TYPE + N_UNIT_TYPES      # shots_full, shots_single, av_mine, seat, steps, build_feature(9), comp(0)
CAND_DIM = F_MISC + 5 + len(BUILD_FEATURES)


def grid_tensor(obs: dict) -> np.ndarray:
    w, h = obs["w"], obs["h"]
    g = np.zeros((N_CHANNELS, CANVAS, CANVAS), dtype=np.float32)
    ox = (CANVAS - w) // 2
    oy = (CANVAS - h) // 2
    def plane(key):
        return np.asarray(obs[key], dtype=np.int32).reshape(h, w)
    floor = plane("floor"); feat = plane("feat"); fown = plane("feat_own")
    cover = plane("cover"); fire = plane("fire"); corpse = plane("corpse")
    dirt = plane("dirt"); fog = plane("fog"); veh = plane("veh")
    sl = (slice(oy, oy + h), slice(ox, ox + w))
    g[C_VALID][sl] = 1.0
    for k in range(3):
        g[C_FLOOR + k][sl] = (floor == k + 1)
    g[C_SPACE][sl] = (floor == 3)
    for k in range(N_FEATURES):
        g[C_FEAT + k][sl] = (feat == k + 1)
    for k in range(3):
        g[C_FEAT_OWN + k][sl] = (fown == k + 1)
        g[C_FOG + k][sl] = (fog == k)
    g[C_COVER][sl] = cover / 4.0
    g[C_FIRE][sl] = fire
    g[C_CORPSE][sl] = corpse / 5.0
    g[C_DIRT][sl] = dirt / 2.0
    g[C_VEH_FOOT][sl] = veh
    for u in obs["units"]:
        x, y = u["x"], u["y"]
        if x < 0 or y < 0 or x >= w or y >= h:
            continue  # tank crew parked off-board
        cx, cy = x + ox, y + oy
        g[C_UNIT_OWN + u["own"], cy, cx] = 1.0
        g[C_UNIT_TYPE + u["type"], cy, cx] = 1.0
        g[C_UNIT_AP, cy, cx] = u["ap"] / max(1, u["max_ap"])
        g[C_UNIT_HELD, cy, cx] = u["held"]
        g[C_UNIT_CORPSES, cy, cx] = u["corpses"]
        g[C_UNIT_ITEM, cy, cx] = 1.0 if u["item"] else 0.0
        g[C_UNIT_CIV, cy, cx] = u["civ"]
        g[C_UNIT_PENDING, cy, cx] = u.get("pending", 0) / 8.0
        g[C_UNIT_MC, cy, cx] = min(u["mc"], 16) / 16.0
    for v in obs["vehicles"]:
        hull = v["comps"].get("hull", [1, 1])
        frac = hull[0] / max(1, hull[1])
        for dy in range(v["h"]):
            for dx in range(v["w"]):
                x, y = v["x"] + dx, v["y"] + dy
                if 0 <= x < w and 0 <= y < h:
                    cx, cy = x + ox, y + oy
                    g[C_VEH_OWN + v["own"], cy, cx] = 1.0
                    g[C_VEH_TYPE + v["type"], cy, cx] = 1.0
                    g[C_VEH_HULL, cy, cx] = frac
                    g[C_VEH_FX, cy, cx] = v["fx"]
                    g[C_VEH_FY, cy, cx] = v["fy"]
                    g[C_VEH_WRECK, cy, cx] = v["wrecked"]
    return g


def flat_vector(obs: dict) -> np.ndarray:
    f = np.zeros(FLAT_DIM, dtype=np.float32)
    cap = max(1, obs["round_cap"])
    f[0] = obs["round"] / cap
    f[1] = cap / 20.0
    f[2] = obs["slot"] / max(1, obs["slots"])
    f[3] = obs["my_value"] / 5000.0
    f[4] = obs["enemy_value"] / 5000.0
    tot = obs["my_value"] + obs["enemy_value"]
    f[5] = (obs["my_value"] - obs["enemy_value"]) / tot if tot > 0 else 0.0
    f[6] = obs["combat_started"]
    f[7 + int(obs["fog_mode"])] = 1.0
    own = [u for u in obs["units"] if u["own"] == 0]
    f[10] = len(own) / 20.0
    f[11] = sum(1 for u in obs["units"] if u["own"] == 1) / 20.0
    f[12] = sum(1 for u in obs["units"] if u["own"] == 2) / 20.0
    f[13] = sum(u["ap"] for u in own) / 40.0
    f[14] = sum(1 for v in obs["vehicles"] if v["own"] == 0) / 4.0
    f[15] = sum(1 for v in obs["vehicles"] if v["own"] == 1) / 4.0
    f[16] = obs["side"]
    f[17] = obs["w"] / CANVAS
    f[18] = obs["h"] / CANVAS
    f[19] = 1.0
    return f


def candidate_rows(obs: dict, legal: list[dict]) -> tuple[np.ndarray, np.ndarray]:
    """Per-candidate feature rows plus the canvas cell index of actor and target
    (for gathering the CNN feature map; -1 when off-board)."""
    w, h = obs["w"], obs["h"]
    ox = (CANVAS - w) // 2
    oy = (CANVAS - h) // 2
    n = len(legal)
    rows = np.zeros((n, CAND_DIM), dtype=np.float32)
    cells = np.full((n, 2), -1, dtype=np.int64)
    for i, c in enumerate(legal):
        wire = c["i"]
        k = KIND_INDEX.get(wire.get("t", ""), 0)
        rows[i, F_KIND + k] = 1.0
        at = c.get("at", -1)
        if at is not None and at >= 0:
            rows[i, F_ACTOR_TYPE + at] = 1.0
        ax, ay, tx, ty = c["ax"], c["ay"], c["tx"], c["ty"]
        g = F_GEOM
        if ax >= 0:
            rows[i, g] = ax / w; rows[i, g + 1] = ay / h
            cells[i, 0] = (ay + oy) * CANVAS + (ax + ox)
        if tx >= 0:
            rows[i, g + 2] = tx / w; rows[i, g + 3] = ty / h
            rows[i, g + 7] = 1.0
            cells[i, 1] = (ty + oy) * CANVAS + (tx + ox)
            if ax >= 0:
                dx, dy = tx - ax, ty - ay
                rows[i, g + 4] = dx / 32.0; rows[i, g + 5] = dy / 32.0
                rows[i, g + 6] = max(abs(dx), abs(dy)) / 32.0
        tt = c.get("tt", -1)
        if tt is not None and tt >= 0:
            rows[i, F_TARGET_TYPE + tt] = 1.0
        m = F_MISC
        s = wire.get("s", None)
        if wire.get("t") in ("shoot", "rsp"):
            rows[i, m] = 1.0 if s == -1 else 0.0
            rows[i, m + 1] = 1.0 if s == 1 else 0.0
        elif s is not None:
            rows[i, m + 3] = float(s) / 16.0     # seat index / vehicle steps
        rows[i, m + 2] = float(wire.get("av", 0))
        rows[i, m + 4] = 1.0 if wire.get("cm", "") else 0.0
        fid = wire.get("f", "")
        if fid in BUILD_FEATURES:
            rows[i, m + 5 + BUILD_FEATURES.index(fid)] = 1.0
    return rows, cells
