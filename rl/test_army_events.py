"""End-turn decoding, hazard observations/rewards, and large-army live play."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import numpy as np
import torch

import features as ft
from mcf_env import PROJECT, EpisodeConfig, EXTERNAL, GodotEnv, VecEnv
from model import PolicyNet, greedy_action, load_compat
from test_rl import fake_obs, legal_move
import train


class ArmyEventTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(1)

    def test_diffuse_moves_continue_but_deliberate_pass_survives(self):
        # Each move scores less than end. Their combined probability says continue.
        cand = torch.zeros(3, 512, ft.CAND_DIM)
        cand[:, :, ft.F_KIND + ft.KIND_INDEX["move"]] = 1
        cand[:, 0, ft.F_KIND + ft.KIND_INDEX["move"]] = 0
        cand[:, 0, ft.F_KIND + ft.KIND_INDEX["end"]] = 1
        logits = torch.zeros(3, 512)
        logits[0, 0], logits[1, 0], logits[2, 0] = 2, 10, 2
        mask = torch.ones(3, 512, dtype=torch.bool)
        mask[2, 1:] = False  # exhausted army: only end is legal
        self.assertEqual(logits[0].argmax().item(), 0)
        self.assertLess(logits[0].softmax(0)[0].item(), .02)
        self.assertEqual(greedy_action(logits, cand, mask).tolist(), [1, 0, 0])
        # Padding with enormous scores must never affect either branch.
        logits[2, 1:] = 1000
        self.assertEqual(greedy_action(logits, cand, mask)[2].item(), 0)

    def test_hazard_grid_and_candidates_are_separate_and_optional(self):
        obs = fake_obs()
        for key in ("gas", "gas_warning", "artillery_warning"):
            obs[key] = [0.0] * (obs["w"] * obs["h"])
        obs["gas"][7 * obs["w"] + 5] = 1
        obs["gas_warning"][7 * obs["w"] + 6] = .5
        obs["artillery_warning"][7 * obs["w"] + 6] = 1
        move = legal_move(5, 7, 6, 7)
        move["hazard"] = [1, 0, 0, 0, .5, 1]
        rows, cells = ft.candidate_rows(obs, [move])
        grid = ft.grid_tensor(obs)
        ay, ax = divmod(cells[0, 0], 64)
        ty, tx = divmod(cells[0, 1], 64)
        self.assertEqual(grid[ft.C_GAS, ay, ax], 1)
        self.assertEqual(grid[ft.C_GAS_WARNING, ty, tx], .5)
        self.assertEqual(grid[ft.C_ARTILLERY_WARNING, ty, tx], 1)
        np.testing.assert_array_equal(rows[0, ft.F_HAZARD:], move["hazard"])
        self.assertEqual(ft.grid_tensor(fake_obs())[ft.C_GAS:].sum(), 0)

    def test_previous_checkpoint_and_adam_keep_logits_with_new_features(self):
        old = PolicyNet()
        old.conv[0] = torch.nn.Conv2d(ft.C_GAS, old.fmap, 3, padding=1)
        old.cand[0] = torch.nn.Linear(ft.F_HAZARD + 2 * old.fmap + 256, 256)
        opt_old = torch.optim.Adam(old.parameters(), lr=1e-4)
        grid, flat = torch.rand(1, ft.N_CHANNELS, 64, 64), torch.rand(1, ft.FLAT_DIM)
        cand = torch.rand(1, 4, ft.CAND_DIM)
        cells, mask = torch.zeros(1, 4, 2, dtype=torch.long), torch.ones(1, 4, dtype=torch.bool)
        args = (grid[:, :ft.C_GAS], flat, cand[:, :, :ft.F_HAZARD], cells, mask)
        logits, value = old(*args)
        (logits.sum() + value.sum()).backward()
        opt_old.step()
        new = PolicyNet()
        opt = torch.optim.Adam(new.parameters(), lr=1e-4)
        load_compat(new, old.state_dict(), opt, opt_old.state_dict())
        for got, expected in zip(new(grid, flat, cand, cells, mask), old(*args)):
            torch.testing.assert_close(got, expected, atol=1e-5, rtol=1e-4)
        logits, value = new(grid, flat, cand, cells, mask)
        (logits.sum() + value.sum()).backward()
        opt.step()

    def test_episode_event_sampling_and_protocol(self):
        with tempfile.TemporaryDirectory() as d:
            t = train.Trainer(d, train.with_defaults(dict(
                maps=["toy.json"], random_events=True, random_event_share=.35)))
            try:
                configs = [t.next_episode()[0] for _ in range(1000)]
                share = sum(c.random_events for c in configs) / len(configs)
                self.assertGreater(share, .29)
                self.assertLess(share, .41)
                cmd = configs[0].to_cmd()
                self.assertEqual(cmd["random_event_interval"], 6)
                self.assertEqual(cmd["hazard_coef"], .5)
                t.cfg["random_events"] = False
                self.assertFalse(t.next_episode()[0].random_events)
            finally:
                t.writer.close()

    def test_event_eval_is_separate_from_main_benchmark(self):
        class Env:
            last = None

            def send(self, cmd):
                self.cmd = cmd

            def recv(self):
                return dict(done=True, info=dict(result="win", by="value", round=2,
                    value_diff=.2, steps=3, illegal=0, tac=dict(hazard_exposure=.1)))

        with tempfile.TemporaryDirectory() as d:
            t = train.Trainer(d, train.with_defaults(dict(maps=["toy"], random_events=True)))
            env = Env()
            t.envs = type("E", (), dict(envs=[env], wait_any=lambda s, ids: list(ids)))()
            t.write_status = lambda *a, **kw: None
            t._last_status = time.time()
            try:
                t.evaluate(2)
                self.assertFalse(env.cfg.random_events)
                result = t.evaluate(2, suite="events")
                self.assertTrue(env.cfg.random_events)
                self.assertEqual(result["hazard_exposure"], .1)
                main = [json.loads(x) for x in Path(d, "eval_games.jsonl").read_text().splitlines()]
                events = [json.loads(x) for x in Path(d, "eval_events_games.jsonl").read_text().splitlines()]
                self.assertEqual(len(main), 2)
                self.assertTrue(all(not r["random_events"] for r in main))
                self.assertTrue(all(r["random_events"] for r in events))
                self.assertEqual(events[0]["decoding"], "stop_continue_mass_v1")
            finally:
                t.writer.close()

    def test_event_suite_follows_full_evaluation_cadence(self):
        with tempfile.TemporaryDirectory() as d:
            t = train.Trainer(d, train.with_defaults(dict(
                eval_full_every=100, eval_games=2, event_eval_games=6)))
            result = dict(games=2, winrate=.5, lossrate=.5, drawrate=0,
                value_diff=0, rounds=20, stallrate=0, rout_winrate=0,
                value_winrate=.5, illegal=0, outcomes={}, by_map={}, hazard_exposure=.1)
            t.has_eval_history = lambda: True
            try:
                with patch.object(t, "evaluate", return_value=result) as evaluate:
                    t.update = 25
                    t.run_eval()
                    self.assertEqual(evaluate.call_count, 1)
                    evaluate.reset_mock()
                    t.update = 100
                    t.run_eval()
                    self.assertEqual(evaluate.call_count, 2)
                    self.assertEqual(evaluate.call_args.kwargs["suite"], "events")
                    self.assertEqual(evaluate.call_args.args[0], 6)
                    self.assertEqual(t.last_eval["events"]["hazard_exposure"], .1)
            finally:
                t.writer.close()

    def test_actual_godot_escape_accounting_and_seeded_events(self):
        p = subprocess.run(["godot", "--headless", "--path", PROJECT,
                            "--script", "res://tests/run_rl_hazards.gd"],
                           capture_output=True, text=True, timeout=90)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("seeded events passed", p.stdout)
        self.assertNotIn("SCRIPT ERROR", p.stderr)

    def test_real_live_army_with_single_highest_stop_score(self):
        # An adversarial checkpoint: end logit 2, all other logits 0. Before this
        # fix the live controller skips EVERY turn, whatever the army size.
        with tempfile.TemporaryDirectory() as d:
            net = PolicyNet()
            with torch.no_grad():
                for p in net.parameters():
                    p.zero_()
                net.cand[0].weight[0, ft.F_KIND + ft.KIND_INDEX["end"]] = 2
                net.cand[2].weight[0, 0] = 1
                net.cand[4].weight[0, 0] = 1
            ck = Path(d, "model.pt")
            torch.save(dict(model=net.state_dict()), ck)
            with socket.socket() as s:
                s.bind(("127.0.0.1", 0))
                port = s.getsockname()[1]
            with open(Path(d, "server.log"), "w") as log:
                proc = subprocess.Popen([sys.executable, str(Path(PROJECT, "rl/policy_server.py")),
                                         str(ck), "--port", str(port)], stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 30
                    while True:
                        try:
                            with socket.create_connection(("127.0.0.1", port), timeout=1):
                                break
                        except OSError:
                            if proc.poll() is not None or time.monotonic() > deadline:
                                self.fail("policy server failed to start")
                            time.sleep(.05)
                    game = subprocess.run(["godot", "--headless", "--path", PROJECT,
                                           "--script", "res://tests/run_learned_large_army.gd"],
                        env=dict(os.environ, MCF_RL_POLICY=f"127.0.0.1:{port}",
                                 MCF_RL_MAX_ACTORS="16", MCF_RL_MAX_CANDIDATES="512"),
                        capture_output=True, text=True, timeout=180)
                    self.assertEqual(game.returncode, 0, game.stdout + game.stderr)
                    self.assertIn("176 units, 60 actions", game.stdout)
                    self.assertNotIn("SCRIPT ERROR", game.stderr)
                    print(game.stdout.strip())
                finally:
                    proc.terminate()
                    proc.wait(timeout=10)

    def test_eventful_self_play_ppo_updates_and_checkpoint_resume(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = train.with_defaults(dict(maps=[str(Path(PROJECT, "rl/maps/arena_34x26.json"))],
                n_envs=1, phase="league", pool_ai_fraction=0, random_events=True,
                random_event_share=1, random_event_interval=1, rollout_steps=24,
                max_candidates=64, max_actors=4, minibatch=8, epochs=1, torch_threads=1))
            t = train.Trainer(d, cfg)
            try:
                t.envs = VecEnv(1, "godot", log_dir=str(Path(d, "envlogs")))
                buffers, info = t.collect()
                self.assertEqual(t.envs.envs[0].cfg.opponent, EXTERNAL)
                self.assertTrue(t.envs.envs[0].cfg.random_events)
                losses = t.ppo_update(buffers)
                self.assertTrue(all(np.isfinite(v) for v in losses.values()))
                t.save()
                clone = train.Trainer(str(Path(d, "resume")), cfg)
                try:
                    clone.load(str(Path(d, "latest.pt")))
                    for name, value in t.net.state_dict().items():
                        torch.testing.assert_close(clone.net.state_dict()[name], value)
                    self.assertEqual(clone.global_step, t.global_step)
                finally:
                    clone.writer.close()
            finally:
                if t.envs:
                    t.envs.close()
                t.writer.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
