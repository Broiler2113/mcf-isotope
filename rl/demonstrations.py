"""Validated .mcfr -> sparse imitation examples. Uploaded files never contain Python objects.

python rl/demonstrations.py import match.mcfr --dataset rl/demonstrations
Whole matches are assigned to train/holdout by content hash, before extraction.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile
import time

import numpy as np
from features import Sparse, N_CHANNELS, CAND_DIM, FLAT_DIM
from mcf_env import PROJECT, refresh_class_cache

SCHEMA = 1
CHUNK = 64


def write_chunk(path, samples):
    arrays = {"count": np.asarray(len(samples))}
    for n, (g, f, c, cells, action) in enumerate(samples):
        for label, value in (("g", g), ("c", c)):
            arrays[f"{n}{label}i"] = value.idx
            arrays[f"{n}{label}v"] = value.val
            arrays[f"{n}{label}s"] = np.asarray(value.shape)
        arrays[f"{n}f"], arrays[f"{n}cells"] = f, cells
        arrays[f"{n}a"] = np.asarray(action)
    np.savez_compressed(path, **arrays)


def read_chunk(path):
    from train import Step
    samples = []
    with np.load(path, allow_pickle=False) as data:
        for n in range(int(data["count"])):
            sparse = []
            for label in ("g", "c"):
                s = Sparse.__new__(Sparse)
                s.idx, s.val = data[f"{n}{label}i"], data[f"{n}{label}v"]
                s.shape = tuple(int(v) for v in data[f"{n}{label}s"])
                sparse.append(s)
            samples.append(Step(sparse[0], data[f"{n}f"], sparse[1], data[f"{n}cells"],
                                int(data[f"{n}a"]), 0.0, 0.0))
    return samples


def import_replay(source, dataset, godot="godot", round_cap=40):
    from train import encode
    source, dataset = Path(source), Path(dataset)
    if source.stat().st_size > 50 * 1024**2:
        raise ValueError("replay exceeds 50 MB")
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    final = dataset / digest
    if (final / "manifest.json").is_file():
        return json.loads((final / "manifest.json").read_text())
    dataset.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(dataset).free < 1536 * 1024**2:
        raise ValueError("replay import needs at least 1.5 GB free disk space")
    refresh_class_cache(godot)
    with tempfile.TemporaryDirectory(prefix=".import-", dir=dataset) as staging:
        staging = Path(staging)
        raw = staging / "samples.jsonl"
        proc = subprocess.run([godot, "--headless", "--path", PROJECT, "--script",
                               "res://rl/tools/export_demonstration.gd", "--", str(source.resolve()),
                               str(raw.resolve()), str(round_cap)], capture_output=True, text=True,
                              timeout=1800)
        if proc.returncode:
            raise ValueError("Replay validation failed: " + (proc.stderr + proc.stdout)[-2000:])
        report = next((json.loads(line) for line in reversed(proc.stdout.splitlines())
                       if line.startswith('{"samples"')), {})
        samples, count, chunks = [], 0, []
        with raw.open() as f:
            for line in f:
                row = json.loads(line)
                if not 0 <= row["action"] < len(row["legal"]):
                    raise ValueError("demonstrated action missing from candidates")
                samples.append((*encode(row), row["action"]))
                count += 1
                if len(samples) == CHUNK:
                    name = f"part-{len(chunks):05d}.npz"
                    write_chunk(staging / name, samples)
                    chunks.append(name); samples = []
        if samples:
            name = f"part-{len(chunks):05d}.npz"
            write_chunk(staging / name, samples); chunks.append(name)
        if not count:
            raise ValueError("no supported human actions in replay")
        raw.unlink()
        code = subprocess.check_output(["git", "-C", PROJECT, "rev-parse", "HEAD"], text=True).strip()
        manifest = dict(schema=SCHEMA, sha256=digest, samples=count, chunks=chunks,
                        split="holdout" if int(digest[:8], 16) % 10 == 0 else "train",
                        code=code, round_cap=round_cap, channels=N_CHANNELS, candidate_dim=CAND_DIM,
                        flat_dim=FLAT_DIM, imported_at=time.time(), source=source.name,
                        actions=report.get("actions"), skipped=report.get("skipped"))
        (staging / "manifest.json").write_text(json.dumps(manifest, indent=2))
        # Publication is atomic: a trainer can only see fully validated matches.
        try:
            os.rename(staging, final)
        except OSError:
            if not (final / "manifest.json").exists():
                raise
        return manifest


class ReplayDataset:
    """Equal weight per match; keep only one sparse shard in memory."""
    def __init__(self, root, split="train", seed=1):
        self.root = Path(root)
        self.split = split
        self.rng = random.Random(seed)
        self.matches = []
        self.cache_path = None
        self.cache = []
        self.bad = set()
        self.next_refresh = 0.0

    def refresh(self):
        if time.monotonic() < self.next_refresh:
            return
        self.next_refresh = time.monotonic() + 30
        matches = []
        for path in sorted(self.root.glob("*/manifest.json")):
            try:
                m = json.loads(path.read_text())
                if (m["schema"] == SCHEMA and m["split"] == self.split and
                    m["channels"] == N_CHANNELS and m["candidate_dim"] == CAND_DIM and
                    m["flat_dim"] == FLAT_DIM and m["chunks"]):
                    matches.append((path.parent, m))
            except (OSError, ValueError, KeyError):
                continue
        self.matches = matches

    def sample(self, count):
        self.refresh()
        if not self.matches:
            return []
        root, manifest = self.rng.choice(self.matches)
        path = root / self.rng.choice(manifest["chunks"])
        if path in self.bad:
            return []
        if self.cache_path != path:
            try:
                self.cache, self.cache_path = read_chunk(path), path
            except (OSError, ValueError, KeyError) as error:
                self.bad.add(path)
                print(f"[demonstrations] skipping unreadable shard {path}: {error}", flush=True)
                return []
        first = self.rng.choice(self.cache)
        same = [s for s in self.cache if s.grid.shape == first.grid.shape]
        return [first] + self.rng.choices(same, k=count - 1)


def import_queue(dataset, godot="godot", round_cap=40):
    import fcntl
    queue = Path(dataset) / "uploads"
    queue.mkdir(parents=True, exist_ok=True)
    with (queue / "worker.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        while True:
            pending = [p for p in sorted(queue.glob("*.mcfr"))
                       if not Path(str(p) + ".status.json").exists()]
            if not pending:
                return
            for source in pending:
                try:
                    manifest = import_replay(source, dataset, godot, round_cap)
                    status = dict(state="accepted", samples=manifest["samples"], split=manifest["split"])
                except Exception as error:
                    status = dict(state="rejected", error=str(error))
                Path(str(source) + ".status.json").write_text(json.dumps(status, indent=2))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("command", choices=["import", "worker"])
    p.add_argument("replay", nargs="?")
    p.add_argument("--dataset", default=os.path.join(PROJECT, "rl", "demonstrations"))
    p.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    p.add_argument("--round-cap", type=int, default=40)
    a = p.parse_args()
    if a.command == "worker":
        import_queue(a.dataset, a.godot, a.round_cap)
    else:
        if not a.replay:
            p.error("import requires a replay path")
        print(json.dumps(import_replay(a.replay, a.dataset, a.godot, a.round_cap), indent=2))

if __name__ == "__main__":
    main()
