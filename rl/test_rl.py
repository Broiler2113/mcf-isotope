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


def _scores_unpacked(net, fm, s, cand, cells, mask):
    """The candidate head written the obvious way: every padded row, state copied in."""
    import torch
    B, N, _ = cand.shape
    flat_fm = fm.flatten(2).transpose(1, 2)
    idx = cells.clamp(min=0)
    a = torch.gather(flat_fm, 1, idx[..., 0:1].expand(B, N, net.fmap)) * (cells[..., 0:1] >= 0).float()
    t = torch.gather(flat_fm, 1, idx[..., 1:2].expand(B, N, net.fmap)) * (cells[..., 1:2] >= 0).float()
    x = torch.cat([cand, a, t, s.unsqueeze(1).expand(B, N, s.shape[1])], dim=2)
    return net.cand(x).squeeze(-1).masked_fill(~mask, -1e9)


def test_packed_head_is_the_same_function():
    """model.scores skips padding and hoists the state term; the logits and every
    gradient must match the unpacked head it replaced (same weights = old checkpoints)."""
    import torch
    from model import PolicyNet
    from train import Step, collate
    torch.manual_seed(0)
    rng = np.random.default_rng(0)
    steps = []
    for n_cand in (3, 40, 7):                          # ragged, like a real minibatch
        obs = fake_obs(ux=int(rng.integers(W)), uy=int(rng.integers(H)))
        legal = [dict(i=dict(t="move"), at=int(rng.integers(19)), tt=-1,
                      ax=int(rng.integers(W)), ay=int(rng.integers(H)),
                      tx=int(rng.integers(-1, W)), ty=int(rng.integers(H))) for _ in range(n_cand)]
        c, cl = candidate_rows(obs, legal)
        steps.append(Step(grid_tensor(obs), ft.flat_vector(obs), c, cl, 0, 0.0, 0.0))
    grid, flat, cand, cells, mask = collate(steps, "cpu")
    net = PolicyNet()
    grads = []
    for fn in (net.scores, lambda *a: _scores_unpacked(net, *a)):
        net.zero_grad()
        fm, s = net.embed(grid, flat)
        logits = fn(fm, s, cand, cells, mask)
        torch.log_softmax(logits, 1)[:, 0].sum().backward()
        grads.append((logits.detach(), [p.grad.clone() for p in net.parameters() if p.grad is not None]))
    (l1, g1), (l2, g2) = grads
    assert torch.allclose(l1[mask], l2[mask], atol=1e-5), (l1[mask] - l2[mask]).abs().max()
    assert (l1[~mask] == -1e9).all()
    assert len(g1) == len(g2) > 0
    for a, b in zip(g1, g2):
        assert torch.allclose(a, b, atol=1e-5, rtol=1e-4), (a - b).abs().max()


def test_device_self_check():
    """device: auto keeps a GPU only if it computes the policy net like the CPU; a backend
    that cannot must fall back, not raise."""
    from train import device_matches_cpu
    assert device_matches_cpu("cpu")
    assert not device_matches_cpu("meta")      # "runs" nothing: fails the comparison


def test_pool_cache_is_trimmed():
    from train import Trainer
    t = Trainer.__new__(Trainer)
    t.run_dir, t.cfg = "/nonexistent", dict(pool_size=2)
    t.pool_cache = {"self": 1, "/a/ckpt_1.pt": 1, "/a/ckpt_2.pt": 1}
    # A game still running against ckpt_2 keeps it, even though it left the pool (and its
    # file may already be pruned); ckpt_1 has no game left and goes.
    t.envs = type("V", (), dict(envs=[type("E", (), dict(label=l))() for l in
                                      ("pool:/a/ckpt_2.pt", "ai:normal", "pool:self")]))()
    t.trim_pool_cache()                                  # glob finds nothing -> pool empty
    assert sorted(t.pool_cache) == ["/a/ckpt_2.pt", "self"]


def test_env_read_times_out():
    import socket
    from mcf_env import EnvDied, GodotEnv
    ours, godot = socket.socketpair()
    env = GodotEnv.__new__(GodotEnv)
    env.buf, env.timeout, env.sock = bytearray(), 0.4, ours
    env.proc = type("P", (), dict(poll=lambda self: None))()
    env.kill = lambda: None
    godot.sendall(b'{"ok":true}\n{"ok":')                # one line, then a partial one
    assert env._readline() == b'{"ok":true}'
    t0 = time.monotonic()
    try:
        env._readline()                                  # writer never finishes the line
    except EnvDied:
        pass
    else:
        raise AssertionError("a silent env must raise EnvDied, not block forever")
    assert 0.3 < time.monotonic() - t0 < 5.0
    godot.close()
    try:
        env._readline()                                  # env gone: EOF is a death, not a hang
    except EnvDied:
        pass
    else:
        raise AssertionError("a closed socket must raise EnvDied")


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
