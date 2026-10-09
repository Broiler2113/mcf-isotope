"""Bounded cleanup of RLM-owned diagnostic logs. Never removes models or replays.

This module has no torch dependency, so the supervisor can run it while the trainer
is stopped. Disk blocks, not logical file length, measure the space actually freed.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import stat

MIB = 1024 * 1024
PROJECT = Path(__file__).resolve().parent.parent


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
    args = parser.parse_args()
    print(json.dumps(trim_owned_logs(args.runs, pressure=args.pressure,
                                    home=Path.home()), indent=2))


if __name__ == "__main__":
    main()
