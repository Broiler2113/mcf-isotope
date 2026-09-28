#!/usr/bin/env python
"""Self-check for the pieces that have no Godot in them: the cropped grid <-> canvas
contract, the batch padding, the pool cache, and the env read timeout.

    python rl/test_rl.py          # needs numpy; the collate check also needs torch
"""
from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np

import features as ft
from features import CANVAS, N_CHANNELS, candidate_rows, canvas_offset, grid_tensor

W, H = 34, 26


def fake_obs(ux: int = 5, uy: int = 7) -> dict:
    z = [0] * (W * H)
    return dict(w=W, h=H, floor=list(z), feat=list(z), feat_own=list(z), cover=list(z),
                fire=list(z), corpse=list(z), dirt=list(z), fog=list(z), veh=list(z),
                units=[dict(x=ux, y=uy, own=0, type=3, ap=2, max_ap=4, held=0, corpses=0,
                            item=0, civ=0, pending=0, mc=0)],
                vehicles=[], round=1, round_cap=10, slot=0, slots=2, my_value=100.0,
                enemy_value=100.0, combat_started=0, fog_mode=1, side=0)


def test_grid_is_cropped():
    g = grid_tensor(fake_obs())
    assert g.shape == (N_CHANNELS, H, W), g.shape
    assert g[ft.C_VALID].all()
    # 4.6x smaller than the padded canvas is the whole point of storing it this way.
    assert g.nbytes * 4 < np.zeros((N_CHANNELS, CANVAS, CANVAS), np.float32).nbytes


def test_grid_and_cells_agree():
    """The candidate's cell index must point at the same canvas square the unit is
    padded onto, or the policy gathers features for the wrong tile."""
    obs = fake_obs(ux=5, uy=7)
    legal = [dict(i=dict(t="move"), at=3, tt=-1, ax=5, ay=7, tx=6, ty=7)]
    _, cells = candidate_rows(obs, legal)
    ox, oy = canvas_offset(W, H)
    assert cells[0, 0] == (7 + oy) * CANVAS + (5 + ox)

    canvas = np.zeros((N_CHANNELS, CANVAS, CANVAS), np.float32)
    canvas[:, oy:oy + H, ox:ox + W] = grid_tensor(obs)
    cy, cx = divmod(int(cells[0, 0]), CANVAS)
    assert canvas[ft.C_UNIT_TYPE + 3, cy, cx] == 1.0
    assert canvas[ft.C_VALID].sum() == W * H          # no padding claimed as playable


def test_collate_pads_grid_and_candidates():
    from train import Step, collate
    obs = fake_obs()
    g = grid_tensor(obs).astype(np.float16)
    f = ft.flat_vector(obs)
    c2, cl2 = candidate_rows(obs, [dict(i=dict(t="end"), at=-1, tt=-1, ax=-1, ay=-1, tx=-1, ty=-1)] * 2)
    c5, cl5 = candidate_rows(obs, [dict(i=dict(t="end"), at=-1, tt=-1, ax=-1, ay=-1, tx=-1, ty=-1)] * 5)
    grid, flat, cand, cells, mask = collate(
        [Step(g, f, c2, cl2, 0, 0.0, 0.0), Step(g, f, c5, cl5, 0, 0.0, 0.0)], "cpu")
    assert tuple(grid.shape) == (2, N_CHANNELS, CANVAS, CANVAS)
    assert tuple(cand.shape) == (2, 5, ft.CAND_DIM)
    assert mask[0].tolist() == [True, True, False, False, False]
    assert mask[1].all()
    ox, oy = canvas_offset(W, H)
    assert grid[0, ft.C_VALID, oy, ox].item() == 1.0
    assert grid[0, ft.C_VALID, 0, 0].item() == 0.0      # the pad stays empty


def test_pool_cache_is_trimmed():
    from train import Trainer
    t = Trainer.__new__(Trainer)
    t.run_dir, t.cfg = "/nonexistent", dict(pool_size=2)
    t.pool_cache = {"self": 1, "/a/ckpt_1.pt": 1, "/a/ckpt_2.pt": 1}
    t.trim_pool_cache()                                  # glob finds nothing -> pool empty
    assert list(t.pool_cache) == ["self"]


def test_env_read_times_out():
    from mcf_env import EnvDied, GodotEnv
    r, w = os.pipe()
    env = GodotEnv.__new__(GodotEnv)
    env.buf, env.timeout, env.proc = bytearray(), 0.4, type(
        "P", (), dict(stdout=os.fdopen(r, "rb", 0), poll=lambda self: None,
                      pid=os.getpid()))()
    env.kill = lambda: None
    os.write(w, b'{"ok":true}\n{"ok":')                  # one line, then a partial one
    assert env._readline() == b'{"ok":true}'
    t0 = time.monotonic()
    try:
        env._readline()                                  # writer never finishes the line
    except EnvDied:
        pass
    else:
        raise AssertionError("a silent env must raise EnvDied, not block forever")
    assert 0.3 < time.monotonic() - t0 < 5.0
    os.close(w)


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            try:
                fn()
            except ImportError as e:
                print(f"skip {name}: {e}")
                continue
            print(f"ok   {name}")
    print("all checks passed")
