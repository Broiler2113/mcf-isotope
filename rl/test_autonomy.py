"""Disk-pressure and unattended recovery regressions; never fill a real disk."""
import json
import os
from pathlib import Path
import tempfile
import time
import subprocess
import sys
import unittest
from unittest.mock import patch

import autonomy
from resources import maintain_storage


class StorageTests(unittest.TestCase):
    def artifact(self, path, content=b"artifact"):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        os.utime(path, (time.time() - 7200,) * 2)
        return path

    def test_pressure_reclaims_old_artifacts_and_preserves_resume_pool_and_unknown_files(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            run = root / "main"
            self.artifact(run / "config.yaml", b"pool_size: 3\npool_archive_size: 3\n")
            protected = [self.artifact(run / name) for name in
                         ("latest.pt", "best.pt", "seed_parent.pt", "pre-upgrade-20261016T000000Z.pt",
                          "champion_999999999.pt", "eval_log.jsonl", "manual.mcfr",
                          "ckpt_123_manual.pt", "pre-upgrade-manual.pt")]
            checkpoints = [self.artifact(run / f"ckpt_{i:09d}.pt") for i in range(20)]
            protected += [checkpoints[i] for i in (0, 8, 16, 17, 18, 19)]
            for i in range(5):
                self.artifact(run / f"replays/train_{i:09d}/game.mcfr")
            newest = run / "replays/train_000000004/game.mcfr"
            protected.append(newest)
            self.artifact(run / "pre-upgrade-20261001T000000Z.pt")
            def free(_):
                deleted = sum(not p.exists() for p in checkpoints)
                return 600 + 200 * deleted
            with patch("resources.disk_free_mb", side_effect=free):
                report = maintain_storage(root)
            self.assertGreaterEqual(report["free_mb"], 2048)
            self.assertGreater(report["deleted"], 4)
            self.assertTrue(report["ready"])
            self.assertTrue(all(p.exists() for p in protected))

    def test_healthy_disk_does_not_delete_history(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.artifact(root / "config.yaml", b"pool_size: 1\n")
            paths = [self.artifact(root / f"ckpt_{i:09d}.pt") for i in range(10)]
            with patch("resources.disk_free_mb", return_value=4096):
                report = maintain_storage(root)
            self.assertEqual(report["deleted"], 0)
            self.assertTrue(all(p.exists() for p in paths))

    def test_unreclaimable_disk_reports_wait_instead_of_deleting_last_model(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            latest = self.artifact(root / "latest.pt")
            with patch("resources.disk_free_mb", return_value=520):
                report = maintain_storage(root, required_mb=64)
            self.assertFalse(report["ready"])
            self.assertTrue(latest.exists())

    def test_symlinks_and_recent_files_cannot_be_deleted(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            run = root / "runs/main"
            self.artifact(run / "config.yaml", b"pool_size: 1\n")
            outside = self.artifact(root / "private.pt")
            (run / "ckpt_000000000.pt").symlink_to(outside)
            for i in (1, 2, 3):
                (run / f"ckpt_{i:09d}.pt").write_bytes(b"new")
            (run / "replays").symlink_to(root, target_is_directory=True)
            with patch("resources.disk_free_mb", return_value=500):
                report = maintain_storage(root / "runs")
            self.assertEqual(report["deleted"], 0)
            self.assertTrue(outside.exists())

    def test_unreadable_config_keeps_entire_checkpoint_pool(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.artifact(root / "config.yaml", b"[")
            paths = [self.artifact(root / f"ckpt_{i:09d}.pt") for i in range(20)]
            with patch("resources.disk_free_mb", return_value=600):
                maintain_storage(root)
            self.assertTrue(all(p.exists() for p in paths))

    def test_checkpoint_refuses_write_below_floor_and_keeps_previous_latest(self):
        import torch
        from train import Trainer, DEFAULTS, DiskPressure
        torch.set_num_threads(1)
        with tempfile.TemporaryDirectory() as d:
            t = Trainer(d, DEFAULTS)
            try:
                t.save()
                path = Path(d) / "latest.pt"
                previous = path.read_bytes()
                t.global_step += 1
                with patch("resources.disk_free_mb", return_value=501):
                    with self.assertRaises(DiskPressure):
                        t.save()
                self.assertEqual(path.read_bytes(), previous)
                self.assertFalse(list(Path(d).glob("*.tmp")))
            finally:
                t.writer.close()

    def test_operator_stop_at_step_target_does_not_become_autonomous_completion(self):
        import torch
        from train import Trainer, with_defaults, PROJECT
        torch.set_num_threads(1)
        with tempfile.TemporaryDirectory() as d:
            cfg = with_defaults(dict(maps=[str(Path(PROJECT) / "rl/maps/arena_34x26.json")],
                                     n_envs=1, rollout_steps=1, epochs=1, minibatch=1,
                                     total_steps=1, preflight=False, torch_threads=1,
                                     max_actors=4, max_candidates=32))
            t = Trainer(d, cfg)
            update = t.ppo_update
            def stop_at_target(buffers):
                result = update(buffers)
                (Path(d) / "STOP").touch()
                return result
            t.ppo_update = stop_at_target
            t.has_eval_history = lambda: True
            t.train()
            self.assertEqual(t.stop_reason, "")
            self.assertTrue(t.stop_requested)


class SupervisionTests(unittest.TestCase):
    def fixture(self, d, **state):
        root = Path(d) / "runs/main"
        root.mkdir(parents=True)
        status = root / "status.json"
        status.write_text(json.dumps(dict(pid=123, step=100, state="running") | state))
        return root, status

    def test_frozen_heartbeat_and_dead_process_are_recovered(self):
        with tempfile.TemporaryDirectory() as d:
            root, status = self.fixture(d)
            with patch.object(autonomy, "HERE", Path(d)), patch.object(autonomy, "trainer_alive", return_value=True):
                self.assertEqual(autonomy.verdict("main", now=status.stat().st_mtime + 901), "stale")
                self.assertEqual(autonomy.verdict("main", now=status.stat().st_mtime + 10), "ok")
            with patch.object(autonomy, "HERE", Path(d)), patch.object(autonomy, "trainer_alive", return_value=False):
                self.assertEqual(autonomy.verdict("main"), "dead")

    def test_step_target_extends_only_for_explicitly_autonomous_runs(self):
        with tempfile.TemporaryDirectory() as d:
            root, _ = self.fixture(d, state="stopped", stop_reason="complete")
            config = root / "config.yaml"
            config.write_text("total_steps: 100\nseed: 7\n")
            with patch.object(autonomy, "HERE", Path(d)):
                self.assertEqual(autonomy.verdict("main"), "stopped")
                autonomy.extend("main", str(config))
                self.assertEqual(config.read_text(), "total_steps: 100\nseed: 7\n")
                (root / "AUTONOMOUS").touch()
                self.assertEqual(autonomy.verdict("main"), "complete")
                autonomy.extend("main", str(config))
                import yaml
                self.assertEqual(yaml.safe_load(config.read_text()), dict(total_steps=20000100, seed=7))
                (root / "STOP").touch()
                autonomy.extend("main", str(config))
                self.assertEqual(yaml.safe_load(config.read_text())["total_steps"], 20000100)

    def test_reused_pid_is_not_a_trainer(self):
        from types import SimpleNamespace
        with patch("autonomy.subprocess.run", return_value=SimpleNamespace(stdout="/usr/bin/some-app main")):
            self.assertFalse(autonomy.trainer_alive(123, "main"))

    def test_stale_recovery_resumes_after_graceful_exit_and_respects_operator_stop(self):
        with tempfile.TemporaryDirectory() as d:
            root, _ = self.fixture(d)
            with patch.object(autonomy, "HERE", Path(d)), \
                    patch.object(autonomy, "verdict", return_value="stale"), \
                    patch.object(autonomy, "trainer_alive", return_value=False), \
                    patch("autonomy.os.kill") as kill:
                self.assertTrue(autonomy.recover_stale("main"))
                kill.assert_called_once_with(123, __import__('signal').SIGTERM)
                (root / "OPERATOR_STOP").touch()
                kill.reset_mock()
                self.assertFalse(autonomy.recover_stale("main"))
                kill.assert_not_called()

    def test_mac_service_is_per_user_persistent_and_preserves_training_config(self):
        import plistlib
        import yaml
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as d:
            root, _ = self.fixture(d, state="stopped")
            (root / "latest.pt").write_bytes(b"saved weights")
            (root / "config.yaml").write_text("total_steps: 20000000\nseed: 17\ndisk_floor_mb: 400\n")
            (root / "STOP").touch()
            (root / "OPERATOR_STOP").touch()
            with patch.object(autonomy, "HERE", Path(d)), \
                    patch("autonomy.sys.platform", "darwin"), \
                    patch("autonomy.Path.home", return_value=Path(d) / "home"), \
                    patch.object(autonomy, "trainer_alive", return_value=False), \
                    patch("autonomy.subprocess.run", return_value=SimpleNamespace(returncode=0)) as run:
                autonomy.install("main")
            cfg = yaml.safe_load((root / "config.yaml").read_text())
            self.assertEqual(cfg["seed"], 17)
            self.assertEqual(cfg["total_steps"], 20000000)
            self.assertEqual(cfg["disk_floor_mb"], 500)
            self.assertFalse((root / "OPERATOR_STOP").exists())
            self.assertTrue((root / "AUTONOMOUS").exists())
            plist = plistlib.loads((Path(d) / "home/Library/LaunchAgents/com.mcf.rlm-training.plist").read_bytes())
            self.assertTrue(plist["KeepAlive"])
            self.assertTrue(plist["RunAtLoad"])
            self.assertEqual(plist["ProgramArguments"][-3:], ["service", "main", str(root / "config.yaml")])
            commands = [call.args[0] for call in run.call_args_list]
            self.assertTrue(any("resume" in cmd for cmd in commands))
            self.assertTrue(any(cmd[:2] == ["launchctl", "bootstrap"] for cmd in commands))
            self.assertFalse(any("sudo" in cmd for cmd in commands))

    def test_bootstrap_updates_existing_checkout_and_preserves_checkpoint(self):
        script = Path(__file__).parent / "tools/enable_autonomy.sh"
        with tempfile.TemporaryDirectory() as d:
            project = Path(d)
            (project / "rl").mkdir()
            (project / ".gitignore").write_text("rl/runs/\nrl/.env\n")
            (project / "rl/run.sh").write_text('''#!/bin/bash
case "$1" in
stop) touch "rl/runs/$2/STOP";;
alive) exit 1;;
autonomous)
touch "rl/runs/$2/autonomy-installed"
"$MCF_RL_PYTHON" - "$2" <<'PY'
import json, pathlib, subprocess, sys
root = pathlib.Path('rl/runs') / sys.argv[1]
worker = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
(root / 'status.json').write_text(json.dumps(dict(state='running', pid=worker.pid, step=11)))
PY
;;
dashboard) exit 0;;
*) exit 2;;
esac
''')
            (project / "rl/resources.py").write_text((Path(__file__).parent / "resources.py").read_text())
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=project, stderr=subprocess.DEVNULL).decode().strip()
            git("init", "-b", "main")
            git("config", "user.email", "test@example.invalid")
            git("config", "user.name", "Autonomy regression")
            git("add", ".")
            git("commit", "-m", "Old checkout")
            before = git("rev-parse", "HEAD")
            (project / "updated-runtime").write_text("new")
            git("add", ".")
            git("commit", "-m", "Updated runtime")
            target = git("rev-parse", "HEAD")
            git("update-ref", "refs/remotes/origin/main", target)
            git("reset", "--hard", before)
            root = project / "rl/runs/saved"
            root.mkdir(parents=True)
            import torch
            torch.save(dict(global_step=10), root / "latest.pt")
            original = (root / "latest.pt").read_bytes()
            (root / "config.yaml").write_text("seed: 17\n")
            (root / "status.json").write_text(json.dumps(dict(state="stopped", pid=999999)))
            (project / "rl/.env").write_text("VENV='" + str(Path(sys.executable).parent.parent) + "'\n")
            try:
                result = subprocess.run(["bash", str(script)], cwd=project, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('Verified saved: step 10 -> 11', result.stdout)
            finally:
                state = json.loads((root / 'status.json').read_text())
                if state.get('state') == 'running':
                    os.kill(state['pid'], __import__('signal').SIGTERM)
            self.assertEqual(git("rev-parse", "HEAD"), target)
            self.assertEqual((root / "latest.pt").read_bytes(), original)
            self.assertEqual(next(root.glob("pre-upgrade-*.pt")).read_bytes(), original)
            self.assertTrue((root / "autonomy-installed").exists())


if __name__ == "__main__":
    unittest.main()
