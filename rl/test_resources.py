"""Resource regressions: only disposable logs are trimmed; model state survives cleanup."""
import os
import json
import signal
import subprocess
import sys
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from resources import MIB, trim_owned_logs


class ResourceTests(unittest.TestCase):
    def test_cleanup_preserves_models_replays_and_metrics(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "run/envlogs").mkdir(parents=True)
            log = root / "run/envlogs/env0.log"
            log.write_bytes(b"x" * (2 * MIB) + b"diagnostic tail\n")
            protected = [root / "run/latest.pt", root / "run/champion_000000001.pt",
                         root / "run/ckpt_000000001.pt", root / "run/eval_log.jsonl",
                         root / "run/pre-upgrade.pt", root / "run/game.mcfr"]
            for p in protected:
                p.write_bytes(b"keep this")
            report = trim_owned_logs(root, pressure=True)
            self.assertGreater(report["reclaimed_mb"], 1)
            self.assertLessEqual(log.stat().st_size, 64 * 1024)
            self.assertTrue(log.read_bytes().endswith(b"diagnostic tail\n"))
            for p in protected:
                self.assertEqual(p.read_bytes(), b"keep this")

    def test_sparse_holes_are_not_counted_as_occupied_gigabytes(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            log = root / "training.log"
            with log.open("wb") as f:
                f.seek(2 * 1024**3)
                f.write(b"tail")
            report = trim_owned_logs(root, max_mb=1)
            self.assertEqual(report["files"], 0)
            self.assertEqual(report["reclaimed_mb"], 0)
            self.assertGreater(log.stat().st_size, 1024**3)

    def test_symlinks_cannot_trim_unrelated_files(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            runs = root / "runs"
            runs.mkdir()
            outside = root / "private.log"
            outside.write_bytes(b"x" * (2 * MIB))
            (runs / "training.log").symlink_to(outside)
            (runs / "linked-run").symlink_to(root, target_is_directory=True)
            self.assertEqual(trim_owned_logs(runs, pressure=True)["files"], 0)
            self.assertEqual(outside.stat().st_size, 2 * MIB)

    def test_active_appenders_keep_writing_to_trimmed_inode(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            log = root / "training.log"
            log.write_bytes(b"old\n" * MIB)
            before = log.stat().st_ino
            with log.open("ab", buffering=0) as writer:
                trim_owned_logs(root, pressure=True)
                writer.write(b"training continues\n")
            self.assertEqual(log.stat().st_ino, before)
            self.assertTrue(log.read_bytes().endswith(b"training continues\n"))

    def test_disk_pressure_uses_tighter_log_limit(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "training.log"
            log.write_bytes(b"x" * (2 * MIB))
            self.assertEqual(trim_owned_logs(d, max_mb=64)["files"], 0)
            self.assertEqual(trim_owned_logs(d, max_mb=64, pressure=True)["files"], 1)

    def trainer(self, path):
        import torch
        from train import Trainer, DEFAULTS
        torch.set_num_threads(1)
        return Trainer(path, DEFAULTS)

    def test_gpu_cleanup_preserves_weights_and_inflight_opponents(self):
        import torch
        with tempfile.TemporaryDirectory() as d:
            t = self.trainer(d)
            before = {k: v.clone() for k, v in t.net.state_dict().items()}
            t.device = "mps"
            t.envs = SimpleNamespace(envs=[SimpleNamespace(label="pool:live")])
            t.pool_cache.update(live=object(), retired=object(), self=object())
            metrics = [dict(gpu_driver_mb=15000, gpu_live_mb=10, gpu_cache_mb=14990),
                       dict(gpu_driver_mb=64, gpu_live_mb=10, gpu_cache_mb=54)]
            try:
                with patch.object(t, "gpu_memory", side_effect=metrics), \
                     patch("train.mem_report", return_value=dict(free_mb=768)), \
                     patch("torch.mps.synchronize") as synchronize, \
                     patch("torch.mps.empty_cache") as clear:
                    t.maintain_resources(force=True)
                    clear.assert_called_once()
                    synchronize.assert_called_once()
                self.assertFalse(t._resource_restart)
                self.assertEqual(set(t.pool_cache), {"live", "self"})
                for k, v in before.items():
                    torch.testing.assert_close(v, t.net.state_dict()[k], rtol=0, atol=0)
            finally:
                t.writer.close()

    def test_metal_framework_growth_requests_checkpointed_recycle(self):
        with tempfile.TemporaryDirectory() as d:
            t = self.trainer(d)
            t.device = "mps"
            metrics = dict(gpu_driver_mb=15000, gpu_live_mb=10, gpu_cache_mb=14990)
            try:
                with patch.object(t, "gpu_memory", return_value=metrics), \
                     patch("train.mem_report", return_value=dict(free_mb=768)), \
                     patch("torch.mps.synchronize"), patch("torch.mps.empty_cache"):
                    t.maintain_resources(force=True)
                self.assertTrue(t._resource_restart)
                self.assertEqual(t.global_step, 0)
                self.assertEqual(t.matches_done, 0)
            finally:
                t.writer.close()

    def test_ram_pressure_also_cleans_cpu_run_without_gpu(self):
        with tempfile.TemporaryDirectory() as d:
            t = self.trainer(d)
            try:
                with patch("train.mem_report", return_value=dict(free_mb=768)), \
                     patch("train.gc.collect") as collect:
                    t.maintain_resources(force=True)
                    collect.assert_called_once()
                self.assertFalse(t._resource_restart)
            finally:
                t.writer.close()

    def test_backend_cleanup_failure_requests_resume_instead_of_crashing(self):
        with tempfile.TemporaryDirectory() as d:
            t = self.trainer(d)
            t.device = "mps"
            try:
                with patch.object(t, "gpu_memory", return_value=dict(gpu_cache_mb=2048)), \
                     patch("train.mem_report", return_value=dict(free_mb=768)), \
                     patch("torch.mps.synchronize"), \
                     patch("torch.mps.empty_cache", side_effect=RuntimeError("allocator unavailable")):
                    t.maintain_resources(force=True)
                self.assertTrue(t._resource_restart)
                self.assertIn("allocator unavailable", t.resource_cleanup["errors"][0])
            finally:
                t.writer.close()

    def test_low_ram_with_large_envs_requests_checkpointed_recycle(self):
        with tempfile.TemporaryDirectory() as d:
            t = self.trainer(d)
            t.cfg["mem_limit_mb"] = 6144
            try:
                with patch("train.mem_report", return_value=dict(free_mb=768, total_mb=15000)):
                    t.maintain_resources(force=True)
                self.assertTrue(t._resource_restart)
            finally:
                t.writer.close()

    def test_recycle_saves_and_restores_completed_training_state(self):
        import numpy as np
        import torch
        from mcf_env import PROJECT
        from train import Trainer, with_defaults
        with tempfile.TemporaryDirectory() as d:
            cfg = with_defaults(dict(maps=[str(Path(PROJECT) / "rl/maps/arena_34x26.json")],
                                     n_envs=1, rollout_steps=4, epochs=1, minibatch=4,
                                     total_steps=4, preflight=False, torch_threads=1,
                                     max_actors=4, max_candidates=32, disk_floor_mb=0))
            torch.set_num_threads(1)
            t = Trainer(d, cfg)
            update = t.ppo_update
            def request_recycle_after_update(buffers):
                result = update(buffers)
                t._resource_restart = True
                return result
            t.ppo_update = request_recycle_after_update
            t.train()
            self.assertEqual(t.stop_reason, "memory")
            self.assertEqual(t.global_step, 4)
            saved = torch.load(Path(d) / "latest.pt", weights_only=False)
            self.assertEqual(saved["update"], t.update)
            self.assertTrue(saved["opt"]["state"])
            expected_torch = torch.rand(8)
            expected_numpy = np.random.rand(8)
            resumed = Trainer(str(Path(d) / "restored"), cfg)
            try:
                resumed.load(str(Path(d) / "latest.pt"))
                self.assertEqual(resumed.global_step, t.global_step)
                self.assertEqual(resumed.update, t.update)
                torch.testing.assert_close(torch.rand(8), expected_torch, atol=0, rtol=0)
                np.testing.assert_array_equal(np.random.rand(8), expected_numpy)
                for k, v in t.net.state_dict().items():
                    torch.testing.assert_close(v, resumed.net.state_dict()[k], atol=0, rtol=0)
            finally:
                resumed.writer.close()

    def test_deployment_resume_preserves_branch_and_restarts_supervisor(self):
        import torch
        script = Path(__file__).parent / "tools/deploy_rlm.sh"
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "rl/config").mkdir(parents=True)
            (root / "rl/config/tactical.yaml").write_text("seed: 1\n")
            (root / ".gitignore").write_text("rl/runs/\nrl/.env\n")
            (root / "rl/train.py").write_text("print('preflight passed')\n")
            (root / "rl/run.sh").write_text('''#!/bin/bash
set -e
case "$1" in
stop) python3 - <<'PY'
import json,pathlib
p=pathlib.Path('rl/runs/test/status.json')
p.write_text(json.dumps(dict(state='stopped',pid=1,step=10)))
PY
;;
alive) exit 1;;
resume) python3 - <<'PY'
import json,pathlib,subprocess,sys
root=pathlib.Path('rl/runs')
worker=subprocess.Popen([sys.executable,'-c','import time; time.sleep(120)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
(root/'test.pid').write_text(str(worker.pid))
(root/'test/status.json').write_text(json.dumps(dict(state='running',pid=worker.pid,step=11,code='updated')))
(root/'resumed').touch()
PY
;;
supervise) touch rl/runs/new-supervisor;;
dashboard) touch rl/runs/new-dashboard;;
fork) echo 'Unexpected new branch' >&2; exit 1;;
esac
''')
            def git(*args):
                return subprocess.run(["git", *args], cwd=root, check=True,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            git("init", "-b", "main")
            git("config", "user.email", "test@example.invalid")
            git("config", "user.name", "Resource regression")
            git("add", ".")
            git("commit", "-m", "Fixture")
            remote = root / "remote.git"
            subprocess.run(["git", "init", "--bare", str(remote)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            git("remote", "add", "origin", str(remote))
            git("push", "origin", "main")
            runs = root / "rl/runs/test"
            runs.mkdir(parents=True)
            torch.save(dict(global_step=10), runs / "latest.pt")
            (root / "rl/.env").write_text("VENV='" + str(Path(sys.executable).parent.parent) + "'\n")
            try:
                result = subprocess.run(["bash", str(script), "test", "--resume"], cwd=root,
                                        capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("test resumed with its checkpoint and config preserved", result.stdout)
                self.assertTrue((runs.parent / "new-supervisor").exists())
                self.assertTrue((runs.parent / "new-dashboard").exists())
                self.assertFalse((runs / "SUPERVISOR_OFF").exists())
                self.assertTrue(list(runs.glob("pre-upgrade-*.pt")))
                self.assertEqual(torch.load(runs / "latest.pt", weights_only=False)["global_step"], 10)
            finally:
                pid = runs.parent / "test.pid"
                if pid.exists():
                    os.kill(int(pid.read_text()), signal.SIGTERM)

    def test_out_of_memory_becomes_automatic_resume_not_unrecorded_crash(self):
        import torch
        from mcf_env import PROJECT
        from train import Trainer, with_defaults
        with tempfile.TemporaryDirectory() as d:
            cfg = with_defaults(dict(maps=[str(Path(PROJECT) / "rl/maps/arena_34x26.json")],
                                     n_envs=1, rollout_steps=1, total_steps=1, preflight=False,
                                     torch_threads=1, max_actors=4, max_candidates=32,
                                     disk_floor_mb=0))
            torch.set_num_threads(1)
            t = Trainer(d, cfg)
            before = {k: v.clone() for k, v in t.net.state_dict().items()}
            with patch.object(t, "ppo_update", side_effect=RuntimeError("MPS backend out of memory")):
                t.train()
            status = json.loads((Path(d) / "status.json").read_text())
            self.assertEqual(status["state"], "stopped")
            self.assertEqual(status["stop_reason"], "memory")
            saved = torch.load(Path(d) / "latest.pt", weights_only=False)
            for k, v in before.items():
                torch.testing.assert_close(v, saved["model"][k], rtol=0, atol=0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
