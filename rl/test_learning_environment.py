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
from features import Sparse, N_CHANNELS, CAND_DIM
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
