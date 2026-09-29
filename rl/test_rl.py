#!/usr/bin/env python
"""Self-check for the pieces that have no Godot in them: the grid <-> candidate-cell
contract, the sparse rollout storage, the packed candidate head, the env read timeout,
the device self-check and the pool cache.

    ~/.venvs/mcf-rl/bin/python rl/test_rl.py      # the system python has no numpy/torch
"""
from __future__ import annotations

import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np

import features as ft
from features import CANVAS, Sparse, candidate_rows, grid_tensor

W, H = 34, 26


def fake_obs(ux: int = 5, uy: int = 7) -> dict:
    z = [0] * (W * H)
    return dict(w=W, h=H, floor=list(z), feat=list(z), feat_own=list(z), cover=list(z),
                fire=list(z), corpse=list(z), dirt=list(z), fog=list(z), veh=list(z),
                units=[dict(x=ux, y=uy, own=0, type=3, ap=2, max_ap=4, held=0, corpses=0,
                            item=0, civ=0, pending=0, mc=0)],
                vehicles=[], round=1, round_cap=10, slot=0, slots=2, my_value=100.0,
                enemy_value=100.0, combat_started=0, fog_mode=1, side=0)


def legal_move(ax, ay, tx, ty, at=3):
    return dict(i=dict(t="move"), at=at, tt=-1, ax=ax, ay=ay, tx=tx, ty=ty)


def test_grid_and_cells_agree():
    """A candidate's cell index must point at the canvas square its unit is drawn on, or
    the policy gathers features for the wrong tile."""
    obs = fake_obs(ux=5, uy=7)
    _, cells = candidate_rows(obs, [legal_move(5, 7, 6, 7)])
    g = grid_tensor(obs)
    cy, cx = divmod(int(cells[0, 0]), CANVAS)
    assert g[ft.C_UNIT_TYPE + 3, cy, cx] == 1.0
    assert g[ft.C_VALID].sum() == W * H            # no padding claimed as playable


def test_sparse_roundtrip():
    g = grid_tensor(fake_obs())
    sp = Sparse(g)
    out = np.zeros_like(g)
    sp.dense(out)
    assert np.allclose(out, g, atol=1e-3)
    assert sp.nbytes * 20 < g.astype(np.float16).nbytes   # the reason it exists


def _steps(n_cands):
    from train import Step
    rng = np.random.default_rng(0)
    out = []
    for n in n_cands:
        obs = fake_obs(ux=int(rng.integers(W)), uy=int(rng.integers(H)))
        legal = [legal_move(int(rng.integers(W)), int(rng.integers(H)),
                            int(rng.integers(-1, W)), int(rng.integers(H)),
                            at=int(rng.integers(19))) for _ in range(n)]
        c, cl = candidate_rows(obs, legal)
        out.append(Step(Sparse(grid_tensor(obs)), ft.flat_vector(obs), Sparse(c),
                        cl.astype(np.int32), 0, 0.0, 0.0))
    return out


def test_collate_pads_candidates():
    from train import collate
    grid, flat, cand, cells, mask = collate(_steps([2, 5]), "cpu")
    assert tuple(grid.shape) == (2, ft.N_CHANNELS, CANVAS, CANVAS)
    assert tuple(cand.shape) == (2, 5, ft.CAND_DIM)
    assert mask[0].tolist() == [True, True, False, False, False] and mask[1].all()


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
    from train import collate
    torch.manual_seed(0)
    grid, flat, cand, cells, mask = collate(_steps([3, 40, 7]), "cpu")
    net = PolicyNet()
    got = []
    for fn in (net.scores, lambda *a: _scores_unpacked(net, *a)):
        net.zero_grad()
        fm, s = net.embed(grid, flat)
        logits = fn(fm, s, cand, cells, mask)
        torch.log_softmax(logits, 1)[:, 0].sum().backward()
        got.append((logits.detach(), [p.grad.clone() for p in net.parameters() if p.grad is not None]))
    (l1, g1), (l2, g2) = got
    assert torch.allclose(l1[mask], l2[mask], atol=1e-5), (l1[mask] - l2[mask]).abs().max()
    assert (l1[~mask] == -1e9).all()
    assert len(g1) == len(g2) > 0
    for a, b in zip(g1, g2):
        assert torch.allclose(a, b, atol=1e-5, rtol=1e-4), (a - b).abs().max()


def test_env_read_times_out():
    """A silent env raises EnvDied instead of blocking the trainer; so does a dead one."""
    import socket
    from mcf_env import EnvDied, GodotEnv
    ours, godot = socket.socketpair()
    env = GodotEnv.__new__(GodotEnv)
    env._buf, env.sock = b"", ours
    env.proc = type("P", (), dict(poll=lambda self: None, pid=0))()
    env.kill = lambda: None
    godot.sendall(b'{"ok":true}\n{"ok":')               # one line, then a partial one
    assert env._readline(time.monotonic() + 5) == b'{"ok":true}'
    t0 = time.monotonic()
    try:
        env._readline(time.monotonic() + 0.4)           # the line is never finished
    except EnvDied:
        pass
    else:
        raise AssertionError("a silent env must raise EnvDied, not block forever")
    assert time.monotonic() - t0 < 5.0
    godot.close()
    try:
        env._readline(time.monotonic() + 5)
    except EnvDied:
        pass
    else:
        raise AssertionError("a closed socket must raise EnvDied")


def test_device_self_check():
    """device: auto keeps a GPU only if it computes the policy net like the CPU; a backend
    that cannot must fall back, not raise."""
    from train import device_matches_cpu
    assert device_matches_cpu("cpu")
    assert not device_matches_cpu("meta")


def test_pool_keeps_a_running_games_opponent():
    """The cache holds pool_size + 1 nets, but never evicts one a running game still plays
    against — its checkpoint may already be pruned from disk."""
    from collections import OrderedDict
    import torch
    from model import PolicyNet
    from train import Trainer
    d = tempfile.mkdtemp()
    paths = []
    for k in range(4):
        paths.append(os.path.join(d, f"ckpt_{k}.pt"))
        torch.save({"model": PolicyNet().state_dict()}, paths[-1])
    t = Trainer.__new__(Trainer)
    t.cfg, t.pool_cache, t.act_net = dict(pool_size=1), OrderedDict(), PolicyNet()
    t.envs = type("V", (), dict(envs=[type("E", (), dict(label="pool:" + paths[0]))()]))()
    for p in paths:
        t.pool_net(p)
    assert paths[0] in t.pool_cache                     # its game is still running
    assert len(t.pool_cache) <= 3                       # bounded: pool + self + the live one
    os.remove(paths[0])
    t.pool_net(paths[0])                                # served from memory, no disk read


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
