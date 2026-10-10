"""Evaluation must never hold the learner or operator controls indefinitely."""
import ast
import glob
import json
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import pandas as pd
import torch
import train


class FinishedEnv:
    last = None
    def send(self, command):
        self.command = command
    def recv(self):
        return dict(done=True, info=dict(result="win", by="value", round=2,
                    value_diff=.2, steps=4, illegal=0))


class EvaluationSchedulingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        torch.set_num_threads(1)

    def trainer(self, directory):
        t = train.Trainer(directory, train.with_defaults(dict(maps=["toy"], eval_maps=["toy"], n_envs=1,
                          eval_budget_seconds=5, promotion_budget_seconds=5)))
        t.envs = SimpleNamespace(envs=[FinishedEnv()], rebuild=Mock())
        t.write_status = Mock()
        t._last_status = train.time.time()
        t.writer.close()
        t.writer = Mock()
        return t

    def test_timeout_inside_socket_wait_keeps_games_but_never_returns_partial_score(self):
        with tempfile.TemporaryDirectory() as d:
            t = self.trainer(d)
            clock = [100.0]
            old_wait = Mock()
            t.envs.on_wait = old_wait
            def wait(ids):
                clock[0] += 3
                t.envs.on_wait()
                return ids
            t.envs.wait_any = wait
            with patch.object(train.time, "monotonic", side_effect=lambda: clock[0]):
                with self.assertRaisesRegex(train.EvaluationInterrupted, "time budget"):
                    t.evaluate(160)
            rows = [json.loads(line) for line in Path(d, "eval_games.jsonl").read_text().splitlines()]
            self.assertEqual(len(rows), 1)
            self.assertIs(t.envs.on_wait, old_wait)
            self.assertIsNone(t._evaluation_deadline)
            self.assertEqual(old_wait.call_count, 1)

    def test_stop_and_pause_interrupt_in_progress_games(self):
        for flag in ("STOP", "PAUSE"):
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as d:
                t = self.trainer(d)
                def wait(ids):
                    Path(d, flag).touch()
                    t.envs.on_wait()
                    return ids
                t.envs.wait_any = wait
                with self.assertRaisesRegex(train.EvaluationInterrupted, "stop/pause"):
                    t.evaluate(160)
                self.assertFalse(Path(d, "eval_games.jsonl").exists())

    def test_nested_suite_cannot_reset_total_budget(self):
        with tempfile.TemporaryDirectory() as d:
            t = self.trainer(d)
            clock = [100.0]
            with patch.object(train.time, "monotonic", side_effect=lambda: clock[0]):
                with t.evaluation_window(5):
                    clock[0] += 4
                    with t.evaluation_window(5):
                        self.assertEqual(t._evaluation_deadline, 105)
                        clock[0] += 2
                        with self.assertRaises(train.EvaluationInterrupted):
                            t.check_evaluation()
            self.assertIsNone(t._evaluation_deadline)

    def test_interrupted_promotion_preserves_champion_and_resets_environments(self):
        with tempfile.TemporaryDirectory() as d:
            t = self.trainer(d)
            t.save("best.pt")
            before = Path(d, "best.pt").read_bytes()
            with patch.object(t, "evaluate", side_effect=train.EvaluationInterrupted("budget")):
                t.run_promotion()
            self.assertEqual(before, Path(d, "best.pt").read_bytes())
            self.assertFalse(Path(d, "promotion.json").exists())
            self.assertEqual(t.promotion_attempts, 1)
            t.envs.rebuild.assert_called_once()
            self.assertEqual(t.eval_live, {})
            record = json.loads(Path(d, "eval_interruptions.jsonl").read_text())
            self.assertTrue(record["incomplete"])
            self.assertEqual(record["suite"], "promotion")

    def test_completed_main_result_survives_optional_suite_timeout(self):
        with tempfile.TemporaryDirectory() as d:
            t = self.trainer(d)
            t.cfg.update(eval_nofog_games=2, promotion_every=1000)
            result = dict(games=10, winrate=.6, lossrate=.3, drawrate=.1,
                          value_diff=.2, rounds=20, stallrate=0, rout_winrate=.1,
                          value_winrate=.5, illegal=0, outcomes={})
            with patch.object(t, "evaluate", side_effect=[result, train.EvaluationInterrupted("budget")]):
                t.run_eval()
            rows = Path(d, "eval_log.jsonl").read_text().splitlines()
            self.assertEqual(len(rows), 1)
            row = json.loads(rows[0])
            self.assertEqual(row["winrate_hard"], .6)
            self.assertFalse(row["full_suite"])
            t.envs.rebuild.assert_called_once()

    def test_real_environment_resumes_learning_after_deadline(self):
        from mcf_env import VecEnv
        with tempfile.TemporaryDirectory() as d:
            cfg = train.load_config(os.path.join(train.PROJECT, "rl/config/smoke.yaml"))
            cfg.update(n_envs=1, rollout_steps=2, minibatch=2, epochs=1, torch_threads=1,
                       eval_budget_seconds=.01, max_candidates=32, max_actors=4)
            t = train.Trainer(d, cfg)
            t.envs = VecEnv(1, cfg["godot"], log_dir=os.path.join(d, "envlogs"))
            try:
                t.run_eval()
                self.assertTrue(Path(d, "eval_interruptions.jsonl").exists())
                buffers, _ = t.collect()
                t.ppo_update(buffers)
                self.assertEqual(t.global_step, 2)
                self.assertEqual(t.update, 1)
            finally:
                t.envs.close()
                t.writer.close()

    def test_dashboard_includes_champion_logs_and_separates_retries(self):
        source = Path(train.PROJECT, "rl/dashboard.py")
        tree = ast.parse(source.read_text())
        node = next(n for n in tree.body if isinstance(n, ast.FunctionDef)
                    and n.name == "recent_eval_game_counts")
        with tempfile.TemporaryDirectory() as root:
            branch = Path(root, "test")
            branch.mkdir()
            def row(game, seed, result, when, suite="promotion", opponent="champion"):
                return dict(step=100, game=game, seed=seed, result=result, time=when,
                            suite=suite, opponent=opponent)
            Path(branch, "eval_games.jsonl").write_text(json.dumps(row(1, 1, "win", 1, "main", "hard")) + "\n")
            promotion = [row(1, 100, "loss", 2), row(2, 100, "loss", 3),
                         row(1, 200, "win", 4)]
            Path(branch, "eval_promotion_games.jsonl").write_text(
                "\n".join(json.dumps(r) for r in promotion) + "\n")
            namespace = dict(RUNS=root, os=os, glob=glob, pd=pd,
                             jsonl=lambda path: pd.read_json(path, lines=True))
            exec(compile(ast.Module(body=[node], type_ignores=[]), str(source), "exec"), namespace)
            result = namespace["recent_eval_game_counts"]("test", 100)
            self.assertEqual(result, dict(suite="promotion", opponent="CHAMPION",
                                         completed=1, win=1, loss=0, draw=0))

    def test_pending_control_cancels_before_any_evaluation_action(self):
        with tempfile.TemporaryDirectory() as d:
            t = self.trainer(d)
            t.envs.wait_any = Mock()
            t.stop_requested = True
            with self.assertRaises(train.EvaluationInterrupted):
                t.evaluate(160)
            t.envs.wait_any.assert_not_called()


if __name__ == "__main__":
    unittest.main()
