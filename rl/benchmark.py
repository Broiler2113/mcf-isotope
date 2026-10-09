#!/usr/bin/env python
"""Benchmark collection + PPO in temporary runs, without touching a training branch.

Example: python rl/benchmark.py rl/config/tactical.yaml --checkpoint best.pt \
  --variant '{"epochs":2,"lr":0.00004}' --variant '{"epochs":3,"lr":0.00004}'

Each variant starts with identical weights and RNG seeds. Results describe throughput
and update stability, not long-term playing strength. Use fixed-seed evaluations over
longer forks to compare curriculum, gamma and learning rates.
"""
import argparse
import json
import os
import random
import tempfile
import time

import numpy as np
import torch

from mcf_env import VecEnv
from train import Trainer, load_config, pick_device, preflight_config


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("config")
    p.add_argument("--checkpoint")
    p.add_argument("--updates", type=int, default=3)
    p.add_argument("--warmup", type=int, default=1)
    p.add_argument("--variant", action="append", default=[], help="JSON config overrides")
    p.add_argument("--output", help="optional JSON report path")
    a = p.parse_args()
    if a.updates < 1 or a.warmup < 0:
        p.error("updates must be positive and warmup nonnegative")
    cfg = load_config(a.config)
    results = []
    for overrides in [json.loads(v) for v in a.variant] or [{}]:
        settings = cfg | overrides
        seed = int(settings["seed"])
        random.seed(seed); np.random.seed(seed); torch.manual_seed(seed)
        torch.set_num_threads(int(settings.get("torch_threads") or min(4, os.cpu_count() or 1)))
        with tempfile.TemporaryDirectory(prefix="isotope-rl-bench-") as d:
            t = Trainer(d, settings, pick_device(settings))
            try:
                if a.checkpoint:
                    t.load(a.checkpoint, keep_cfg=True)
                # Equal checkpoints and episode seeds for every variant. A temporary
                # pool has only the frozen current policy, not the source run's archive.
                t.envs = VecEnv(settings["n_envs"], settings["godot"], log_dir=os.path.join(d, "envlogs"))
                if settings["preflight"]:
                    preflight_config(settings, t.envs.envs[0])
                measured = []
                for index in range(a.warmup + a.updates):
                    buffers, info = t.collect()
                    start = time.perf_counter()
                    losses = t.ppo_update(buffers)
                    update_secs = time.perf_counter() - start
                    del buffers
                    if index >= a.warmup:
                        measured.append(dict(steps=info["steps"], collect_secs=info["seconds"],
                                             update_secs=update_secs, timings=info["timings"], **losses))
                steps = sum(row["steps"] for row in measured)
                seconds = sum(row["collect_secs"] + row["update_secs"] for row in measured)
                results.append(dict(overrides=overrides, device=t.device, steps=steps,
                                    seconds=seconds, steps_per_sec=steps / max(seconds, 1e-6),
                                    updates=measured, includes_evaluation=False,
                                    source_archive_loaded=False))
            finally:
                if t.envs:
                    t.envs.close()
                t.writer.close()
    report = json.dumps(results, indent=2)
    if a.output:
        with open(a.output, "w") as f:
            f.write(report + "\n")
    print(report)


if __name__ == "__main__":
    main()
