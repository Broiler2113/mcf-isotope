"""Learning clock, spatial batching, replay ingestion, and selection regressions."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest

import numpy as np
import torch
import train
from demonstrations import import_replay, ReplayDataset, read_chunk
from features import (Sparse, N_CHANNELS, CAND_DIM, C_VEH_CRUSH, F_VEH_CRUSH,
                      F_ADVANCE, F_SPACING, F_COUNTER_TANK, candidate_rows, grid_tensor)
from mcf_env import PROJECT, VecEnv
from model import PolicyNet
from selection import promotion_decision
from test_rl import fake_obs, legal_move


class LearningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(1)

    def step(self, size=64, action=0):
        row = dict(obs=fake_obs(), legal=[legal_move(5, 7, 6, 7), legal_move(5, 7, 5, 8)])
        return train.Step(*train.encode(row, size), action, -.69, 0)

    def test_credit_crosses_hundreds_of_decisions_in_same_round(self):
        buf = [SimpleNamespace(value=0, reward=0, done=False, discount=1, trace_discount=1) for _ in range(500)]
        buf[-1].reward, buf[-1].done = 1, True
        np.testing.assert_allclose(train.Trainer.advantages(buf, 0, .97, .95), 1)
        buf[249].discount, buf[249].trace_discount = .97, .97 * .95
        adv = train.Trainer.advantages(buf, 0, .97, .95)
        self.assertAlmostEqual(float(adv[0]), .97 * .95, places=6)
        for s in buf:
            s.discount = s.trace_discount = None
        self.assertLess(float(train.Trainer.advantages(buf, 0, .99, .95)[0]), 1e-12)

    def test_spatial_buckets_match_individual_inference(self):
        net = PolicyNet().eval()
        samples = [self.step(size) for size in (64, 96, 64, 80)]
        encoded = [(s.grid, s.flat, s.cand, s.cells) for s in samples]
        actual = train.choose(net, encoded, "cpu", greedy=True)
        individual = [train.choose(net, [row], "cpu", greedy=True) for row in encoded]
        for k in range(3):
            np.testing.assert_allclose(actual[k], [x[k][0] for x in individual], atol=1e-6)
        batches = train.canvas_batches(samples, 2)
        self.assertEqual(sorted(int(i) for b in batches for i in b), list(range(4)))
        for b in batches:
            self.assertEqual(len({samples[i].grid.shape for i in b}), 1)

    def test_vehicle_lane_reaches_policy_and_safe_move_prior(self):
        obs = fake_obs()
        obs["vcrush"] = [0] * (obs["w"] * obs["h"])
        obs["vcrush"][7 * obs["w"] + 5] = 4
        legal = [legal_move(5, 7, 6, 7), legal_move(5, 7, 5, 8)]
        legal[0]["vc"] = [1, 0]
        legal[1]["vc"] = [1, 1]
        rows, cells = candidate_rows(obs, legal)
        self.assertEqual(rows[0, F_VEH_CRUSH], 1)
        self.assertEqual(rows[1, F_VEH_CRUSH + 1], 1)
        grid = grid_tensor(obs)
        yy = (64 - obs["h"]) // 2 + 7
        xx = (64 - obs["w"]) // 2 + 5
        self.assertEqual(grid[C_VEH_CRUSH, yy, xx], 1)
        net = PolicyNet().eval()
        with torch.no_grad():
            for p in net.parameters():
                p.zero_()
            scores, _ = net(torch.from_numpy(grid[None]), torch.zeros(1, 20),
                            torch.from_numpy(rows[None]), torch.from_numpy(cells[None]),
                            torch.ones(1, 2, dtype=torch.bool))
        self.assertGreater(scores[0, 0].item(), scores[0, 1].item() + 2)

    def test_giant_board_uses_bounded_feature_grid_and_valid_cells(self):
        net = PolicyNet()
        grid = torch.rand(1, N_CHANNELS, 160, 160)
        flat = torch.zeros(1, 20)
        cand = torch.zeros(1, 2, CAND_DIM)
        cells = torch.tensor([[[159 * 160 + 159, 0], [159 * 160 + 80, 80]]])
        mask = torch.ones(1, 2, dtype=torch.bool)
        fmap, _ = net.embed(grid, flat)
        self.assertEqual(tuple(fmap.shape[-2:]), (96, 96))
        scores, value = net(grid, flat, cand, cells, mask)
        self.assertTrue(torch.isfinite(scores).all())
        (scores.sum() + value.sum()).backward()
        self.assertIsNotNone(net.conv[0].weight.grad)

    def test_giant_moves_approach_contact_and_leave_dense_clumps(self):
        obs = dict(w=149, h=119, units=[dict(x=x, y=20, own=0) for x in range(11, 17)] +
                   [dict(x=125, y=20, own=1)], vehicles=[])
        toward = legal_move(15, 20, 23, 20)
        away = legal_move(15, 20, 7, 20)
        rows, _ = candidate_rows(obs, [toward, away])
        self.assertGreater(rows[0, F_ADVANCE], 0)
        self.assertLess(rows[1, F_ADVANCE], 0)
        self.assertGreater(rows[0, F_SPACING], 0)
        obs["units"].append(dict(x=-9999, y=-9999, own=1, aboard=1))
        rows_with_crew, _ = candidate_rows(obs, [toward])
        self.assertEqual(rows_with_crew[0, F_ADVANCE], rows[0, F_ADVANCE])
        small = dict(obs, w=80, h=60)
        rows_small, _ = candidate_rows(small, [toward])
        self.assertEqual(rows_small[0, F_ADVANCE], 0)

    def test_clean_track_shot_prior_disappears_near_allies(self):
        obs = dict(w=32, h=24, units=[dict(x=2, y=2, own=0)], vehicles=[
            dict(id=9, x=15, y=10, w=3, h=3, own=1, alive=1, type=0,
                 comps=dict(hull=[8, 8]), fx=1, fy=0, wrecked=0)])
        shot = dict(i=dict(t="shoot", a=1, tid=-1, cx=16, cy=11,
                           cm="tracks_l", s=1), ax=2, ay=2, tx=16, ty=11,
                    at=4, tt=-1)
        clean, _ = candidate_rows(obs, [shot])
        self.assertEqual(clean[0, F_COUNTER_TANK], 1.25)
        obs["units"].append(dict(x=16, y=12, own=0))
        crowded, _ = candidate_rows(obs, [shot])
        self.assertEqual(crowded[0, F_COUNTER_TANK], 0)

    def test_human_examples_change_policy_without_fake_ppo_ratios(self):
        with tempfile.TemporaryDirectory() as d:
            t = train.Trainer(d, dict(n_envs=1, epochs=1, minibatch=1, lr=.001,
                                     demonstration_coef=1, demonstration_batch=1,
                                     ent_coef=0, vf_coef=0, torch_threads=1))
            try:
                step = self.step(action=1)
                step.done = True
                t.envs = SimpleNamespace(envs=[SimpleNamespace(last=None)])
                t.demonstrations = SimpleNamespace(sample=lambda n: [step])
                before = train.choose(t.net, [(step.grid, step.flat, step.cand, step.cells)], "cpu", greedy=True)
                with torch.no_grad():
                    logits, _ = t.net(*train.collate([step], "cpu"))
                    p0 = logits.softmax(1)[0, 1].item()
                result = t.ppo_update([[step]])
                with torch.no_grad():
                    logits, _ = t.net(*train.collate([step], "cpu"))
                    p1 = logits.softmax(1)[0, 1].item()
                self.assertIn("demonstration_loss", result)
                self.assertGreater(p1, p0)
            finally:
                t.writer.close()

    def test_training_replay_sidecar_and_curriculum(self):
        from mcf_env import EpisodeConfig
        from collections import Counter
        with tempfile.TemporaryDirectory() as d:
            t = train.Trainer(d, dict(maps=["easy", "hard"], map_weights=[1, 1], adaptive_curriculum=True))
            try:
                env = SimpleNamespace(cfg=EpisodeConfig("human-map", seed=1, fog=0),
                                      label="ai:hard", save_replay=lambda path: True)
                t._save_rollout_replay(env, "win", dict(round=4, value_diff=.2, illegal=0))
                sidecars = list(Path(d).glob("replays/*/*.json"))
                self.assertEqual(len(sidecars), 1)
                self.assertEqual(json.loads(sidecars[0].read_text())["fog"], 0)
                t.curriculum_scores = {"easy": 1.0, "hard": 0.0}
                counts = Counter(t.pick_map() for _ in range(1000))
                self.assertGreater(counts[0], 100)
                self.assertGreater(counts[1], 700)
            finally:
                t.writer.close()

    def test_selection_uses_pairs_and_rejects_noise_and_illegal_actions(self):
        rows = [dict(map="map", seed=k//2, side=k%2, result="win", illegal=0) for k in range(80)]
        self.assertTrue(promotion_decision(rows)["promote"])
        self.assertEqual(promotion_decision(rows)["pairs"], 40)
        self.assertFalse(promotion_decision(rows[:10])["promote"])
        self.assertFalse(promotion_decision(rows[:-1])["promote"])
        draws = [r | {"result": "draw"} for r in rows]
        self.assertFalse(promotion_decision(draws)["promote"])
        rows[0]["illegal"] = 1
        self.assertFalse(promotion_decision(rows)["promote"])

    def test_new_horizon_preserves_policy_and_resumes_selection_counter(self):
        with tempfile.TemporaryDirectory() as d:
            a = train.Trainer(os.path.join(d, "old"), dict(torch_threads=1))
            b = train.Trainer(os.path.join(d, "new"), dict(discount_unit="round", gamma=.97, torch_threads=1))
            try:
                a.promotion_attempts = 7
                source = a.save()
                before = copy.deepcopy(a.net.state_dict())
                b.load(source, keep_cfg=True)
                self.assertEqual(b.promotion_attempts, 7)
                for key, value in b.net.state_dict().items():
                    if not key.startswith("value."):
                        torch.testing.assert_close(value, before[key])
                self.assertFalse(torch.equal(b.net.value[0].weight, a.net.value[0].weight))
                resumed = b.save()
                value = b.net.value[0].weight.clone()
                b.load(resumed, keep_cfg=True)
                torch.testing.assert_close(value, b.net.value[0].weight)
            finally:
                a.writer.close(); b.writer.close()

    def test_real_network_replay_import_and_rejection(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "human.mcfr")
            proc = subprocess.run(["godot", "--headless", "--path", PROJECT, "--script",
                                   "res://tests/run_rl_learning.gd", "--", path],
                                  capture_output=True, text=True, timeout=90)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            root = os.path.join(d, "dataset")
            manifest = import_replay(path, root)
            self.assertGreater(manifest["samples"], 0)
            self.assertEqual(import_replay(path, root), manifest)
            data = ReplayDataset(root, manifest["split"])
            samples = data.sample(4)
            self.assertEqual(len(samples), 4)
            self.assertEqual(ReplayDataset(root, "holdout" if manifest["split"] == "train" else "train").sample(4), [])
            for s in samples:
                self.assertTrue(0 <= s.action < s.cand.shape[0])
                self.assertEqual(s.grid.shape[0], N_CHANNELS)
            with self.assertRaisesRegex(ValueError, "validation failed"):
                import_replay(path + ".bad.mcfr", root)
            self.assertEqual(len(list(Path(root).glob("*/manifest.json"))), 1)

    def test_head_to_head_evaluation_routes_both_policies_and_balances_conditions(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = train.load_config(os.path.join(PROJECT, "rl/config/smoke.yaml"))
            cfg.update(n_envs=1, max_steps=4, max_actors=4, max_candidates=32, torch_threads=1)
            t = train.Trainer(d, cfg)
            t.envs = VecEnv(1, cfg["godot"], log_dir=os.path.join(d, "envlogs"))
            try:
                result = t.evaluate(8, opponent_net=copy.deepcopy(t.act_net), suite="promotion",
                                    seed_base=87000000, fogs=[0, 0, 1, 1], round_cap=2)
                self.assertEqual(len(result["per_game"]), 8)
                pairs = sorted(result["per_game"], key=lambda x:x["game"])
                for a, b in zip(pairs[::2], pairs[1::2]):
                    self.assertEqual((a["seed"], a["fog"], a["random_events"]),
                                     (b["seed"], b["fog"], b["random_events"]))
                    self.assertNotEqual(a["side"], b["side"])
                self.assertEqual({r["random_events"] for r in pairs}, {True, False})
                self.assertEqual({r["fog"] for r in pairs}, {0, 1})
            finally:
                t.envs.close(); t.writer.close()

if __name__ == "__main__":
    unittest.main()
