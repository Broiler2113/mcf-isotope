"""Regression checks for rollout accounting, checkpoint migration and live serving.

Run with the RL venv: python rl/test_training_fixes.py
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from collections import OrderedDict
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np
import torch

import features as ft
import train
from mcf_env import EpisodeConfig, EXTERNAL, GodotEnv, PROJECT
from model import PolicyNet
from test_rl import fake_obs, legal_move


def wide_obs(w=74, h=62):
    obs = fake_obs()
    for key in ("floor", "feat", "feat_own", "cover", "fire", "corpse", "dirt", "fog", "veh"):
        obs[key] = [0] * (w * h)
    obs.update(w=w, h=h)
    return obs


class FixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(1)

    def test_opponent_tail_survives_rollout_and_memory_boundary(self):
        class Env:
            def __init__(self):
                self.cfg = SimpleNamespace(side=0, map_path="toy.json", record=False)
                self.label, self.position = "pool:self", 0
                self.last = self.response(0, 0)

            def response(self, acting, reward):
                return dict(acting=acting, reward=reward, done=False,
                            legal=[dict(i=dict(t="move"), at=0)],
                            info=dict(legal_ms=0, round=1, action_ok=True))

            def send(self, _cmd):
                pass

            def recv(self):
                acting, reward = [(1, 0), (1, -1), (0, -2)][self.position % 3]
                self.position += 1
                return self.response(acting, reward)

        for budget in (float("inf"), 0.000001):
            env = Env()
            t = train.Trainer.__new__(train.Trainer)
            t.cfg = train.with_defaults(dict(rollout_steps=1, n_envs=1, maps=["toy.json"]))
            t.envs = SimpleNamespace(envs=[env], wait_any=lambda ids: list(ids))
            t.act_threads, t.act_net = 1, None
            t.rollout_budget_mb, t.pool_cache = budget, OrderedDict()
            t._last_status = time.time()
            t.pool_net = lambda path: None
            t.write_status = lambda *a, **kw: None
            enc = tuple(np.zeros(1, dtype=np.float32) for _ in range(4))
            with patch.object(train, "encode", return_value=enc), patch.object(
                    train, "choose", side_effect=lambda net, states, dev: (
                        np.zeros(len(states), dtype=int), np.zeros(len(states)), np.ones(len(states)))):
                for _ in range(2):
                    buffers, info = t.collect()
                    self.assertEqual(len(buffers[0]), 1)
                    self.assertEqual(buffers[0][0].reward, -3)
                    self.assertEqual(env.last["acting"], 0)
                    self.assertEqual(info["accepted"]["toy.json"]["move"], 1)
            self.assertEqual(env.position, 6)

    def test_self_pool_is_frozen_once_per_rollout(self):
        t = train.Trainer.__new__(train.Trainer)
        t.act_net, t.pool_cache = PolicyNet(), OrderedDict()
        first = t.pool_net("self")
        self.assertIs(first, t.pool_net("self"))
        self.assertIsNot(first, t.act_net)
        t.pool_cache.pop("self")
        self.assertIsNot(first, t.pool_net("self"))

    def test_evaluations_repeat_seed_pairs_on_both_sides(self):
        class Env:
            last = None

            def send(self, cmd):
                self.cmd = cmd

            def recv(self):
                return dict(done=True, info=dict(result="win", by="value", round=2,
                            value_diff=.2, steps=3, illegal=0))

        with tempfile.TemporaryDirectory() as d:
            t = train.Trainer(d, train.with_defaults(dict(maps=["one", "two"], n_envs=2)))
            t.envs = SimpleNamespace(envs=[Env(), Env()], wait_any=lambda ids: list(ids))
            t.write_status = lambda *a, **kw: None
            t._last_status = time.time()
            try:
                for update in (25, 50):
                    t.update = update
                    result = t.evaluate(8)
                    self.assertEqual(result["value_winrate"], 1)
                    self.assertEqual(result["rout_winrate"], 0)
                with open(os.path.join(d, "eval_games.jsonl")) as f:
                    rows = [json.loads(line) for line in f]
                first, second = rows[:8], rows[8:]
                keys = lambda batch: [(r["map"], r["seed"], r["side"]) for r in batch]
                self.assertEqual(keys(first), keys(second))
                for a, b in zip(first[::2], first[1::2]):
                    self.assertEqual((a["map"], a["seed"]), (b["map"], b["seed"]))
                    self.assertEqual((a["side"], b["side"]), (0, 1))
                t.evaluate(2, suite="nofog")
                with open(os.path.join(d, "eval_games.jsonl")) as f:
                    self.assertEqual(len(f.readlines()), 16)
                self.assertTrue(os.path.exists(os.path.join(d, "eval_nofog_games.jsonl")))
            finally:
                t.writer.close()

    def test_full_suite_cadence_and_champion(self):
        with tempfile.TemporaryDirectory() as d:
            t = train.Trainer(d, train.with_defaults(dict(
                eval_full_every=100, eval_games=10, eval_nofog_games=4,
                drill_eval_maps=["drill"], drill_eval_games=4,
                heldout_eval_maps=["heldout"], heldout_eval_games=4)))
            result = dict(games=10, winrate=.6, lossrate=.3, drawrate=.1,
                          value_diff=.2, rounds=20, stallrate=0, rout_winrate=.1,
                          value_winrate=.5, illegal=0, outcomes={}, by_map={"drill": .5})
            t.has_eval_history = lambda: True
            try:
                with patch.object(t, "evaluate", return_value=result) as evaluate:
                    t.update = 25
                    t.run_eval()
                    self.assertEqual(evaluate.call_count, 1)
                    self.assertFalse(t.last_eval["full_suite"])
                    self.assertTrue(any("champion_" in p for p in os.listdir(d)))
                    evaluate.reset_mock()
                    t.update = 100
                    t.run_eval()
                    self.assertEqual(evaluate.call_count, 4)
                    self.assertTrue(t.last_eval["full_suite"])
                    call = evaluate.call_args_list[-1]
                    self.assertEqual(call.kwargs["round_cap"], 40)
                    self.assertEqual(call.kwargs["maps"], ["heldout", "heldout"])
            finally:
                t.writer.close()

    def test_component_features_and_condition(self):
        obs = fake_obs()
        obs["vehicles"] = [dict(id=9, x=6, y=7, w=3, h=3, own=0, type=0,
                                fx=1, fy=0, wrecked=0, crew=2, cap=3, ap=2,
                                comps=dict(hull=[4, 8], tracks_l=[0, 4], gun=[1, 4]))]
        legal = [dict(i=dict(t="veh_repair", a=1, v=9, cm=comp),
                      ax=5, ay=7, tx=6, ty=7, at=5, tt=-1) for comp in ("hull", "tracks_l", "gun")]
        rows, cells = ft.candidate_rows(obs, legal)
        self.assertFalse(np.array_equal(rows[0], rows[1]))
        np.testing.assert_allclose(rows[:, ft.F_COMPONENT_HEALTH], [.5, 0, .25])
        g = ft.grid_tensor(obs)
        y, x = divmod(int(cells[0, 1]), ft.CANVAS)
        j = ft.VEH_COMPONENTS.index("tracks_l")
        self.assertEqual(g[ft.C_VEH_COMPONENT + j, y, x], 0)
        self.assertEqual(g[ft.C_VEH_COMPONENT + len(ft.VEH_COMPONENTS) + j, y, x], 1)

    def test_recent_checkpoint_and_adam_expand_without_changing_outputs(self):
        from model import load_compat
        old = PolicyNet()
        old.conv[0] = torch.nn.Conv2d(78, old.fmap, 3, padding=1)
        old.cand[0] = torch.nn.Linear(ft.F_COMPONENT + 2 * old.fmap + 256, 256)
        opt_old = torch.optim.Adam(old.parameters(), lr=1e-4)
        grid = torch.rand(1, ft.N_CHANNELS, 64, 64)
        flat = torch.rand(1, ft.FLAT_DIM)
        candidates = torch.rand(1, 3, ft.CAND_DIM)
        candidates[:, :, ft.F_VEH_CRUSH:] = 0  # no visible vehicle lane in old observations
        cells = torch.zeros(1, 3, 2, dtype=torch.long)
        mask = torch.ones(1, 3, dtype=torch.bool)
        args_old = (grid[:, :78], flat, candidates[:, :, :ft.F_COMPONENT], cells, mask)
        logits, values = old(*args_old)
        (logits.sum() + values.sum()).backward()
        opt_old.step()
        net = PolicyNet()
        opt = torch.optim.Adam(net.parameters(), lr=1e-4)
        load_compat(net, old.state_dict(), opt, opt_old.state_dict())
        with torch.no_grad():
            actual = net(grid, flat, candidates, cells, mask)
            expected = old(*args_old)
        for a, b in zip(actual, expected):
            torch.testing.assert_close(a, b, atol=1e-5, rtol=1e-4)
        logits, values = net(grid, flat, candidates, cells, mask)
        (logits.sum() + values.sum()).backward()
        opt.step()

    def test_large_live_board_preserves_all_cells(self):
        from policy_server import answer
        obs = wide_obs()
        obs["units"][0].update(x=72, y=60)
        legal = [legal_move(72, 60, 73, 60)]
        with self.assertRaisesRegex(ValueError, "exceeds policy canvas"):
            ft.grid_tensor(obs)
        grid = ft.grid_tensor(obs, 74)
        _, cells = ft.candidate_rows(obs, legal, 74)
        y, x = divmod(int(cells[0, 0]), 74)
        self.assertEqual(grid[ft.C_UNIT_TYPE + 3, y, x], 1)
        self.assertEqual(grid[ft.C_VALID].sum(), 74 * 62)
        self.assertEqual(answer(PolicyNet().eval(), dict(obs=obs, legal=legal))["action"], 0)

    def test_policy_socket_survives_error_and_large_board(self):
        # Real process and TCP framing: the former failure silently closed this socket.
        with tempfile.TemporaryDirectory() as d:
            ck = os.path.join(d, "model.pt")
            torch.save(dict(model=PolicyNet().state_dict()), ck)
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            with open(os.path.join(d, "server.log"), "w") as log:
                proc = subprocess.Popen([sys.executable, os.path.join(PROJECT, "rl", "policy_server.py"),
                                         ck, "--port", str(port)], stdout=log, stderr=log)
                try:
                    until = time.monotonic() + 30
                    while True:
                        try:
                            conn = socket.create_connection(("127.0.0.1", port), timeout=10)
                            break
                        except OSError:
                            if proc.poll() is not None or time.monotonic() > until:
                                self.fail("policy server did not start")
                            time.sleep(.05)
                    with conn, conn.makefile("rwb") as f:
                        requests = [{"cmd": "ping"}, {"obs": {}, "legal": []},
                                    dict(obs=wide_obs(), legal=[legal_move(5, 7, 6, 7)]),
                                    dict(obs=fake_obs(), legal=[legal_move(5, 7, 6, 7)])]
                        for i, req in enumerate(requests):
                            f.write((json.dumps(req) + "\n").encode()); f.flush()
                            reply = json.loads(f.readline())
                            if i == 0:
                                self.assertTrue(reply["ok"])
                            elif i == 1:
                                self.assertIn("error", reply)
                            else:
                                self.assertEqual(reply["action"], 0)
                    game = subprocess.run([
                        "godot", "--headless", "--path", PROJECT,
                        "--script", "res://tests/run_learned_large_map.gd"],
                        env=dict(os.environ, MCF_RL_POLICY=f"127.0.0.1:{port}",
                                 MCF_RL_MAX_ACTORS="4", MCF_RL_MAX_CANDIDATES="32"),
                        capture_output=True, text=True, timeout=60)
                    self.assertEqual(game.returncode, 0, game.stdout + game.stderr)
                    self.assertIn("4 accepted policy decisions, no fallback", game.stdout)
                finally:
                    proc.terminate()
                    proc.wait(timeout=10)

    def test_milestones_cross_intervals_and_pool_retains_history(self):
        with tempfile.TemporaryDirectory() as d:
            t = train.Trainer.__new__(train.Trainer)
            t.run_dir = d
            t.cfg = train.with_defaults(dict(keep_checkpoints=2, pool_size=1,
                                            milestone_every=100, pool_archive_size=2))
            for step in (96, 112, 144, 208, 240, 304, 336, 368):
                open(os.path.join(d, f"ckpt_{step:09d}.pt"), "w").close()
            t.prune()
            paths = sorted(os.path.basename(p) for p in t.pool_checkpoints())
            self.assertEqual(paths, ["ckpt_000000112.pt", "ckpt_000000336.pt", "ckpt_000000368.pt"])
            self.assertTrue(os.path.exists(os.path.join(d, "ckpt_000000208.pt")))
            self.assertTrue(os.path.exists(os.path.join(d, "ckpt_000000304.pt")))

    def test_discounted_shaping_uses_learner_boundary(self):
        fixture = tempfile.TemporaryDirectory()
        with open(os.path.join(PROJECT, "rl/maps/arena_34x26.json")) as f:
            board = json.load(f)
        n = board["width"] * board["height"]
        board.update(cover_height=[0] * n, feature_id=[""] * n, is_space=[False] * n,
                     floor_type=[0] * n,
                     spawns=[dict(owner=0, stats_id="machinegunner", x=5, y=8),
                             dict(owner=1, stats_id="light_infantry", x=12, y=8)])
        path = os.path.join(fixture.name, "asymmetric_fire.json")
        with open(path, "w") as f:
            json.dump(board, f)
        env = GodotEnv()
        try:
            config = EpisodeConfig(map_path=path, fog=0,
                                   seed=7, side=0, opponent=EXTERNAL, round_cap=2,
                                   max_steps=100, max_actors=4, max_candidates=64,
                                   potential_coef=.5, gamma=.91)
            r = env.reset(config)
            self.assertGreater(abs(r["info"]["potential"]), .01)
            pending = None
            transitions = 0
            nonzero_rewards = 0
            shaped = []
            for _ in range(100):
                if r["done"]:
                    break
                if r["acting"] == 0:
                    pending = r["info"]["potential"]
                end = next(i for i, c in enumerate(r["legal"]) if c["i"]["t"] == "end")
                r = env.step(end)
                shaped.append((r["reward"], r["info"]["potential_reward"]))
                if pending is not None and (r["done"] or r["acting"] == 0):
                    self.assertAlmostEqual(r["info"]["potential_reward"],
                                           .5 * (.91 * r["info"]["potential"] - pending), places=6)
                    pending = None
                    transitions += 1
                    nonzero_rewards += abs(r["info"]["potential_reward"]) > 1e-6
                else:
                    self.assertEqual(r["info"]["potential_reward"], 0)
            self.assertGreater(transitions, 0)
            self.assertGreater(nonzero_rewards, 0)
            self.assertTrue(r["done"])
            self.assertEqual(r["info"]["potential"], 0)
            # The reported shaping must actually be paid, and only that term may
            # change between identical episodes with shaping enabled/disabled.
            config.potential_coef = 0
            r = env.reset(config)
            for reward, shaping in shaped:
                end = next(i for i, c in enumerate(r["legal"]) if c["i"]["t"] == "end")
                r = env.step(end)
                self.assertAlmostEqual(reward - r["reward"], shaping, places=6)
        finally:
            env.close()
            fixture.cleanup()


if __name__ == "__main__":
    unittest.main(verbosity=2)
