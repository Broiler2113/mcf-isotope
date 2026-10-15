"""Bounded cleanup of generated RLM artifacts, preserving resumable model state.

This module has no torch dependency, so the supervisor can run it while the trainer
is stopped. Disk blocks, not logical file length, measure the space actually freed.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import stat
import time

import fcntl

MIB = 1024 * 1024
PROJECT = Path(__file__).resolve().parent.parent


def disk_free_mb(path: Path) -> float:
    return shutil.disk_usage(path).free / MIB


def safe_regular(path: Path, root: Path) -> bool:
    """Never traverse a symlink or cross onto a different filesystem during cleanup."""
    try:
        path.relative_to(root)
        return (not any(p.is_symlink() for p in (path, *path.parents))
                and stat.S_ISREG(path.lstat().st_mode)
                and path.stat().st_dev == root.stat().st_dev)
    except (OSError, ValueError):
        return False


def read_config(branch: Path) -> dict | None:
    try:
        import yaml
        result = yaml.safe_load((branch / "config.yaml").read_text())
        return result if isinstance(result, dict) else None
    except Exception:
        # A config may be replaced while a trainer starts. Keep every model when
        # its pool cannot be established, rather than guess a smaller pool.
        return None


def disposable_artifacts(runs: Path):
    """Oldest generated files first; retain resume/best/seed models and league pool.

    Active replay windows and the current TensorBoard file are excluded. Unknown
    files, demonstrations, configs, evaluation histories and manual exports stay.
    Milestone checkpoints may be discarded under pressure; latest/best never are.
    """
    branches = [runs] if (runs / "config.yaml").exists() else [
        p for p in runs.iterdir() if p.is_dir() and not p.is_symlink()
        and ((p / "config.yaml").is_file() or (p / "latest.pt").is_file())]
    candidates = []
    for branch in branches:
        if branch.is_symlink():
            continue
        cfg = read_config(branch)
        checkpoints = sorted(p for p in branch.glob("ckpt_*.pt")
                             if re.fullmatch(r"ckpt_\d+\.pt", p.name))
        size = max(1, int((cfg or {}).get("pool_size", 6)))
        protected = set(checkpoints[-max(2, size):])
        older = checkpoints[:-size]
        count = min(len(older), max(0, int((cfg or {}).get("pool_archive_size", 0))))
        # Same evenly spaced archive selection as Trainer.pool_checkpoints().
        for i in range(count):
            protected.add(older[int(i * (len(older) - 1) / max(1, count - 1))])
        backups = sorted(p for p in branch.glob("pre-upgrade-*.pt")
                         if re.fullmatch(r"pre-upgrade-\d{8}T\d{6}Z\.pt", p.name))
        champions = sorted(p for p in branch.glob("champion_*.pt")
                           if re.fullmatch(r"champion_\d+\.pt", p.name))
        for path in (checkpoints if cfg is not None else []) + backups[:-1] + champions[:-1]:
            if path not in protected:
                candidates.append((2, path))
                candidates.append((2, Path(str(path) + ".json")))
        replays = branch / "replays"
        if replays.is_dir() and not replays.is_symlink():
            for pattern in ("checkpoint_*", "train_*"):
                groups = sorted(p for p in replays.glob(pattern)
                                if re.fullmatch(r"(?:train|checkpoint)_\d+", p.name))
                for group in groups[:-1]:
                    if group.is_dir() and not group.is_symlink():
                        candidates.extend((0, p) for p in group.iterdir()
                                          if p.suffix in (".mcfr", ".json"))
            wins = replays / "wins"
            if wins.is_dir() and not wins.is_symlink():
                for path in sorted(wins.glob("*.mcfr"))[:-10]:
                    candidates.extend([(0, path), (0, Path(str(path) + ".json"))])
        tb = branch / "tb"
        if tb.is_dir() and not tb.is_symlink():
            candidates.extend((1, p) for p in sorted(tb.glob("events.out.tfevents.*"),
                              key=lambda p: p.stat().st_mtime)[:-1])
        # Partial saves left by a crash; the age guard excludes in-flight writes.
        try:
            status = json.loads((branch / "status.json").read_text())
            os.kill(int(status["pid"]), 0)
        except (OSError, ValueError, KeyError):
            candidates.extend((1, p) for p in branch.glob("*.pt.tmp"))
    safe = [(priority, p) for priority, p in candidates if safe_regular(p, runs)]
    return [p for _, p in sorted(safe, key=lambda row: (row[0], row[1].stat().st_mtime))]


def maintain_storage(runs: str | Path, floor_mb: float = 500,
                     trigger_mb: float = 1024, target_mb: float = 2048,
                     required_mb: float = 0, max_log_mb: float = 64,
                     home: Path | None = None, protect=()) -> dict:
    """Clean proactively with hysteresis, and reserve room for the next atomic save.

    The minimum is a free-space floor, not a run-size quota. If unrelated disk use
    leaves insufficient reclaimable data, callers must wait rather than cross it.
    A shared nonblocking lock serializes trainer/supervisor cleanup.
    """
    runs = Path(os.path.abspath(runs))
    minimum = max(0, floor_mb) + max(0, required_mb)
    trigger = max(trigger_mb, minimum + 512)
    target = max(target_mb, trigger + 512)
    free = disk_free_mb(runs)
    report = dict(reclaimed_mb=0.0, files=0, deleted=0, errors=[],
                  free_mb=round(free, 1), floor_mb=floor_mb, ready=free >= minimum)
    if runs.is_symlink() or any(p.is_symlink() for p in runs.parents):
        report["errors"].append("cleanup root traverses a symlink")
        return report
    try:
        fd = os.open(runs / ".cleanup.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "r+") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return report
            logs = trim_owned_logs(runs, max_mb=max_log_mb, pressure=free < trigger, home=home)
            report.update(logs)
            protected = {Path(os.path.abspath(p)) for p in protect}
            if disk_free_mb(runs) < trigger:
                for path in disposable_artifacts(runs):
                    if disk_free_mb(runs) >= target:
                        break
                    # Recent artifacts may still be serving an evaluator or player.
                    if path in protected or not safe_regular(path, runs):
                        continue
                    try:
                        if time.time() - path.stat().st_mtime < 600:
                            continue
                        before = allocated(path)
                        path.unlink()
                        group = path.parent
                        if group.parent.name == "replays" and group.name.startswith(("train_", "checkpoint_")):
                            try:
                                group.rmdir()  # Only an empty generated replay directory.
                            except OSError:
                                pass
                        report["reclaimed_mb"] += before / MIB
                        report["files"] += 1
                        report["deleted"] += 1
                    except FileNotFoundError:
                        pass
                    except OSError as error:
                        report["errors"].append(f"{path.name}: {error.strerror}")
    except OSError as error:
        report["errors"].append(str(error))
    free = disk_free_mb(runs)
    report.update(free_mb=round(free, 1), ready=free >= minimum,
                  reclaimed_mb=round(report["reclaimed_mb"], 2))
    return report


def allocated(path: Path) -> int:
    info = path.lstat()
    return info.st_blocks * 512


def owned_logs(runs: Path, home: Path | None = None):
    """Only explicit diagnostic locations, without following directory symlinks."""
    if runs.is_symlink():
        return
    yield from runs.glob("*.log")
    yield from runs.glob("*.log.1")
    if not (runs / "envlogs").is_symlink():
        yield from (runs / "envlogs").glob("*.log")
    for branch in runs.iterdir() if runs.exists() else []:
        logs = branch / "envlogs"
        if branch.is_dir() and not branch.is_symlink() and not logs.is_symlink():
            yield from logs.glob("*.log")
    if home is not None:
        logs = home / "Library/Application Support/Godot/app_userdata/MCF Isotope/logs"
        if not any(p.is_symlink() for p in [logs, *logs.parents] if p != home.parent):
            yield from logs.glob("godot*.log")
        yield home / "Library/Logs/mcf-rlm-tunnel.log"


def trim_owned_logs(runs: str | Path, max_mb: float = 64, pressure: bool = False,
                    home: Path | None = None) -> dict:
    """Keep a diagnostic tail in the same inode so active appenders keep working.

    A non-append writer may leave a sparse hole on its next write. Check allocated
    blocks to avoid treating that logical hole as gigabytes of occupied storage.
    """
    limit = max(0, max_mb) * MIB
    report = dict(reclaimed_mb=0.0, files=0, errors=[])
    for path in owned_logs(Path(runs), home):
        try:
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or path.is_symlink():
                continue
            before = info.st_blocks * 512
            if before <= (MIB if pressure else limit):
                continue
            # O_NOFOLLOW also closes the race between the path check and opening it.
            fd = os.open(path, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
            with os.fdopen(fd, "r+b") as log:
                log.seek(0, os.SEEK_END)
                log.seek(max(0, log.tell() - 64 * 1024))
                tail = log.read()
                log.seek(0)
                log.truncate(0)
                log.write(tail)
                log.flush()
            report["reclaimed_mb"] += max(0, before - allocated(path)) / MIB
            report["files"] += 1
        except FileNotFoundError:
            pass
        except OSError as e:
            report["errors"].append(f"{path.name}: {e.strerror}")
    report["reclaimed_mb"] = round(report["reclaimed_mb"], 2)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", default=str(PROJECT / "rl/runs"))
    parser.add_argument("--pressure", action="store_true")
    parser.add_argument("--floor-mb", type=float, default=500)
    parser.add_argument("--target-mb", type=float, default=2048)
    args = parser.parse_args()
    if args.pressure:
        print(json.dumps(trim_owned_logs(args.runs, pressure=True, home=Path.home())))
    else:
        report = maintain_storage(args.runs, floor_mb=args.floor_mb,
                                  target_mb=args.target_mb, required_mb=64, home=Path.home())
        print(json.dumps(report))
        raise SystemExit(0 if report["ready"] else 75)


if __name__ == "__main__":
    main()
