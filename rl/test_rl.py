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


def test_memory_pressure_shrinks_the_rollout():
    """Over the budget, the trainer shrinks its rollout and keeps training; it only gives
    up when the base process alone leaves no room. town-8 exited every few updates and was
    restarted 28 times in a night on a limit it could simply have trained under."""
    import train as T
    t = T.Trainer.__new__(T.Trainer)
    t.cfg = dict(mem_limit_mb=4096, rollout_budget_mb=2048)
    t.rollout_budget_mb = 2048.0
    t.global_step, t.stop_reason = 0, ""
    t.writer = type("W", (), {"add_scalar": lambda *a, **k: None})()
    t.write_status = lambda *a, **k: None
    real = T.mem_report
    try:
        # 4300 MB in use against a 4096 limit, of which 1400 is the empty process.
        T.mem_report = lambda: {"total_mb": 4300.0}
        t._base_mb = 1400.0
        assert t.over_memory_budget() is False           # shrink, do not exit
        first = t.rollout_budget_mb
        assert first < 2048, first
        assert t.over_memory_budget() is False           # still room to shrink
        assert t.rollout_budget_mb < first
        for _ in range(20):                              # shrink to the floor, then stop
            if t.over_memory_budget():
                break
        assert t.rollout_budget_mb >= T.MIN_ROLLOUT_MB
        assert t.stop_reason == "memory"                 # the give-up is labelled
        # A base that fits with room to spare keeps training at the floor rather than exiting.
        t2 = T.Trainer.__new__(T.Trainer)
        t2.cfg, t2.rollout_budget_mb = dict(mem_limit_mb=4096, rollout_budget_mb=2048), 2048.0
        t2.global_step, t2.stop_reason, t2._base_mb = 0, "", 3990.0   # no headroom at all
        t2.writer, t2.write_status = t.writer, t.write_status
        assert t2.over_memory_budget() is True
        assert t2.stop_reason == "memory"
    finally:
        T.mem_report = real


def test_class_cache_staleness():
    """A pull that adds a class_name must trigger an import before Godot runs: without it
    the lobby failed to parse and "Play vs latest" opened a gray window. A current cache
    must not (an import on every launch would slow each env start)."""
    from mcf_env import refresh_class_cache
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, ".godot"))
    with open(os.path.join(d, "a.gd"), "w") as f:
        f.write("extends Node\nclass_name Foo\n")
    with open(os.path.join(d, ".godot", "global_script_class_cache.cfg"), "w") as f:
        f.write('list=[{\n"class": &"Foo",\n}]\n')
    assert refresh_class_cache("true", d) is False          # declared == cached
    with open(os.path.join(d, "b.gd"), "w") as f:
        f.write("class_name Bar extends RefCounted\n")
    assert refresh_class_cache("true", d) is True           # Bar is new -> import


def test_only_hard():
    """The owner's rule: RL trains and evaluates against HARD only. A config (or a branch's
    saved config.yaml) that still asks for NORMAL must lose the key, not honour it."""
    import yaml
    from mcf_env import HARD
    from train import Trainer, load_config
    d = tempfile.mkdtemp()
    path = os.path.join(d, "old.yaml")
    with open(path, "w") as f:
        yaml.safe_dump({"opponent": "normal", "eval_opponents": ["normal", "hard"], "phase": "A",
                        "maps": [os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                              "maps", "arena_34x26.json")]}, f)
    cfg = load_config(path)
    assert "opponent" not in cfg and "eval_opponents" not in cfg
    t = Trainer.__new__(Trainer)
    t.cfg, t.rng = cfg, __import__("random").Random(0)
    assert t.pick_opponent() == (HARD, "ai:hard")


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


def test_old_checkpoint_grows():
    """A checkpoint from before the tactical env (72 grid channels, no tactical/drone
    candidate columns, no residual trunk) still loads, optimizer state included, and
    scores every candidate exactly as it did: new inputs start at zero weight and the
    residual blocks start as the identity."""
    import torch
    import torch.nn as nn
    from features import CAND_DIM, CANVAS, FLAT_DIM, N_CHANNELS
    from model import PolicyNet, load_compat
    torch.manual_seed(0)
    old_ch, old_cand = 72, ft.F_COMPONENT - 9

    class OldNet(PolicyNet):
        """The network as it was: a narrower first conv and candidate layer, no trunk."""
        def __init__(self):
            super().__init__()
            self.conv[0] = nn.Conv2d(old_ch, self.fmap, 3, padding=1)
            first = self.cand[0]
            self.cand[0] = nn.Linear(first.in_features - (CAND_DIM - old_cand), first.out_features)
            del self.res
            self.res = nn.ModuleList()

    old = OldNet()
    opt_old = torch.optim.Adam(old.parameters(), lr=1e-3)
    grid = torch.rand(1, N_CHANNELS, CANVAS, CANVAS)
    flat = torch.rand(1, FLAT_DIM)
    cand = torch.rand(1, 4, CAND_DIM)
    cells = torch.zeros(1, 4, 2, dtype=torch.long)
    mask = torch.ones(1, 4, dtype=torch.bool)
    # one optimizer step so Adam has moments to grow
    d = old.cand[0].in_features - old_cand
    old_cand_in = torch.cat([cand[..., :old_cand]], dim=-1)
    loss = old(grid[:, :old_ch], flat, old_cand_in, cells, mask)[0].sum()
    loss.backward()
    opt_old.step()
    net = PolicyNet()
    opt = torch.optim.Adam(net.parameters(), lr=1e-3)
    load_compat(net, old.state_dict(), opt, opt_old.state_dict())
    g2 = grid.clone(); g2[:, old_ch:] = 0.0
    c2 = cand.clone(); c2[..., old_cand:] = 0.0
    with torch.no_grad():
        a = net(g2, flat, c2, cells, mask)
        b = old(grid[:, :old_ch], flat, cand[..., :old_cand], cells, mask)
    assert torch.allclose(a[0], b[0], atol=1e-5) and torch.allclose(a[1], b[1], atol=1e-5)
    # and it trains: a step through the grown optimizer runs and moves the trunk
    net(grid, flat, cand, cells, mask)[0].sum().backward()
    opt.step()
    assert any(p.abs().sum() > 0 for p in net.res[0][2].parameters())


def test_tactical_trainer_knobs():
    """League picks harder pool members more often, evaluation-only HARD is untouched,
    the per-action bonus decays from where the config was applied, map weights and
    generated maps are accepted."""
    import random
    import yaml
    from mcf_env import HARD
    from train import Trainer, load_config
    d = tempfile.mkdtemp()
    arena = os.path.join(os.path.dirname(os.path.abspath(__file__)), "maps", "arena_34x26.json")
    path = os.path.join(d, "t.yaml")
    with open(path, "w") as f:
        yaml.safe_dump({"maps": [arena, "gen:any:0:8:1"], "map_weights": [0, 1], "phase": "league",
                        "pool_ai_fraction": 0.0, "opponent_styles": [0, 0, 0, 1],
                        "shaping_decay_updates": 100, "shaping_floor": 0.2,
                        "shaping_decay_start": 50}, f)
    cfg = load_config(path)
    assert cfg["maps"][1] == "gen:any:0:8:1"
    t = Trainer.__new__(Trainer)
    t.cfg, t.rng, t.update = cfg, random.Random(0), 100
    t.pfsp = {"self": [100, 95], "strong": [100, 5]}
    t.pool_checkpoints = lambda: ["strong"]
    t.pool_net = lambda p: None
    picks = [t.pick_opponent()[1] for _ in range(400)]
    assert picks.count("pool:strong") > 3 * picks.count("pool:self"), picks.count("pool:strong")
    assert t.pick_style() == 3
    assert abs(t.shaping_scale() - 0.6) < 1e-9            # halfway from 1.0 to the 0.2 floor
    t.update = 1000
    assert t.shaping_scale() == 0.2
    assert {t.pick_map() for _ in range(50)} == {1}
    t.cfg = dict(cfg, phase="A")
    assert t.pick_opponent() == (HARD, "ai:hard")          # phase A is still HARD only


def test_tactical_features():
    """The tactical wire fields land in the new grid layers and candidate columns."""
    import numpy as np
    from features import (C_FCOVER, C_FNEXT, C_LASTSEEN, C_THREAT, CANVAS, F_PRED, F_TAC,
                          candidate_rows, grid_tensor)
    w, h = 4, 3
    z = [0] * (w * h)
    obs = {"w": w, "h": h, "floor": z, "feat": z, "feat_own": z, "cover": z, "fire": z,
           "corpse": z, "dirt": z, "fog": [2] * (w * h), "veh": z, "units": [], "vehicles": [],
           "threat": [0] * 5 + [12] + [0] * 6, "fcover": [24] + [0] * 11,
           "fnext": [0] * 11 + [6], "ereach": [4] * 12, "lastseen": [0, 50] + [0] * 10}
    g = grid_tensor(obs)
    ox, oy = (CANVAS - w) // 2, (CANVAS - h) // 2
    assert abs(g[C_THREAT, oy + 1, ox + 1] - 0.5) < 1e-6 and g[C_FCOVER, oy, ox] == 1.0
    assert abs(g[C_FNEXT, oy + 2, ox + 3] - 0.25) < 1e-6 and g[C_LASTSEEN, oy, ox + 1] == 0.5
    legal = [{"i": {"t": "move"}, "ax": 0, "ay": 0, "tx": 1, "ty": 1, "tt": -1, "at": 0,
              "th": 3.0, "fc": 6.0, "cv": 1.0, "apc": 2, "tn": 1.5, "er": 3}]
    rows, _ = candidate_rows(obs, legal)
    assert np.allclose(rows[0, F_TAC:F_TAC + 5], [0.5, 1.0, 0.5, 2 / 3, 1.0])
    assert np.allclose(rows[0, F_PRED:F_PRED + 2], [0.25, 0.5])


def test_round_cap_is_scored_on_value():
    """At the round cap the env scores army VALUE, not head count, and pays ±0.5 (a rout
    pays ±1). Owner's call 2026-10-03, after tactical-1 won a quarter of its head-count
    wins from behind on value. Needs Godot: one real arena episode with round_cap 1."""
    import shutil
    from mcf_env import HARD, EpisodeConfig, GodotEnv
    godot = os.environ.get("GODOT") or shutil.which("godot")
    if not godot:
        raise ImportError("no godot on PATH")
    env = GodotEnv(godot)
    try:
        r = env.reset(EpisodeConfig(map_path=os.path.join(os.path.dirname(__file__), "maps",
                                                          "arena_34x26.json"),
                                    seed=3, opponent=HARD, round_cap=1, max_steps=500))
        prev = r["info"]["value_diff"]
        while not r["done"]:
            prev = r["info"]["value_diff"]
            end = next(i for i, d in enumerate(r["legal"]) if d["i"].get("t") == "end")
            r = env.step(end)
    finally:
        env.close()
    info = r["info"]
    assert info["by"] == "value", info
    vd = info["value_diff"]
    assert info["result"] == ("win" if vd > 0 else "loss") or info["result"] == "draw_cap", info
    stake = {"win": 0.5, "loss": -0.5}.get(info["result"], -0.1)
    # the last reward = value differential of that step + the stake + one end-turn penalty
    assert abs(r["reward"] - (vd - prev) - stake) < 0.05, (r["reward"], vd, prev, stake)


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
