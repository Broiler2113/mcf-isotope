#!/usr/bin/env python
"""RL Enemy AI v1 trainer and launcher (spec Sections 6, 8, 9, 10, 13.1).

    train.py start  <config.yaml> --branch NAME     new run (rl/runs/NAME)
    train.py resume <branch>                          continue from latest checkpoint
    train.py fork   <checkpoint.pt> --branch NAME [--config c.yaml]
    train.py stop   <branch>                          graceful stop after this update
    train.py pause  <branch>                          checkpoint and hold; envs stay up
    train.py continue <branch>                        release a paused run
    train.py status [branch]
    train.py eval   <checkpoint.pt> [--games N] [--record DIR]      greedy games vs HARD
    train.py play   <checkpoint.pt>                   real game, checkpoint in the AI slot
    train.py export <checkpoint.pt> <out.onnx>        policy + value head (Section 12)

Everything a run needs to resume - weights, optimizer, curriculum stage, phase, map
rotation, match counters, RNG - is inside the checkpoint (9.5). Graduation between
phases and growing the map pool are config edits followed by `resume`, never automatic
(8.2). Monitoring is TensorBoard under rl/runs/<branch>/tb (D3).
"""
from __future__ import annotations

import argparse
import copy
import glob
import gc
import json
import os
import random
import shutil
import signal
import subprocess
import sys
import time
import traceback
from pathlib import Path
from collections import Counter, OrderedDict, defaultdict
from dataclasses import dataclass

import numpy as np
import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import torch_compat  # noqa: F401,E402
import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402
from torch.utils.tensorboard import SummaryWriter  # noqa: E402

from features import (CAND_DIM, CANVAS, FLAT_DIM, N_CHANNELS, Sparse, candidate_rows,  # noqa: E402
                      flat_vector, grid_tensor)
from mcf_env import (EXTERNAL, HARD, PROJECT, EnvDied, GodotEnv,  # noqa: E402
                     EpisodeConfig, VecEnv, refresh_class_cache)
from model import OnnxWrapper, PolicyNet, load_compat  # noqa: E402
from resources import trim_owned_logs  # noqa: E402

RUNS = os.path.join(PROJECT, "rl", "runs")
# Never shrink the rollout below this under memory pressure: a handful of transitions
# per update is not training, and at that point the base process is the problem.
MIN_ROLLOUT_MB = 192.0
# The one scripted opponent: AIController HARD, for training (Phase A, and the scripted
# share of Phase B) and for every evaluation. The owner retired NORMAL and EASY outright;
# the game keeps them for human matches, the RL pipeline has no way to select them.
SCRIPTED = "hard"
# Config keys that used to choose the scripted opponent. Dropped from any config a run
# loads — a branch whose saved config still says `opponent: normal` trains vs HARD.
RETIRED_KEYS = ("opponent", "eval_opponents")
FOGS = {"off": 0, "standard": 1, "realistic": 2}
UNIT_NAMES = ["light_infantry", "heavy_infantry", "machinegunner", "sniper", "anti_tank",
              "engineer", "flamethrower", "assault", "marksman", "miner", "sapper",
              "shield_bearer", "drone_operator", "commander", "civilian", "drone",
              "tank", "shuttle", "borg"]

DEFAULTS = dict(
    godot=os.environ.get("GODOT", "godot"),   # rl/.env sets GODOT; a config's godot: overrides
    n_envs=2, maps=["rl/maps/arena_34x26.json"], stage=1,
    phase="A", pool_ai_fraction=0.15, pool_size=6,
    round_cap=10, max_steps=3000, max_candidates=0, max_actors=0,
    civilians=False, random_events=False, fog="standard", friendly_fire=True,
    rollout_steps=256, epochs=4, minibatch=32, lr=3e-4, gamma=0.99, lam=0.95, clip=0.2,
    ent_coef=0.01, vf_coef=0.5, max_grad_norm=0.5, total_steps=20_000_000,
    # Stop an update early once the policy has moved this far (mean KL over an epoch).
    # Without it town-3 ran at KL 0.077 and clipfrac 42% against the usual 0.01 / 10-30%:
    # per-step rewards there are ~1e-4, and normalising advantages by a near-zero standard
    # deviation turns that noise into unit-scale gradients. The result was a policy flung
    # around every update - `shoot` went 2.4% -> 5.3% -> 0.1% while entropy bounced between
    # 4.5 and 6.2 - which reads as "not learning" but is really "learning something new and
    # unrelated each time". 0 disables the check.
    target_kl=0.02,
    checkpoint_every=5, eval_every=10, eval_games=6, replays_per_checkpoint=2,
    map_rotate_matches=5, seed=1, torch_threads=0,
    # --- keeping the machine alive (the trainer runs for weeks, unattended) ---
    keep_checkpoints=12,      # newest N kept on disk; 0 = keep everything
    milestone_every=0,        # also keep every checkpoint at a step multiple of this
    keep_replay_sets=8,       # newest N replays/checkpoint_* directories
    mem_limit_mb=0,           # >0: checkpoint and exit before the OS OOM-kills the run
    # >0: checkpoint and exit while there is still room to write the checkpoint. A disk
    # that fills mid-save leaves a truncated file and then a crash loop, because every
    # restart tries the same failing write. Stopping early is the difference between
    # "stopped: disk floor" in the morning and a branch that died at 4am taking its last
    # checkpoint with it.
    disk_floor_mb=1536,
    disk_cleanup_trigger_mb=1024, log_max_mb=64,
    memory_cleanup_free_mb=1024, gpu_cache_max_mb=1024,
    gpu_memory_restart_mb=6144, resource_check_seconds=10,
    rollout_budget_mb=0,      # >0: end a rollout early once the buffer reaches this
    # --- tactical env (config/tactical.yaml); every default keeps the old behaviour ---
    # Per-map sampling weights, same order as `maps`. Empty = the old fixed rotation.
    map_weights=[],
    # Chance that a fixed map's infantry types are swapped (mirrored for both sides), so the
    # policy meets every unit type instead of the map's one composition.
    army_shuffle=0.0,
    # The per-action bonuses (R_SHOT, R_VEHICLE) taught a novice that shooting and driving
    # pay at all. A strong policy should play for the outcome: the bonus scale falls
    # linearly from 1 to shaping_floor over shaping_decay_updates updates (0 = never).
    shaping_decay_updates=0, shaping_floor=0.0, shaping_decay_start=0,
    # Weight of the position potential (env_server._phi): fire concentrated on visible
    # enemies minus enemy fire on us. Potential-based, so the optimal policy is unchanged.
    potential_coef=0.0,
    # HARD's play styles in TRAINING games vs the scripted AI: weights for
    # [standard, rush, turtle, flank]. Evaluation always plays standard HARD.
    opponent_styles=[1.0, 0.0, 0.0, 0.0],
    # Prioritised fictitious self-play (phase "league"): a pool member that beats us more
    # often is picked more often — weight (1 - our win rate vs it)^pfsp_power + pfsp_floor.
    pfsp_power=2.0, pfsp_floor=0.05,
    # Skill drills evaluated vs standard HARD at every evaluation, `drill_eval_games` each,
    # on top of the main eval. Read per drill on the dashboard (eval/drill_<map>_winrate).
    drill_eval_maps=[], drill_eval_games=2,
    # Share of TRAINING games played with fog off (full information). Human players often
    # play without fog, and HARD sees through it regardless; a policy that only ever played
    # in fog never learns to read a whole board. The rest use `fog`.
    fog_off_share=0.0,
    # Extra evaluation games vs HARD with fog OFF on eval_maps (eval/*_hard_nofog). The main
    # evaluation keeps `fog`, so its history stays comparable.
    eval_nofog_games=0,
    eval_seed=900_000, eval_full_every=0,  # 0: full suite at every eval
    heldout_eval_maps=[], heldout_eval_games=0, heldout_round_cap=40,
    preflight=True, pool_archive_size=3,
)

STYLE_NAMES = ["standard", "rush", "turtle", "flank"]


class ResourceRecycle(RuntimeError):
    """Resume the same checkpoint in a fresh process to release Metal/framework memory."""


def map_name(path: str) -> str:
    """Display/tag name of a map: the file name, or the generator spec with ':' made
    tag-safe ("gen:any:0:12:1" -> "gen_any_0_12_1")."""
    return os.path.basename(path).replace(":", "_")


def is_generated(m: str) -> bool:
    return str(m).startswith("gen:")


def load_config(path: str | None) -> dict:
    cfg = dict(DEFAULTS)
    if path:
        with open(path) as f:
            cfg.update(yaml.safe_load(f) or {})
    # eval_maps gets the SAME treatment as maps, and it was missing it. The trainer runs
    # with cwd=rl/, so a relative "rl/maps/x.json" resolves to rl/rl/maps/x.json — which
    # does not exist. It only appeared to work because the path is handed to Godot, which
    # resolves it against the project root instead; the evaluations were correct by luck,
    # not by construction, and the same config would have failed the instant anything on
    # the Python side tried to open the file.
    for key in ("maps", "eval_maps", "drill_eval_maps", "heldout_eval_maps"):
        if not cfg.get(key):
            continue
        # "gen:<style>:<size>:<units>:<tanks>" is a map the env builds per episode (MapGen);
        # there is no file to resolve or check.
        cfg[key] = [m if is_generated(m) or os.path.isabs(m) else os.path.join(PROJECT, m)
                    for m in cfg[key]]
        for m in cfg[key]:
            if not is_generated(m) and not os.path.exists(m):
                sys.exit(f"map not found ({key}): {m}")
    if cfg.get("map_weights") and len(cfg["map_weights"]) != len(cfg["maps"]):
        sys.exit("map_weights must have one weight per map")
    weights = cfg.get("map_weights") or []
    if weights and (any(not np.isfinite(w) or w < 0 for w in weights) or sum(weights) <= 0):
        raise ValueError("map_weights must be finite, nonnegative, and have a positive sum")
    for key in ("n_envs", "rollout_steps", "epochs", "minibatch", "checkpoint_every", "eval_every"):
        if int(cfg[key]) <= 0:
            raise ValueError(f"{key} must be positive")
    if cfg["eval_full_every"] and cfg["eval_full_every"] % cfg["eval_every"]:
        raise ValueError("eval_full_every must be a multiple of eval_every")
    if not 0 < cfg["gamma"] <= 1 or not 0 <= cfg["lam"] <= 1:
        raise ValueError("gamma must be in (0, 1] and lam in [0, 1]")
    return with_defaults(cfg)


def with_defaults(cfg: dict) -> dict:
    """A config read out of an old checkpoint predates keys added since. Fill them in
    rather than sprinkling .get() over the trainer — and drop the retired ones."""
    out = dict(DEFAULTS) | dict(cfg or {})
    for k in RETIRED_KEYS:
        out.pop(k, None)
    return out


def preflight_config(cfg: dict, env: GodotEnv) -> list[dict]:
    """Reset and encode every configured scenario before any optimizer update.

    Generated `any` maps exercise every style at the configured upper army size.
    This catches protocol, rules, canvas and feature incompatibilities in one place.
    """
    maps = list(dict.fromkeys(m for key in ("maps", "eval_maps", "drill_eval_maps", "heldout_eval_maps")
                             for m in cfg.get(key, [])))
    cases = []
    for mp in maps:
        if not is_generated(mp):
            cases.append(mp)
            continue
        parts = mp.split(":")
        if len(parts) != 5 or parts[1] not in ("any", "0", "1", "2", "3", "4"):
            raise ValueError(f"invalid generated map specification: {mp}")
        for style in range(5) if parts[1] == "any" else [int(parts[1])]:
            cases.append(":".join(["gen", str(style), parts[2],
                                   parts[3].split("-")[-1], parts[4].split("-")[-1]]))
    rows = []
    for mp in cases:
        print(f"[preflight] {mp}", flush=True)
        ec = EpisodeConfig(map_path=mp, seed=int(cfg["seed"]) * 1000, opponent=HARD,
                           max_actors=cfg["max_actors"], max_candidates=cfg["max_candidates"],
                           fog=FOGS[cfg["fog"]], round_cap=cfg["round_cap"],
                           disembark=disembark_allowed(cfg, mp))
        r = env.reset(ec)
        if r.get("done") or not r.get("legal"):
            raise ValueError(f"preflight: {mp} has no playable opening")
        encode(r)
        rows.append(dict(map=mp, width=r["obs"]["w"], height=r["obs"]["h"],
                         candidates=len(r["legal"])))
    env.last = None
    return rows


def mem_report() -> dict:
    """What this run is costing the machine: the trainer, its Godot children, and how
    much the box has left. psutil is the accurate path; without it fall back to peak
    RSS from resource(), which never falls and so only ever over-reports."""
    try:
        import psutil
        me = psutil.Process()
        own = me.memory_info().rss
        kids = 0
        for c in me.children(recursive=True):
            try:
                kids += c.memory_info().rss
            except psutil.Error:
                pass
        vm = psutil.virtual_memory()
        return dict(rss_mb=own / 2**20, envs_mb=kids / 2**20,
                    total_mb=(own + kids) / 2**20, free_mb=vm.available / 2**20,
                    machine_pct=vm.percent)
    except Exception:
        try:
            import resource
            peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
            peak = peak / 2**20 if sys.platform == "darwin" else peak / 1024
            return dict(rss_mb=peak, total_mb=peak, peak_only=True)
        except Exception:
            return {}


def free_mb(path: str) -> float:
    """Free space on the volume holding `path`."""
    try:
        return shutil.disk_usage(path).free / 2**20
    except OSError:
        return float("inf")


def dir_mb(path: str) -> float:
    """Megabytes the directory actually OCCUPIES, counted in allocated blocks.

    st_size is the wrong question here. The Godot env logs are truncated in place while
    their writers hold an open file offset, which leaves holes: the files are sparse, and
    summing st_size reported this run directory as 6692 MB when `du` said 159 MB — a 42x
    overstatement, shown on the dashboard's disk panel where it reads as a run about to
    fill the machine. st_blocks is what the filesystem has really handed out.
    """
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.stat(os.path.join(root, f)).st_blocks * 512
            except OSError:
                pass
    return total / (1024 * 1024)


# --- rollout storage --------------------------------------------------------------------

@dataclass
class Step:
    grid: Sparse          # (N_CHANNELS, CANVAS, CANVAS)
    flat: np.ndarray
    cand: Sparse          # (n_candidates, CAND_DIM)
    cells: np.ndarray
    action: int
    logp: float
    value: float
    reward: float = 0.0
    done: bool = False

    @property
    def nbytes(self) -> int:
        return self.grid.nbytes + self.cand.nbytes + self.flat.nbytes + self.cells.nbytes


def collate(steps: list[Step], device):
    """Rebuild the dense batch from the sparse buffer. One batch is alive at a time,
    which is the whole point: the rollout itself never holds a dense grid (see Sparse)."""
    B = len(steps)
    n = max(s.cand.shape[0] for s in steps)
    shape = steps[0].grid.shape
    if any(s.grid.shape != shape for s in steps):
        raise ValueError("batch mixes different policy canvas sizes")
    grid = np.zeros((B, *shape), dtype=np.float32)
    cand = np.zeros((B, n, CAND_DIM), dtype=np.float32)
    cells = np.full((B, n, 2), -1, dtype=np.int64)
    mask = np.zeros((B, n), dtype=bool)
    for i, s in enumerate(steps):
        s.grid.dense(grid[i])
        k = s.cand.shape[0]
        s.cand.dense(cand[i, :k])
        cells[i, :k] = s.cells
        mask[i, :k] = True
    flat = np.stack([s.flat for s in steps])
    return (torch.from_numpy(grid).to(device), torch.from_numpy(flat).to(device),
            torch.from_numpy(cand).to(device), torch.from_numpy(cells).to(device),
            torch.from_numpy(mask).to(device))


def encode(resp: dict, canvas: int = CANVAS) -> tuple[Sparse, np.ndarray, Sparse, np.ndarray]:
    obs = resp["obs"]
    g = Sparse(grid_tensor(obs, canvas))
    f = flat_vector(obs)
    c, cells = candidate_rows(obs, resp["legal"], canvas)
    return g, f, Sparse(c), cells.astype(np.int32)


def choose(net: PolicyNet, encoded: list, device, greedy=False):
    steps = [Step(g, f, c, cl, 0, 0.0, 0.0) for g, f, c, cl in encoded]
    batch = collate(steps, device)
    a, lp, v = net.act(*batch, greedy=greedy)
    return a.cpu().numpy(), lp.cpu().numpy(), v.cpu().numpy()


# --- trainer ---------------------------------------------------------------------------

def disembark_allowed(cfg: dict, map_path: str) -> bool:
    """False on maps that seal crews into their hulls.

    Driven by a config list of filename substrings rather than a global flag, because a
    pool mixes map kinds: the tank map is the whole point of the ban, and applying it to
    the platoon map would quietly change what every other map trains. Matching on the
    filename keeps the rule visible in the config instead of buried in the map JSON.
    """
    needles = cfg.get("sealed_crew_maps") or []
    base = os.path.basename(map_path)
    return not any(str(n) in base for n in needles)


class Trainer:
    def __init__(self, run_dir: str, cfg: dict, device="cpu"):
        self.run_dir = run_dir
        self.cfg = with_defaults(cfg)
        self.device = device
        # The game rules this process trains on: the env servers load the checkout as it was
        # at start, and a later pull changes nothing until a restart. tactical-1 trained for a
        # day on rules two merges behind main without anyone seeing it; the dashboard now
        # compares this commit with the checkout and with origin/main.
        self.code = game_version(PROJECT)
        os.makedirs(run_dir, exist_ok=True)
        self.net = PolicyNet().to(device)
        self.opt = torch.optim.Adam(self.net.parameters(), lr=self.cfg["lr"], eps=1e-5)
        # Rollouts and evaluation always decide on the CPU: forwards of a few states at a
        # time between env replies, where a GPU's launch/sync cost loses. With the update
        # on a GPU (`device`), this is a CPU copy synced after every update.
        self.act_net = self.net if device == "cpu" else copy.deepcopy(self.net).cpu()
        # Rollout forwards share the CPU with n_envs Godot processes, so they get the cores
        # those leave free (every core, with OpenMP workers spin-waiting between forwards,
        # starves the envs); the update has the machine to itself.
        self.update_threads = self.cfg.get("torch_threads") or torch.get_num_threads()
        self.act_threads = max(1, min(self.update_threads,
                                      (os.cpu_count() or 2) - self.cfg["n_envs"]))
        self.global_step = 0
        self.update = 0
        self.matches_done = 0
        self.map_idx = 0
        # Maps that already have a rollout replay in the current checkpoint window.
        self._replay_maps: set[str] = set()
        self.parent = None
        self.rng = random.Random(self.cfg["seed"])
        self.writer = SummaryWriter(os.path.join(run_dir, "tb"))
        self.envs: VecEnv | None = None
        self.stop_requested = False
        # Why this process ended: "" (operator stop / total_steps), "memory" or "disk".
        # The supervisor resumes a resource stop and leaves an operator stop alone.
        self.stop_reason = ""
        # Ordered so the least recently used frozen opponent is the one evicted: one
        # PolicyNet per pool member is a few MB, and an unbounded dict grew without end.
        self.pool_cache: OrderedDict[str, PolicyNet] = OrderedDict()
        self.episode_seed = self.cfg["seed"] * 1000
        self._tac_kinds: dict[str, set] = {}
        # League bookkeeping: pool member -> [games, trainee wins] (phase "league").
        self.pfsp: dict[str, list[int]] = {}
        self._last_status = 0.0
        self.last_eval: dict = {}
        self.champion_score = (-1.0, -1e30)
        # Live, shrinkable copy of the configured cap, plus the memory the process costs
        # with no rollout held (measured after each update drops the buffer).
        self.rollout_budget_mb = float(self.cfg["rollout_budget_mb"]) or float("inf")
        self._base_mb = 0.0
        self._disk = (0.0, 0.0)          # (measured at, MB)
        self._resource_check_at = 0.0
        self._resource_restart = False
        self.resource_cleanup = {}

    def has_eval_history(self) -> bool:
        p = os.path.join(self.run_dir, "eval_log.jsonl")
        return os.path.exists(p) and os.path.getsize(p) > 0

    def next_eval_update(self) -> int:
        n = max(1, int(self.cfg["eval_every"]))
        return self.update + (n - self.update % n)

    def disk_mb(self) -> float:
        """Walking the run directory on every 3-second heartbeat would be silly; once a
        minute is plenty for a number that moves when a checkpoint lands."""
        now = time.time()
        if now - self._disk[0] > 60:
            self._disk = (now, round(dir_mb(self.run_dir), 1))
        return self._disk[1]

    # -- checkpoints (9.5) --
    def state_dict(self) -> dict:
        state = dict(model=self.net.state_dict(), opt=self.opt.state_dict(), cfg=self.cfg,
                    global_step=self.global_step, update=self.update,
                    matches_done=self.matches_done, map_idx=self.map_idx,
                    parent=self.parent, rng=self.rng.getstate(),
                    episode_seed=self.episode_seed, branch=os.path.basename(self.run_dir),
                    pfsp=self.pfsp, champion_score=self.champion_score, saved_at=time.time(),
                    torch_rng=torch.get_rng_state(), numpy_rng=np.random.get_state())
        if self.device == "mps":
            state["mps_rng"] = torch.mps.get_rng_state()
        return state

    def save(self, tag: str | None = None) -> str:
        path = os.path.join(self.run_dir, f"ckpt_{self.global_step:09d}.pt" if tag is None else tag)
        tmp = path + ".tmp"
        sd = self.state_dict()
        torch.save(sd, tmp)
        os.replace(tmp, path)          # never leave a half-written checkpoint behind
        latest = os.path.join(self.run_dir, "latest.pt")
        torch.save(sd, latest + ".tmp")
        os.replace(latest + ".tmp", latest)
        # Sidecar for the dashboard (11.4): everything but the weights, readable without torch.
        meta = {k: v for k, v in sd.items()
                if k not in ("model", "opt", "rng", "torch_rng", "numpy_rng", "mps_rng")}
        with open(path + ".json", "w") as f:
            json.dump(meta, f)
        self.prune()
        return path

    # -- retention: a run left alone for a month must not fill the disk --
    def prune(self) -> None:
        """Drop old checkpoints and old replay sets.

        A checkpoint is 4 MB and one lands every `checkpoint_every` updates, so an
        unattended branch writes a few hundred MB a day — on the VPS that is the thing
        that fills up first. Kept: the newest `keep_checkpoints`, every milestone, and
        never fewer than the Phase B pool draws from, because pool_checkpoints() reads
        these same files. The sidecar .json follows its checkpoint out.
        """
        keep_n = int(self.cfg["keep_checkpoints"])
        if keep_n > 0:
            keep_n = max(keep_n, self.cfg["pool_size"] + 1)
            every = int(self.cfg["milestone_every"])
            cks = sorted(glob.glob(os.path.join(self.run_dir, "ckpt_*.pt")))
            # First saved checkpoint in each crossed interval. Exact divisibility
            # almost never happens with variable rollout lengths.
            milestones = {}
            for path in cks:
                try:
                    bucket = int(os.path.basename(path)[5:-3]) // every if every > 0 else 0
                    if bucket > 0:
                        milestones.setdefault(bucket, path)
                except ValueError:
                    pass
            for path in cks[:-keep_n]:
                try:
                    step = int(os.path.basename(path)[5:-3])
                except ValueError:
                    continue
                if path in milestones.values():
                    continue
                for p in (path, path + ".json"):
                    try:
                        os.remove(p)
                    except OSError:
                        pass
        # Только наборы чекпойнтов. replays/wins/ намеренно вне этого glob'а: победы
        # не устаревают, их там единицы, и удалять их по возрасту нечего.
        keep_r = int(self.cfg["keep_replay_sets"])
        if keep_r > 0:
            sets = sorted(glob.glob(os.path.join(self.run_dir, "replays", "checkpoint_*")))
            for d in sets[:-keep_r]:
                shutil.rmtree(d, ignore_errors=True)
            # Training replays are per-step directories too, and grow with one set per
            # checkpoint window; prune them on the same rule so the pool's replays cannot
            # quietly outgrow the evaluation ones.
            tsets = sorted(glob.glob(os.path.join(self.run_dir, "replays", "train_*")))
            for d in tsets[:-keep_r]:
                shutil.rmtree(d, ignore_errors=True)

    def write_status(self, state: str, activity: str = "", done: int = 0, total: int = 0, **extra):
        """Heartbeat for the dashboard: who is training, how far, what it is doing right now
        (activity + done/total progress), and whether the pid is alive. Written at every
        stage change and every few seconds inside a rollout, so "nothing moved" is visible.

        Carries memory and disk too. When the OS kills the run there is no exception to
        catch and no traceback to write — the last heartbeat before the kill is the only
        evidence, so it has to say what the run was costing at that moment."""
        self.maintain_resources()
        st = dict(state=state, pid=os.getpid(), step=self.global_step, update=self.update,
                  matches=self.matches_done, phase=self.cfg["phase"], stage=self.cfg["stage"],
                  activity=activity, done=done, total=total, time=time.time(),
                  next_eval_update=self.next_eval_update(), eval=self.last_eval,
                  disk_mb=self.disk_mb(), disk_free_mb=round(free_mb(self.run_dir)),
                  code=self.code, resource_cleanup=self.resource_cleanup,
                  memory_restart_pending=self._resource_restart,
                  **mem_report(), **self.gpu_memory(), **extra)
        self._last_status = time.time()
        tmp = os.path.join(self.run_dir, "status.json.tmp")
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, os.path.join(self.run_dir, "status.json"))

    def gpu_memory(self) -> dict:
        """Track Metal allocations separately; RSS misses much of its cached memory."""
        if self.device != "mps":
            return {}
        try:
            live = torch.mps.current_allocated_memory() / 2**20
            driver = torch.mps.driver_allocated_memory() / 2**20
            return dict(gpu_live_mb=round(live, 1), gpu_driver_mb=round(driver, 1),
                        gpu_cache_mb=round(max(0.0, driver - live), 1))
        except (RuntimeError, AttributeError):
            return {}

    def watch_waiting_resources(self) -> None:
        self.maintain_resources()
        if self._resource_restart:
            raise ResourceRecycle("memory pressure while waiting for an environment response")

    def maintain_resources(self, force: bool = False) -> None:
        """Run between decisions/minibatches; restart only after a completed update.

        Free unused allocator caches before asking for a process recycle. Checkpoint,
        optimizer and RNG state survive a recycle; the supervisor resumes this branch.
        """
        now = time.monotonic()
        if not force and now - self._resource_check_at < self.cfg["resource_check_seconds"]:
            return
        self._resource_check_at = now
        disk = free_mb(self.run_dir)
        trigger = max(self.cfg["disk_cleanup_trigger_mb"], self.cfg["disk_floor_mb"])
        parent = Path(self.run_dir).parent
        # Test/benchmark runs under /tmp must not scan unrelated sibling directories.
        runs = parent if parent.resolve() == Path(RUNS).resolve() else Path(self.run_dir)
        cleaned = trim_owned_logs(runs, max_mb=self.cfg["log_max_mb"],
                                  pressure=disk < trigger,
                                  home=Path.home() if runs == parent else None)
        if cleaned["reclaimed_mb"]:
            print(f"[resources] reclaimed {cleaned['reclaimed_mb']:.1f} MB from "
                  f"{cleaned['files']} diagnostic logs", flush=True)
            self._disk = (0.0, 0.0)
        memory = mem_report()
        gpu = self.gpu_memory()
        low = memory.get("free_mb", float("inf")) < self.cfg["memory_cleanup_free_mb"]
        cached = gpu.get("gpu_cache_mb", 0) > self.cfg["gpu_cache_max_mb"]
        if low or cached:
            gc.collect()
            # Preserve all opponents serving an in-flight game, including checkpoints
            # that retention may already have removed from disk.
            live = {e.label.split(":", 1)[1] for e in (self.envs.envs if self.envs else [])
                    if e.label.startswith("pool:")}
            for path in list(self.pool_cache):
                if path != "self" and path not in live:
                    del self.pool_cache[path]
            if self.device == "mps":
                try:
                    torch.mps.synchronize()
                    torch.mps.empty_cache()
                except RuntimeError as e:
                    cleaned["errors"].append(f"Metal cache cleanup: {e}")
                    self._resource_restart = True
                    print("[resources] Metal cache cleanup failed; saving for automatic resume", flush=True)
            elif str(self.device).startswith("cuda"):
                torch.cuda.empty_cache()
            after = self.gpu_memory()
            reclaimed = max(0, gpu.get("gpu_driver_mb", 0) - after.get("gpu_driver_mb", 0))
            if reclaimed or low:
                print(f"[resources] cleared unused memory: GPU reclaimed {reclaimed:.1f} MB; "
                      f"system available {mem_report().get('free_mb', 0):.0f} MB", flush=True)
            gpu = after
            cleaned["gpu_reclaimed_mb"] = round(reclaimed, 1)
        cap = float(self.cfg["gpu_memory_restart_mb"])
        if cap > 0 and gpu.get("gpu_driver_mb", 0) >= cap and not self._resource_restart:
            self._resource_restart = True
            print(f"[resources] Metal driver still holds {gpu['gpu_driver_mb']:.0f} MB "
                  f"after cleanup; checkpointing after this update for automatic resume", flush=True)
        after_memory = mem_report() if low or cached else memory
        limit = float(self.cfg["mem_limit_mb"])
        if (after_memory.get("free_mb", float("inf")) < self.cfg["memory_cleanup_free_mb"]
                and limit > 0 and after_memory.get("total_mb", 0) >= limit
                and not self._resource_restart):
            self._resource_restart = True
            print(f"[resources] system has {after_memory['free_mb']:.0f} MB available and "
                  f"trainer/envs hold {after_memory['total_mb']:.0f} MB after cleanup; "
                  "saving for automatic resume", flush=True)
        cleaned["checked_at"] = time.time()
        cleaned["disk_free_mb"] = round(free_mb(self.run_dir), 1)
        self.resource_cleanup = cleaned

    def load(self, path: str, keep_cfg: bool = False):
        ck = torch.load(path, map_location=self.device, weights_only=False)
        load_compat(self.net, ck["model"], self.opt, ck["opt"])
        if not keep_cfg:
            self.cfg = with_defaults(ck["cfg"])
        self.global_step = ck["global_step"]
        self.update = ck["update"]
        self.matches_done = ck["matches_done"]
        self.map_idx = ck["map_idx"] % max(1, len(self.cfg["maps"]))
        self.parent = ck.get("parent")
        self.rng.setstate(ck["rng"])
        self.episode_seed = ck.get("episode_seed", self.episode_seed)
        self.pfsp = dict(ck.get("pfsp") or {})
        self.champion_score = tuple(ck.get("champion_score", (-1.0, -1e30)))
        if keep_cfg and any(self.cfg.get(k) != ck["cfg"].get(k) for k in
                            ("eval_maps", "eval_seed", "eval_games", "fog", "round_cap")):
            self.champion_score = (-1.0, -1e30)
        for g in self.opt.param_groups:
            g["lr"] = self.cfg["lr"]
        self.sync_act_net()
        if "torch_rng" in ck:
            torch.set_rng_state(ck["torch_rng"].cpu())
        if "numpy_rng" in ck:
            np.random.set_state(ck["numpy_rng"])
        if self.device == "mps" and "mps_rng" in ck:
            torch.mps.set_rng_state(ck["mps_rng"].cpu())

    def sync_act_net(self) -> None:
        if self.act_net is not self.net:
            self.act_net.load_state_dict(self.net.state_dict())

    # -- opponents (8.2) --
    def pool_checkpoints(self) -> list[str]:
        cks = sorted(glob.glob(os.path.join(self.run_dir, "ckpt_*.pt")))
        size = max(0, int(self.cfg["pool_size"]))
        recent = cks[-size:] if size else []
        older = cks[:-size] if size else cks
        count = max(0, int(self.cfg.get("pool_archive_size", 0)))
        archive = ([older[i] for i in np.linspace(0, len(older) - 1,
                    min(count, len(older)), dtype=int)] if older and count else [])
        champions = sorted(glob.glob(os.path.join(self.run_dir, "champion_*.pt")))[-1:]
        return list(dict.fromkeys(recent + archive + champions))

    def pool_net(self, path: str) -> PolicyNet:
        if path == "self" and path not in self.pool_cache:
            net = copy.deepcopy(self.act_net).eval()
            self.pool_cache["self"] = net
            return net
        if path not in self.pool_cache:
            net = PolicyNet()
            load_compat(net, torch.load(path, map_location="cpu", weights_only=False)["model"])
            self.pool_cache[path] = net.eval()
            # The pool is pool_size members plus "self"; anything beyond that rotated out
            # of the pool — unless a game that started against it is still running, which
            # still needs it and whose checkpoint prune() may already have deleted.
            live = {e.label.split(":", 1)[1] for e in (self.envs.envs if self.envs else [])
                    if e.label.startswith("pool:")}
            for old in [k for k in self.pool_cache if k not in live and k != path]:
                if len(self.pool_cache) <= self.cfg["pool_size"] + self.cfg.get("pool_archive_size", 0) + 2:
                    break
                del self.pool_cache[old]
        self.pool_cache.move_to_end(path)
        return self.pool_cache[path]

    def pick_opponent(self) -> tuple[int, str]:
        """(env opponent code, label). Phase A: the scripted AI. Phase B: the pool.
        Phase "league": the pool, prioritised toward members that beat us (PFSP)."""
        if self.cfg["phase"] == "A" or self.rng.random() < self.cfg["pool_ai_fraction"]:
            return HARD, "ai:" + SCRIPTED
        cands = ["self"] + self.pool_checkpoints()
        if self.cfg["phase"] == "league":
            member = self.rng.choices(cands, weights=[self.pfsp_weight(c) for c in cands])[0]
        else:
            member = self.rng.choice(cands)
        if member != "self":
            # Load it now: by the opponent's first move this checkpoint may have left the
            # pool and been pruned from disk, and the game still needs it.
            self.pool_net(member)
        return EXTERNAL, "pool:" + member

    def pfsp_weight(self, member: str) -> float:
        """Harder opponents more often. Unknown members count as even (0.5)."""
        games, wins = self.pfsp.get(member, [0, 0])
        wr = (wins + 1) / (games + 2)
        return (1.0 - wr) ** float(self.cfg["pfsp_power"]) + float(self.cfg["pfsp_floor"])

    def pick_style(self) -> int:
        """HARD's play style for a TRAINING game (evaluation always plays standard)."""
        w = list(self.cfg.get("opponent_styles") or [1.0])
        w = (w + [0.0] * 4)[:4]
        if sum(w) <= 0:
            return 0
        return self.rng.choices(range(4), weights=w)[0]

    def shaping_scale(self) -> float:
        n = int(self.cfg["shaping_decay_updates"])
        if n <= 0:
            return 1.0
        done = max(0, self.update - int(self.cfg["shaping_decay_start"]))
        floor = float(self.cfg["shaping_floor"])
        return max(floor, 1.0 - (1.0 - floor) * done / n)

    def pick_map(self) -> int:
        """Weighted draw when map_weights is set, else the fixed rotation (8.2.2)."""
        maps = self.cfg["maps"]
        if self.cfg.get("map_weights"):
            return self.rng.choices(range(len(maps)), weights=self.cfg["map_weights"])[0]
        return (self.matches_done // self.cfg["map_rotate_matches"]) % len(maps)

    def _save_rollout_replay(self, env, result: str, info: dict) -> None:
        """Write one training replay for the map this episode was played on.

        Filed under replays/train/<step>/ rather than replays/checkpoint_*/ so it is
        obvious in the dashboard which replays came from TRAINING (whole map pool, the
        policy against whatever opponent the rotation picked) and which came from
        EVALUATION (pinned map, always vs the graduation opponent). Mixing them in one
        directory would make the map column look inconsistent for no stated reason.
        """
        mp = map_name(env.cfg.map_path)
        stem = os.path.splitext(mp)[0]
        # train_<step>, NOT train/<step>: the dashboard gallery globs
        # runs/*/replays/*/*.mcfr, which is exactly two levels, so a nested directory
        # would write files the gallery can never find.
        d = os.path.join(self.run_dir, "replays", f"train_{self.global_step:09d}")
        try:
            os.makedirs(d, exist_ok=True)
            path = os.path.join(d, f"{stem}_{result}.mcfr")
            if env.save_replay(path):
                # Sidecar in the same schema the evaluation replays use. It has to carry
                # the match's OUTCOME NUMBERS too, not just its identity: without by /
                # value_diff / rounds the gallery showed None in those columns for every
                # training replay, which reads as "broken on every map except the
                # evaluation one" — evaluation is pinned to a single map, so its rows were
                # the only populated ones.
                with open(path + ".json", "w") as f:
                    json.dump(dict(branch=os.path.basename(self.run_dir),
                                   step=self.global_step, update=self.update,
                                   opponent=env.label, source="training",
                                   result=result, by=info.get("by", ""),
                                   value_diff=info.get("value_diff"),
                                   rounds=info.get("round"), steps=info.get("steps"),
                                   illegal=info.get("illegal"),
                                   fire_losses=info.get("fire_losses"),
                                   map=env.cfg.map_path,
                                   side=env.cfg.side, seed=env.cfg.seed,
                                   time=time.time()), f)
        except Exception as e:      # a replay is a nicety; never take the run down for one
            print(f"[train] could not save rollout replay for {mp}: {e}", flush=True)

    def next_episode(self, record: bool = False) -> tuple[EpisodeConfig, str]:
        # Rotation: every map_rotate_matches completed matches, the next map (8.2.2).
        maps = self.cfg["maps"]
        self.map_idx = self.pick_map()
        # Record ONE rollout episode per map per checkpoint window.
        #
        # Replays used to come only from evaluation, and evaluation is pinned to a single
        # map so the whole pool can be compared against earlier runs. The consequence was
        # that every replay on the dashboard was the same map: three of the four maps in
        # training had no watchable game anywhere, which reads as "those maps are not
        # running". Rollout episodes happen regardless, so capturing one costs a replay
        # write rather than extra games.
        here = map_name(maps[self.map_idx])
        if here not in self._replay_maps:
            record = True
            # Claim the map HERE, when the assignment is handed out, not when the replay
            # is written. All six envs are on the same map at the same time, so marking it
            # on save would hand every one of them a recording flag for the same episode:
            # six simultaneous recordings, five of them overwriting the sixth's file.
            self._replay_maps.add(here)
        opp, label = self.pick_opponent()
        style = self.pick_style() if opp == HARD else 0
        if style:
            label += ":" + STYLE_NAMES[style]
        self.episode_seed += 1
        mp = maps[self.map_idx]
        army = "shuffle" if not is_generated(mp) and self.rng.random() < float(self.cfg["army_shuffle"]) else ""
        fog = FOGS["off"] if self.rng.random() < float(self.cfg["fog_off_share"]) else FOGS[self.cfg["fog"]]
        cfg = EpisodeConfig(
            map_path=maps[self.map_idx], seed=self.episode_seed,
            side=self.episode_seed % 2, opponent=opp, round_cap=self.cfg["round_cap"], max_steps=self.cfg.get("max_steps", 3000),
            civilians=self.cfg["civilians"], random_events=self.cfg["random_events"],
            fog=fog, friendly_fire=self.cfg["friendly_fire"], record=record,
            disembark=disembark_allowed(self.cfg, maps[self.map_idx]),
            max_candidates=self.cfg["max_candidates"], max_actors=self.cfg["max_actors"],
            opponent_style=style, shaping_scale=self.shaping_scale(),
            potential_coef=float(self.cfg["potential_coef"]), army=army,
            gamma=float(self.cfg["gamma"]),
        )
        return cfg, label

    # -- rollout (5.1) --
    def collect(self) -> tuple[list[list[Step]], dict]:
        """Every env runs at its own pace: whatever replies are in get one batched forward
        and go straight back while the other envs keep computing. Stepping all envs in
        lockstep waited on the slowest one every step — an end-turn, where the scripted
        opponent plays, is ~8x slower than an own action — and ran the policy while every
        Godot process sat idle."""
        cfg = self.cfg
        envs = self.envs.envs
        n = len(envs)
        T = cfg["rollout_steps"]
        buffers: list[list[Step]] = [[] for _ in range(n)]
        stats = defaultdict(list)
        usage_units = Counter()
        usage_kinds = Counter()
        # Per-map copies of the same counters. The pooled numbers are the ones that
        # mislead on a mixed pool: "veh_move+cannon 15%" is not a policy that drives a bit
        # everywhere, it is a policy that drives constantly on the tank map and barely at
        # all on the other three, and the pooled share cannot tell those apart. Keyed by
        # map basename, which is what the dashboard and the eval rows already use.
        usage_units_map: dict[str, Counter] = defaultdict(Counter)
        usage_kinds_map: dict[str, Counter] = defaultdict(Counter)
        offered: dict[str, Counter] = defaultdict(Counter)
        accepted: dict[str, Counter] = defaultdict(Counter)
        selected: dict[int, tuple[str, str]] = {}
        timings = Counter()
        illegal = 0
        inflight: dict[int, str] = {}          # env -> "reset" | "step" awaiting its reply
        bad_resets = [0] * n

        def new_episode(i: int) -> None:
            ec, envs[i].label = self.next_episode()
            envs[i].cfg = ec
            envs[i].send(ec.to_cmd())
            inflight[i] = "reset"

        torch.set_num_threads(self.act_threads)
        for i, env in enumerate(envs):
            if env.last is None or env.last.get("done", True):
                new_episode(i)
            elif not env.label:
                env.label = "ai:" + SCRIPTED
        t0 = time.time()
        budget = float(self.rollout_budget_mb) * 2**20
        buf_bytes = 0
        self.pool_cache.pop("self", None)
        self.write_status("running", "collecting rollout", 0, T * n)
        taken = 0
        capped = False
        def responding() -> bool:
            # Finish every learner transition before PPO, including the entire pool
            # response. No new learner actions are needed while draining this tail.
            return any(buf and not buf[-1].done and envs[i].last is not None
                       and not envs[i].last.get("done", False)
                       and envs[i].last["acting"] != envs[i].cfg.side
                       for i, buf in enumerate(buffers))

        while (taken < T * n and not capped) or inflight or responding():
            if not capped and budget > 0 and buf_bytes > budget:
                # A map whose decision points carry thousands of candidates makes the
                # per-step cost unpredictable. Cutting the rollout short costs this
                # update some samples; running out of memory costs the whole run.
                print(f"[train] rollout capped at {buf_bytes / 2**20:.0f} MB "
                      f"({taken}/{T * n} steps)", flush=True)
                capped = True
            if time.time() - self._last_status > 3:
                # Report WHICH MAP each env is playing. Without it the only record of the
                # training pool is map_idx inside a checkpoint, so a multi-map run looks
                # single-map from outside: evaluation is pinned to one map, and every
                # replay on the dashboard comes from evaluation, so the other maps leave
                # no visible trace anywhere. That is exactly how a correctly rotating
                # four-map pool came to look like it was ignoring three of them.
                self.write_status("running", "collecting rollout", taken, T * n,
                                  env_steps_per_sec=taken / max(1e-6, time.time() - t0),
                                  buffer_mb=round(buf_bytes / 2**20, 1),
                                  map_idx=self.map_idx,
                                  map_name=map_name(self.cfg["maps"][self.map_idx]),
                                  env_maps=[map_name(e.cfg.map_path)
                                            for e in envs if e.cfg],
                                  rounds=[int(e.last["info"]["round"]) for e in envs if e.last])
                if self._resource_restart:
                    raise ResourceRecycle("allocator memory could not be released during collection")
            if (taken < T * n and not capped) or responding():
                collecting = taken < T * n and not capped
                waiting = [i for i in range(n) if i not in inflight
                           and envs[i].last is not None and not envs[i].last["done"]]
                trainee = [i for i in waiting if collecting
                           and envs[i].last["acting"] == envs[i].cfg.side]
                actions = {}
                if trainee:
                    ts = time.perf_counter()
                    enc = [encode(envs[i].last) for i in trainee]
                    timings["encode_secs"] += time.perf_counter() - ts
                    ts = time.perf_counter()
                    a, lp, v = choose(self.act_net, enc, "cpu")
                    timings["inference_secs"] += time.perf_counter() - ts
                    for j, i in enumerate(trainee):
                        g, f, c, cl = enc[j]
                        step = Step(g, f, c, cl, int(a[j]), float(lp[j]), float(v[j]))
                        buffers[i].append(step)
                        buf_bytes += step.nbytes
                        actions[i] = int(a[j])
                        legal = envs[i].last["legal"][int(a[j])]
                        mp = map_name(envs[i].cfg.map_path) if envs[i].cfg else "?"
                        offered[mp].update({c["i"]["t"] for c in envs[i].last["legal"]})
                        selected[i] = (mp, legal["i"]["t"])
                        usage_kinds[legal["i"]["t"]] += 1
                        usage_kinds_map[mp][legal["i"]["t"]] += 1
                        at = legal.get("at", -1)
                        if at is not None and at >= 0:
                            usage_units[at] += 1
                            usage_units_map[mp][at] += 1
                    taken += len(trainee)
                # Phase B: opponent decision points served by a frozen pool member.
                by_net = defaultdict(list)
                for i in waiting:
                    if envs[i].last["acting"] != envs[i].cfg.side and (
                            collecting or (buffers[i] and not buffers[i][-1].done)):
                        by_net[envs[i].label.split(":", 1)[1]].append(i)
                for path, idxs in by_net.items():
                    ts = time.perf_counter()
                    enc = [encode(envs[i].last) for i in idxs]
                    timings["encode_secs"] += time.perf_counter() - ts
                    ts = time.perf_counter()
                    a, _, _ = choose(self.pool_net(path), enc, "cpu")
                    timings["opponent_inference_secs"] += time.perf_counter() - ts
                    for j, i in enumerate(idxs):
                        actions[i] = int(a[j])
                for i, act in actions.items():
                    envs[i].send({"cmd": "step", "action": act})
                    inflight[i] = "step"
            ts = time.perf_counter()
            ready = self.envs.wait_any(list(inflight)) if inflight else []
            timings["wait_secs"] += time.perf_counter() - ts
            for i in ready:
                env = envs[i]
                ts = time.perf_counter()
                r = env.last = env.recv()
                timings["receive_secs"] += time.perf_counter() - ts
                if inflight.pop(i) == "reset":
                    if r["done"]:
                        # A reset that comes back already over (a degenerate map) gets a new
                        # seed; one that keeps doing it is a broken env, not a reason to spin.
                        bad_resets[i] += 1
                        if bad_resets[i] > 8:
                            raise EnvDied(f"env {i}: 8 resets in a row came back already over")
                        new_episode(i)
                    else:
                        bad_resets[i] = 0
                    continue
                stats["legal_ms"].append(r["info"].get("legal_ms", 0.0))
                stats["obs_ms"].append(r["info"].get("obs_ms", 0.0))
                if i in selected:
                    mp, kind = selected.pop(i)
                    if r["info"].get("action_ok", False):
                        accepted[mp][kind] += 1
                buf = buffers[i]
                # Every reward belongs to the trainee's latest decision in this episode —
                # the ones that arrive over a pool opponent's moves (Phase B) included; those
                # used to be credited to the trainee's NEXT decision instead.
                if buf and not buf[-1].done:
                    buf[-1].reward += r["reward"]
                if r["done"]:
                    if buf:
                        buf[-1].done = True
                    info = r["info"]
                    res = info.get("result", "draw")
                    stats["win"].append(1.0 if res == "win" else 0.0)
                    stats["draw"].append(1.0 if res.startswith("draw") else 0.0)
                    stats["rounds"].append(info["round"])
                    stats["value_diff"].append(info["value_diff"])
                    stats["illegal"].append(info["illegal"])
                    stats["result"].append((env.label, map_name(env.cfg.map_path), res))
                    stats["fog_win"].append((env.cfg.fog, 1.0 if res == "win" else 0.0))
                    if "tac" in info:
                        stats["tac"].append((map_name(env.cfg.map_path), info["tac"]))
                    if env.label.startswith("pool:"):
                        rec = self.pfsp.setdefault(env.label.split(":", 1)[1], [0, 0])
                        rec[0] += 1
                        rec[1] += 1 if res == "win" else 0
                    stats["aim"].append((map_name(env.cfg.map_path),
                                         info.get("shots", 0), info.get("shots_hit", 0)))
                    illegal += info["illegal"]
                    self.matches_done += 1
                    # Save BEFORE any reset: the recording lives in the env and a reset
                    # discards it.
                    if env.cfg is not None and env.cfg.record:
                        self._save_rollout_replay(env, res, info)
                    if taken < T * n and not capped:
                        new_episode(i)
        dt = time.time() - t0
        info = dict(stats=stats, usage_units=usage_units, usage_kinds=usage_kinds,
                    usage_units_map=usage_units_map, usage_kinds_map=usage_kinds_map,
                    offered=offered, accepted=accepted, timings=dict(timings),
                    illegal=illegal, seconds=dt, steps=taken)
        return buffers, info

    # -- PPO update --
    def ppo_update(self, buffers: list[list[Step]]) -> dict:
        cfg = self.cfg
        gamma, lam = cfg["gamma"], cfg["lam"]
        # Bootstrap value for each env's last state, unless it ended.
        last_vals = []
        for i, env in enumerate(self.envs.envs):
            if not buffers[i]:        # env contributed nothing (a short-cut rollout)
                last_vals.append(0.0)
            elif buffers[i][-1].done or env.last is None or env.last["done"]:
                last_vals.append(0.0)
            elif env.last["acting"] == env.cfg.side:
                enc = [encode(env.last)]
                _, _, v = choose(self.act_net, enc, "cpu")
                last_vals.append(float(v[0]))
            else:
                raise RuntimeError("rollout ended before the opponent response completed")
        flat_steps, advs, rets = [], [], []
        for i, buf in enumerate(buffers):
            adv = np.zeros(len(buf), dtype=np.float32)
            gae = 0.0
            next_v = last_vals[i]
            for t in reversed(range(len(buf))):
                s = buf[t]
                nonterm = 0.0 if s.done else 1.0
                delta = s.reward + gamma * next_v * nonterm - s.value
                gae = delta + gamma * lam * nonterm * gae
                adv[t] = gae
                next_v = s.value
            for t, s in enumerate(buf):
                flat_steps.append(s)
                advs.append(adv[t])
                rets.append(adv[t] + s.value)
        advs = np.asarray(advs, dtype=np.float32)
        rets = np.asarray(rets, dtype=np.float32)
        N = len(flat_steps)
        if N == 0:
            self.update += 1
            return {k: 0.0 for k in ("policy_loss", "value_loss", "entropy",
                                     "approx_kl", "clipfrac", "epochs_run")}
        advs = (advs - advs.mean()) / (advs.std() + 1e-8)
        mb = cfg["minibatch"]
        out = defaultdict(list)
        stopped_at = cfg["epochs"]
        torch.set_num_threads(self.update_threads)
        total_mb = cfg["epochs"] * ((N + mb - 1) // mb)
        done_mb = 0
        self.write_status("running", "PPO update", 0, total_mb)
        for epoch in range(cfg["epochs"]):
            epoch_kl = []
            order = np.random.permutation(N)
            for start in range(0, N, mb):
                # The update is minutes on a CPU; without this the heartbeat went silent
                # for all of it and the dashboard called a healthy run stale.
                if time.time() - self._last_status > 3:
                    self.write_status("running", "PPO update", done_mb, total_mb)
                done_mb += 1
                idx = order[start:start + mb]
                steps = [flat_steps[k] for k in idx]
                grid, flat, cand, cells, mask = collate(steps, self.device)
                actions = torch.tensor([s.action for s in steps], device=self.device)
                old_logp = torch.tensor([s.logp for s in steps], device=self.device)
                adv = torch.from_numpy(advs[idx]).to(self.device)
                ret = torch.from_numpy(rets[idx]).to(self.device)
                logits, value = self.net(grid, flat, cand, cells, mask)
                logp_all = F.log_softmax(logits, dim=1)
                logp = logp_all.gather(1, actions.unsqueeze(1)).squeeze(1)
                probs = logp_all.exp() * mask
                entropy = -(probs * logp_all.masked_fill(~mask, 0.0)).sum(1).mean()
                logratio = logp - old_logp
                ratio = logratio.exp()
                pg = -torch.min(ratio * adv, ratio.clamp(1 - cfg["clip"], 1 + cfg["clip"]) * adv).mean()
                vloss = F.mse_loss(value, ret)
                loss = pg + cfg["vf_coef"] * vloss - cfg["ent_coef"] * entropy
                self.opt.zero_grad()
                loss.backward()
                torch.nn.utils.clip_grad_norm_(self.net.parameters(), cfg["max_grad_norm"])
                self.opt.step()
                with torch.no_grad():
                    # Schulman's k3 estimator: unbiased, lower variance, and always >= 0.
                    # The naive k1, mean(old_logp - logp), routinely comes out NEGATIVE -
                    # town-3 logged kl=-0.0470 at clipfrac 25.2% with all four epochs run,
                    # because "-0.047 > 0.02" is false and the brake silently never fired
                    # while the policy moved more than twice the target.
                    kl = ((ratio - 1) - logratio).mean().item()
                    epoch_kl.append(kl)
                    out["policy_loss"].append(pg.item())
                    out["value_loss"].append(vloss.item())
                    out["entropy"].append(entropy.item())
                    out["approx_kl"].append(kl)
                    out["clipfrac"].append(((ratio - 1).abs() > cfg["clip"]).float().mean().item())
                self.opt.zero_grad(set_to_none=True)
                # Let cache cleanup release these before the next progress heartbeat.
                del grid, flat, cand, cells, mask, logits, value, logp_all, logp, probs
                del entropy, logratio, ratio, pg, vloss, loss, actions, old_logp, adv, ret
            # One epoch is the granularity: checking per minibatch would abandon an update
            # halfway through a shuffle and bias which samples ever get used.
            if self._resource_restart or (cfg["target_kl"] and float(np.mean(epoch_kl)) > cfg["target_kl"]):
                stopped_at = epoch + 1
                break
        self.sync_act_net()
        self.global_step += N
        self.update += 1
        res = {k: float(np.mean(v)) for k, v in out.items()}
        res["epochs_run"] = float(stopped_at)
        return res

    # -- evaluation (10.3): greedy, fixed seeds, not training data --
    def evaluate(self, games: int, record_dir: str | None = None,
                 keep: int = 0, net: PolicyNet | None = None,
                 maps: list[str] | None = None, log_games: bool = True,
                 fogs: list[int] | None = None, suite: str = "main",
                 round_cap: int | None = None) -> dict:
        """Game k gets seed_base + k // 2 and side k % 2, whichever env plays it; an env
        starts its next game the moment it finishes one instead of waiting for the slowest
        game of a batch."""
        opponent = SCRIPTED
        net = net or self.act_net
        envs = self.envs.envs
        results, diffs, rounds = [], [], []
        per_game: list[dict] = []     # one row per game, for the dashboard's drill-down
        # Evaluation maps are configurable SEPARATELY from training maps, and default to
        # the training pool so nothing changes for runs that do not set it.
        #
        # This exists because evaluation picks its map per game (`maps[k % len(maps)]`).
        # The moment a pool holds more than one KIND of map, a 10-game evaluation becomes
        # two or three games on each of several different tasks and value_diff_hard turns
        # into their average — a mixture whose mean measures nothing, and whose scatter no
        # longer matches the noise floor every decision here is judged against. Pinning
        # evaluation to one map keeps the number comparable across a pool change, which is
        # the only way to answer "did adding those maps help?".
        eval_maps = maps or self.cfg.get("eval_maps") or self.cfg["maps"]
        seed_base = int(self.cfg["eval_seed"]) + (1_000_000 if suite == "heldout" else 0)
        game_of: dict[int, int] = {}
        inflight: set[int] = set()
        started = 0

        def start(i: int) -> None:
            nonlocal started
            k = game_of[i] = started
            started += 1
            envs[i].cfg = EpisodeConfig(
                map_path=eval_maps[(k // 2) % len(eval_maps)], seed=seed_base + k // 2,
                side=k % 2, opponent=HARD,
                round_cap=round_cap if round_cap is not None else self.cfg["round_cap"],
                max_steps=self.cfg.get("max_steps", 3000),
                civilians=self.cfg["civilians"], random_events=self.cfg["random_events"],
                fog=fogs[k % len(fogs)] if fogs else FOGS[self.cfg["fog"]],
                friendly_fire=self.cfg["friendly_fire"],
                disembark=disembark_allowed(self.cfg, eval_maps[(k // 2) % len(eval_maps)]),
                max_candidates=self.cfg["max_candidates"],
                max_actors=self.cfg["max_actors"],
                # Пишем КАЖДУЮ партию оценки, а не первые `keep`. Признак записи
                # задаётся на reset'е, а кто победил — известно только в конце, так
                # что «сохранять все победы» невозможно, если не включить запись
                # заранее. Эпизод от этого не меняется: ReplayRecorder.capture_opening()
                # сам зовёт play_civilian_slots(), ту же самую, что и ветка без записи.
                # На диск попадают не все — см. ниже.
                record=record_dir is not None)
            envs[i].send(envs[i].cfg.to_cmd())
            inflight.add(i)

        torch.set_num_threads(self.act_threads)
        self.write_status("running", f"evaluating vs {opponent}", 0, games)
        for i in range(min(len(envs), games)):
            start(i)
        while inflight:
            # A company-scale game runs for many minutes; without a heartbeat in here the
            # dashboard sees nothing move and calls the run stale. The same tick bounds the
            # env logs, since an evaluation runs between updates and so between the
            # per-update disk checks.
            if time.time() - self._last_status > 5:
                self.envs.trim_logs()
                self.write_status(
                    "running", f"evaluating vs {opponent}", len(results), games,
                    eval_rounds=[int(envs[j].last["info"]["round"])
                                 for j in sorted(inflight) if envs[j].last],
                    eval_steps=[int(envs[j].last["info"].get("steps", 0))
                                for j in sorted(inflight) if envs[j].last])
                if self._resource_restart:
                    raise ResourceRecycle("allocator memory could not be released during evaluation")
            todo = []
            for i in self.envs.wait_any(sorted(inflight)):
                inflight.discard(i)
                r = envs[i].last = envs[i].recv()
                if not r["done"]:
                    todo.append(i)
                    continue
                info = r["info"]
                results.append(info.get("result", "draw"))
                diffs.append(info["value_diff"])
                rounds.append(info["round"])
                k = game_of[i]
                # An aggregate win rate hides which games went wrong and how. One
                # row per game means the dashboard can show that a 0% win rate was
                # four honest losses and four stalls, not eight of the same thing.
                row = dict(
                    step=self.global_step, update=self.update, opponent=opponent, suite=suite,
                    game=k + 1, result=results[-1], by=info.get("by", ""),
                    value_diff=info["value_diff"],
                    rounds=info["round"], steps=info.get("steps"),
                    illegal=info.get("illegal"),
                    # WHAT was refused, not just how many: the enumerator is meant to be
                    # exact, so a non-empty column is a bug report with the reason in it.
                    illegal_kinds=info.get("illegal_kinds") or None,
                    # Своих, сгоревших от расползания огня: смерть, которой можно
                    # избежать с гарантией, поэтому её видно отдельной колонкой.
                    fire_losses=info.get("fire_losses"),
                    seed=envs[i].cfg.seed, side=envs[i].cfg.side,
                    map=map_name(envs[i].cfg.map_path), time=time.time())
                per_game.append(row)
                # Appended as each game ends, not batched at the finish: a long
                # evaluation should show its results filling in, and if it dies
                # halfway the games it did play are already on disk.
                if log_games:
                    filename = "eval_games.jsonl" if suite == "main" else f"eval_{suite}_games.jsonl"
                    with open(os.path.join(self.run_dir, filename), "a") as f:
                        f.write(json.dumps(row) + "\n")
                print(f"[eval]   vs {opponent} game {k + 1}/{games}: "
                      f"{row['result']}"
                      f"{'(' + row['by'] + ')' if row['by'] else ''} "
                      f"in {row['rounds']}r / {row['steps']} steps",
                      flush=True)
                # Куда (и попадёт ли вообще) эта партия на диск.
                #
                # ПОБЕДА СОХРАНЯЕТСЯ ВСЕГДА, и не в набор чекпойнта, а в
                # replays/wins/, который _prune() не трогает (он чистит только
                # replays/checkpoint_*). Победа — это ровно то, ради чего всё
                # затеяно; потерять её из-за того, что она случилась пятой партией
                # из десяти или что набор состарился, было бы обидно до глупости.
                # Остальные партии, как и раньше, — выборка в `keep` штук.
                dest = None
                if record_dir is not None:
                    if results[-1] == "win":
                        wins_dir = os.path.join(self.run_dir, "replays", "wins")
                        os.makedirs(wins_dir, exist_ok=True)
                        dest = os.path.join(
                            wins_dir,
                            f"{self.global_step:09d}_vs_{opponent}_{k + 1}_win.mcfr")
                    elif k < keep:
                        os.makedirs(record_dir, exist_ok=True)
                        dest = os.path.join(
                            record_dir, f"vs_{opponent}_{k + 1}_{results[-1]}.mcfr")
                if dest is not None:
                    rp = dest
                    if envs[i].save_replay(rp):
                        with open(rp + ".json", "w") as f:
                            json.dump(dict(branch=os.path.basename(self.run_dir),
                                           step=self.global_step, update=self.update,
                                           opponent=opponent,
                                           result=results[-1], by=info.get("by", ""),
                                           value_diff=info["value_diff"],
                                           rounds=info["round"], map=envs[i].cfg.map_path,
                                           side=envs[i].cfg.side, game=k + 1,
                                           time=time.time()), f)
                        if results[-1] == "win":
                            print(f"[eval]   WIN recorded -> {rp}", flush=True)
                if started < games:
                    start(i)
            if todo:
                a, _, _ = choose(net, [encode(envs[i].last) for i in todo], "cpu", greedy=True)
                for q, i in enumerate(todo):
                    envs[i].send({"cmd": "step", "action": int(a[q])})
                    inflight.add(i)
        for env in self.envs.envs:
            env.last = None   # evaluation episodes are over; training resets next collect
        wins = sum(r == "win" for r in results)
        draws = sum(r.startswith("draw") for r in results)
        # How the games ended, not just how many were won. An untrained greedy policy
        # tends to stall on a free action and never end its turn, so the episode dies on
        # max_steps ("draw_steps") before the scripted opponent has played at all, which
        # looks like a broken evaluation rather than what it is. The breakdown makes that
        # legible.
        outcomes = Counter(results)
        by_map: dict[str, list[float]] = defaultdict(list)
        for row in per_game:
            by_map[row["map"]].append(1.0 if row["result"] == "win" else 0.0)
        return dict(games=len(results), winrate=wins / max(1, len(results)),
                    rout_winrate=sum(r["result"] == "win" and r["by"] == "rout"
                                     for r in per_game) / max(1, len(results)),
                    value_winrate=sum(r["result"] == "win" and r["by"] == "value"
                                      for r in per_game) / max(1, len(results)),
                    illegal=sum(r.get("illegal") or 0 for r in per_game),
                    by_map={m: float(np.mean(v)) for m, v in by_map.items()},
                    lossrate=outcomes["loss"] / max(1, len(results)),
                    drawrate=draws / max(1, len(results)), value_diff=float(np.mean(diffs)),
                    rounds=float(np.mean(rounds)),
                    stallrate=outcomes["draw_steps"] / max(1, len(results)),
                    outcomes=dict(outcomes))

    # -- main loop --
    def train(self):
        cfg = self.cfg
        # shaping_decay_start: -1 means "from the update this config was first applied":
        # a fork of a run thousands of updates in must decay from where it starts, not
        # find its bonuses already gone. Anchored once, before config.yaml is written, so a
        # resume keeps the same anchor.
        if int(cfg.get("shaping_decay_start", 0)) < 0:
            cfg["shaping_decay_start"] = self.update
        with open(os.path.join(self.run_dir, "config.yaml"), "w") as f:
            yaml.safe_dump(cfg, f)
        self.write_status("running", f"starting {cfg['n_envs']} Godot envs", 0, 0)
        self.envs = VecEnv(cfg["n_envs"], cfg["godot"],
                           log_dir=os.path.join(self.run_dir, "envlogs"))
        self.envs.on_wait = self.watch_waiting_resources
        stop_flag = os.path.join(self.run_dir, "STOP")

        def on_signal(signum, frame):
            if signum == signal.SIGHUP:
                # The terminal is gone (closed window / nohup-less run): keep logging
                # straight into the branch log so the graceful stop below can still print.
                sys.stdout = sys.stderr = open(os.path.join(RUNS, f"{os.path.basename(self.run_dir)}.log"), "a")
            print(f"[train] signal {signum}: finishing this update, then saving", flush=True)
            self.stop_requested = True
        signal.signal(signal.SIGINT, on_signal)
        signal.signal(signal.SIGTERM, on_signal)
        signal.signal(signal.SIGHUP, on_signal)   # closed terminal
        print(f"[train] branch={os.path.basename(self.run_dir)} phase={cfg['phase']} "
              f"stage={cfg['stage']} maps={len(cfg['maps'])} envs={cfg['n_envs']} "
              f"step={self.global_step} update={self.update}", flush=True)
        crash: dict = {}
        try:
            if cfg["preflight"]:
                self.write_status("running", "checking map and policy compatibility", 0, 0)
                checked = preflight_config(cfg, self.envs.envs[0])
                with open(os.path.join(self.run_dir, "preflight.json"), "w") as f:
                    json.dump(checked, f, indent=2)
            while self.global_step < cfg["total_steps"] and not self.stop_requested:
                if self.wait_while_paused():
                    break
                try:
                    buffers, info = self.collect()
                except EnvDied as e:
                    print(f"[train] {e}; restarting envs", flush=True)
                    self.write_status("running", f"restarting envs after: {e}", 0, 0)
                    self.envs.rebuild()
                    continue
                t0 = time.time()
                losses = self.ppo_update(buffers)      # writes its own progress heartbeat
                del buffers            # the rollout is the biggest thing alive; drop it
                                       # before eval opens a second front on memory
                # With the buffer gone this is what the process costs empty — the number
                # over_memory_budget() needs to know how much rollout it can still afford.
                self._base_mb = mem_report().get("total_mb", 0.0)
                self.log(info, losses, time.time() - t0)
                self.write_status("running", "update done", 0, 0)
                if self._resource_restart:
                    self.stop_reason = "" if self.stop_requested or os.path.exists(stop_flag) else "memory"
                    break
                if self.update % cfg["checkpoint_every"] == 0:
                    path = self.save()
                    print(f"[train] checkpoint {path}", flush=True)
                    # New window: let every map be recorded again. Without this the set
                    # fills once and the gallery freezes on the first few episodes of the
                    # run, which is a subtler version of the problem this fixes.
                    self._replay_maps.clear()
                # Evaluate on schedule, but also whenever this branch has no win rate at
                # all yet. eval_every is tens of updates and an update can take minutes,
                # so a fresh run used to show a blank "win vs HARD" for hours
                # and read as broken (§11.2). The second clause also rescues a branch
                # trained before this rule existed: it evaluates on its next update.
                if self.update % cfg["eval_every"] == 0 or not self.has_eval_history():
                    try:
                        self.run_eval()
                    except EnvDied as e:
                        # An env dying mid-evaluation costs this evaluation, not the run.
                        print(f"[train] {e} during eval; restarting envs, eval skipped", flush=True)
                        self.envs.rebuild()
                # The operator's stop is checked FIRST. Checked after the resource
                # ceilings, a stop requested while the disk happened to sit under its floor
                # was recorded as stop_reason "disk" — and the supervisor, which resumes
                # resource stops by design, started the run again (town-8, 2026-10-02).
                if os.path.exists(stop_flag):
                    os.remove(stop_flag)
                    print("[train] STOP flag found", flush=True)
                    break
                if self.over_memory_budget() or self.under_disk_floor():
                    break
        except ResourceRecycle as e:
            self.stop_reason = "" if self.stop_requested or os.path.exists(stop_flag) else "memory"
            print(f"[resources] {e}; saving checkpoint for automatic resume", flush=True)
        except (KeyboardInterrupt, SystemExit):
            raise                        # an asked-for stop, not a crash
        except BaseException as e:       # noqa: BLE001 - the reason must survive to disk
            if isinstance(e, RuntimeError) and "out of memory" in str(e).lower():
                print(f"[resources] {e}; releasing failed-update buffers and saving for automatic resume", flush=True)
                # Tracebacks retain the failed minibatch's GPU tensors. Release them
                # before saving; a completed checkpoint remains available if saving fails.
                e.__traceback__ = None
                buffers = None
                self.opt.zero_grad(set_to_none=True)
                self._resource_restart = True
                self.stop_reason = "" if self.stop_requested or os.path.exists(stop_flag) else "memory"
                self.maintain_resources(force=True)
            else:
                crash = dict(error=f"{type(e).__name__}: {e}",
                             traceback="".join(traceback.format_exc())[-4000:],
                             crashed_at=time.time(), crashed_update=self.update)
                print("[train] CRASHED: " + crash["error"] + "\n" + crash["traceback"], flush=True)
                raise
        finally:
            try:
                path = self.save()
                print(f"[train] final checkpoint {path}", flush=True)
            except Exception as e:       # a crash mid-save must not hide the first cause
                print(f"[train] could not write the final checkpoint: {e}", flush=True)
            self.envs.close()
            self.writer.close()
            self.write_status("crashed" if crash else "stopped",
                              stop_reason=self.stop_reason, **crash)

    # -- pause (11.3): hold the run without tearing the envs down --
    def wait_while_paused(self) -> bool:
        """Block while rl/runs/<branch>/PAUSE exists. Returns True if the run should end.

        Stopping and resuming would also work, but it throws away the Godot processes
        and the rollout in flight and takes a minute to come back. A pause keeps the
        envs warm, so continuing is instant — the difference between "pause while I
        play a match against it" and "restart the run"."""
        flag = os.path.join(self.run_dir, "PAUSE")
        if not os.path.exists(flag):
            return False
        print(f"[train] paused at update {self.update} (remove {flag} to continue)", flush=True)
        self.save()
        while os.path.exists(flag):
            self.write_status("paused", f"paused at update {self.update}", 0, 0)
            if self.stop_requested:
                return True
            if os.path.exists(os.path.join(self.run_dir, "STOP")):
                os.remove(os.path.join(self.run_dir, "STOP"))
                print("[train] STOP while paused", flush=True)
                return True
            time.sleep(2)
        print("[train] continuing", flush=True)
        return False

    def under_disk_floor(self) -> bool:
        floor = float(self.cfg["disk_floor_mb"])
        if floor <= 0:
            return False
        self.maintain_resources(force=True)
        # Env logs have a tighter cap than the human-readable trainer diagnostics.
        reclaimed = self.envs.trim_logs() if getattr(self, "envs", None) else 0
        if reclaimed:
            print(f"[train] trimmed {reclaimed} MB of Godot env logs", flush=True)
        free = free_mb(self.run_dir)
        if free >= floor:
            return False
        print(f"[train] disk floor reached: {free:.0f} MB free < {floor:.0f} MB "
              f"— checkpointing and exiting while the write can still succeed", flush=True)
        self.write_status("running", f"below disk_floor_mb ({free:.0f} MB free) — exiting", 0, 0,
                          stop_reason="disk")
        self.stop_reason = "disk"
        return True

    def over_memory_budget(self) -> bool:
        """True only when no rollout small enough to fit exists — otherwise SHRINK and
        carry on.

        The budget used to end the run. It is the elastic part of the process that pushes
        it over — the rollout buffer, whose size is the map's candidate count times the
        steps collected, and a company-scale town map is an order of magnitude heavier per
        step than the arena the defaults were set on. So town-8 exited every few updates on
        a limit it could simply have trained under: 3.6 GB of trainer against a 1.4 GB base
        is 2.2 GB of buffer, and the run needed a smaller buffer, not a restart (which
        rebuilds exactly the same buffer and exits again — 28 restarts overnight).

        Shrinking costs samples per update, not correctness: a short rollout is still an
        unbiased set of transitions, and ppo_update already handles a rollout cut short by
        rollout_budget_mb. Only a BASE process too big to hold any rollout is fatal, and
        that one still exits with a checkpoint and a reason."""
        limit = float(self.cfg["mem_limit_mb"])
        if limit <= 0:
            return False
        used = mem_report().get("total_mb", 0.0)
        if used < limit:
            return False
        # What the process costs with no rollout held: measured right after ppo_update
        # dropped the buffer (see train()), so it is the real floor, not an estimate.
        base = self._base_mb or used
        headroom = limit - base
        if headroom >= MIN_ROLLOUT_MB:
            new_budget = max(MIN_ROLLOUT_MB, min(headroom * 0.8, self.rollout_budget_mb * 0.6))
            if new_budget < self.rollout_budget_mb - 1:
                print(f"[train] memory {used:.0f} MB >= {limit:.0f} MB — rollout budget "
                      f"{self.rollout_budget_mb:.0f} -> {new_budget:.0f} MB "
                      f"(base {base:.0f} MB) and carrying on", flush=True)
                self.rollout_budget_mb = new_budget
                self.writer.add_scalar("speed/rollout_budget_mb", new_budget, self.global_step)
                return False
        print(f"[train] memory budget reached: {used:.0f} MB >= {limit:.0f} MB with a "
              f"{base:.0f} MB base — no rollout fits; checkpointing and exiting", flush=True)
        self.write_status("running", f"over mem_limit_mb ({used:.0f} MB) — exiting", 0, 0,
                          stop_reason="memory")
        self.stop_reason = "memory"
        return True

    def run_eval(self):
        """Greedy games vs HARD, every time. An eval that dies with its Godot env
        must not take the run with it — the win rate is a diagnostic, not the training
        signal, so a failed one is logged as such and training carries on."""
        started_at = time.perf_counter()
        full_every = int(self.cfg["eval_full_every"])
        full = full_every <= 0 or self.update % full_every == 0 or not self.has_eval_history()
        rec = os.path.join(self.run_dir, "replays", f"checkpoint_{self.global_step:09d}")
        row = {"step": self.global_step, "update": self.update, "time": time.time(),
               "phase": self.cfg["phase"], "stage": self.cfg["stage"]}
        opp = SCRIPTED
        try:
            r = self.evaluate(self.cfg["eval_games"], record_dir=rec,
                              keep=self.cfg["replays_per_checkpoint"])
        except EnvDied as e:
            print(f"[eval] vs {opp} aborted: {e}", flush=True)
            row[f"error_{opp}"] = str(e)
            self.envs.rebuild()
        else:
            row.update({f"{k}_{opp}": v for k, v in r.items()})
            score = (r["winrate"], r["value_diff"])
            if r["games"] >= 10 and score > self.champion_score:
                self.champion_score = score
                path = os.path.join(self.run_dir, f"champion_{self.global_step:09d}.pt")
                torch.save(self.state_dict(), path + ".tmp")
                os.replace(path + ".tmp", path)
                for old in glob.glob(os.path.join(self.run_dir, "champion_*.pt")):
                    if old != path:
                        os.remove(old)
            for k in ("winrate", "lossrate", "drawrate", "value_diff", "rounds", "stallrate",
                      "rout_winrate", "value_winrate", "illegal"):
                self.writer.add_scalar(f"eval/{k}_{opp}", r[k], self.global_step)
            print(f"[eval] step={self.global_step} vs {opp}: win {r['winrate']:.2f} "
                  f"draw {r['drawrate']:.2f} diff {r['value_diff']:+.2f} "
                  f"rounds {r['rounds']:.1f} outcomes {r['outcomes']}", flush=True)
        # Skill drills: each is a scenario only one tactic wins (flank the MG nest, screen
        # the tank, breach the wall...). Played vs standard HARD like the main eval, with
        # both sides of each drill (game k plays side k % 2), and scored per drill.
        nofog = int(self.cfg.get("eval_nofog_games") or 0)
        if full and nofog > 0:
            try:
                r2 = self.evaluate(nofog, fogs=[FOGS["off"]], suite="nofog")
            except EnvDied as e:
                print(f"[eval] fog-off eval aborted: {e}", flush=True)
                self.envs.rebuild()
            else:
                row["nofog"] = {k: r2[k] for k in ("winrate", "value_diff", "rounds")}
                for k in ("winrate", "lossrate", "drawrate", "value_diff", "rounds"):
                    self.writer.add_scalar(f"eval/{k}_{opp}_nofog", r2[k], self.global_step)
                print(f"[eval] fog off: win {r2['winrate']:.2f} diff {r2['value_diff']:+.2f}", flush=True)
        drills = list(self.cfg.get("drill_eval_maps") or [])
        if full and drills:
            per = max(1, int(self.cfg["drill_eval_games"]))
            per = max(2, per + per % 2)
            order = [m for m in drills for _ in range(per // 2)]
            # With 4 games a drill (the default in tactical.yaml) each drill is played from
            # both sides (game k plays side k % 2) AND both in fog and with fog off: games
            # 0-1 in fog, 2-3 without. Fog is keyed on k // 2 so it never coincides with side.
            fogs = [FOGS["off"] if ((k % per) // 2) % 2 == 1 else FOGS[self.cfg["fog"]]
                    for k in range(2 * len(order))]
            try:
                d = self.evaluate(2 * len(order), maps=order, fogs=fogs, suite="drills")
            except EnvDied as e:
                print(f"[eval] drills aborted: {e}", flush=True)
                self.envs.rebuild()
            else:
                row["drills"] = d["by_map"]
                for mp, wr in d["by_map"].items():
                    stem = os.path.splitext(mp)[0].removeprefix("drill_")
                    self.writer.add_scalar(f"eval/drill_{stem}_winrate", wr, self.global_step)
                self.writer.add_scalar("eval/drills_winrate", d["winrate"], self.global_step)
                print(f"[eval] drills: win {d['winrate']:.2f} " +
                      " ".join(f"{os.path.splitext(m)[0]}={v:.2f}" for m, v in sorted(d["by_map"].items())),
                      flush=True)
        if full and self.cfg["heldout_eval_maps"] and self.cfg["heldout_eval_games"] > 0:
            try:
                row["heldout"] = self.evaluate(
                    self.cfg["heldout_eval_games"],
                    maps=[m for m in self.cfg["heldout_eval_maps"] for _ in range(2)],
                    suite="heldout", round_cap=self.cfg["heldout_round_cap"],
                    fogs=[FOGS[self.cfg["fog"]]] * 2 + [FOGS["off"]] * 2)
                for k in ("winrate", "rout_winrate", "value_winrate", "illegal"):
                    self.writer.add_scalar(f"eval/heldout_{k}", row["heldout"][k], self.global_step)
            except EnvDied as e:
                row["heldout_error"] = str(e)
                self.envs.rebuild()
        row["seconds"] = time.perf_counter() - started_at
        row["full_suite"] = full
        self.writer.add_scalar("speed/eval_secs", row["seconds"], self.global_step)
        self.writer.flush()
        self.last_eval = row
        with open(os.path.join(self.run_dir, "eval_log.jsonl"), "a") as f:
            f.write(json.dumps(row) + "\n")
        self.prune()

    def log(self, info: dict, losses: dict, update_secs: float):
        st = info["stats"]
        w, s = self.writer, self.global_step
        steps = info.get("steps") or self.cfg["rollout_steps"] * self.cfg["n_envs"]
        w.add_scalar("speed/env_steps_per_sec", steps / max(1e-6, info["seconds"]), s)
        w.add_scalar("speed/update_secs", update_secs, s)
        w.add_scalar("speed/collect_secs", info["seconds"], s)
        w.add_scalar("speed/train_steps_per_sec", steps / max(1e-6, info["seconds"] + update_secs), s)
        for k, v in info.get("timings", {}).items():
            w.add_scalar(f"speed/{k}", v, s)
        if st["obs_ms"]:
            w.add_scalar("speed/env_obs_ms", float(np.mean(st["obs_ms"])), s)
        w.add_scalar("speed/matches_done", self.matches_done, s)
        if st["legal_ms"]:
            # Where a slow step actually goes: on company-sized maps the legal-intent
            # enumerator is most of it, and max_actors is the knob that moves this number.
            w.add_scalar("speed/env_legal_ms", float(np.mean(st["legal_ms"])), s)
        mem = mem_report()
        for k in ("rss_mb", "envs_mb", "free_mb"):
            if k in mem:
                w.add_scalar(f"mem/{k}", mem[k], s)
        for k, v in self.gpu_memory().items():
            w.add_scalar(f"mem/{k}", v, s)
        w.add_scalar("mem/run_dir_mb", self.disk_mb(), s)
        for k, v in losses.items():
            w.add_scalar(f"ppo/{k}", v, s)
        # epochs_run below cfg["epochs"] means target_kl braked the update. Persistently
        # braking is the signal to lower lr, not to raise target_kl.
        w.add_scalar("ppo/epochs_run", losses.get("epochs_run", self.cfg["epochs"]), s)
        if st["win"]:
            by_opp = defaultdict(list)
            by_map = defaultdict(list)
            for label, mp, res in st["result"]:
                by_opp[label.split(":")[0]].append(1.0 if res == "win" else 0.0)
                by_map[mp].append(1.0 if res == "win" else 0.0)
            for kind, vals in by_opp.items():
                w.add_scalar(f"train/winrate_vs_{kind}", float(np.mean(vals)), s)
            for mp, vals in by_map.items():
                w.add_scalar(f"map/{os.path.splitext(mp)[0]}_winrate", float(np.mean(vals)), s)
            # Per-map match shape, not just the win rate. On a mixed pool the pooled
            # rounds/value_diff are an average over tasks of different length and
            # lethality, which is a number no single map ever produces.
            by_map_rounds = defaultdict(list)
            by_map_vd = defaultdict(list)
            for (label, mp, res), rnd, vd in zip(st["result"], st["rounds"], st["value_diff"]):
                by_map_rounds[mp].append(rnd)
                by_map_vd[mp].append(vd)
            for mp, vals in by_map_rounds.items():
                w.add_scalar(f"map/{os.path.splitext(mp)[0]}_rounds", float(np.mean(vals)), s)
            for mp, vals in by_map_vd.items():
                w.add_scalar(f"map/{os.path.splitext(mp)[0]}_value_diff", float(np.mean(vals)), s)
            # Is it attacking? Shots per game and the share that damaged an enemy. Firing is
            # not attacking: town-8 fired its tank cannon 1202 times in 12 tank-map games and
            # 6% did damage (the scripted AI: 56%), which no win rate or action share shows.
            aim = defaultdict(lambda: [0, 0, 0])
            for mp, shots, hit in st["aim"]:
                aim[mp][0] += shots
                aim[mp][1] += hit
                aim[mp][2] += 1
            for mp, (shots, hit, games) in aim.items():
                stem = os.path.splitext(mp)[0]
                w.add_scalar(f"map/{stem}_shots", shots / games, s)
                if shots:
                    w.add_scalar(f"map/{stem}_hit_rate", hit / shots, s)
            shots_all = sum(v[0] for v in aim.values())
            if shots_all:
                w.add_scalar("train/shot_hit_rate", sum(v[1] for v in aim.values()) / shots_all, s)
            w.add_scalar("train/drawrate", float(np.mean(st["draw"])), s)
            w.add_scalar("train/match_rounds", float(np.mean(st["rounds"])), s)
            w.add_scalar("train/value_diff_end", float(np.mean(st["value_diff"])), s)
            w.add_scalar("train/illegal_per_match", float(np.mean(st["illegal"])), s)
        total_u = max(1, sum(info["usage_units"].values()))
        for t, c in info["usage_units"].items():
            w.add_scalar(f"usage/unit_{UNIT_NAMES[t]}", c / total_u, s)
        total_k = max(1, sum(info["usage_kinds"].values()))
        for k, c in info["usage_kinds"].items():
            w.add_scalar(f"usage/kind_{k}", c / total_k, s)
        # Same shares again, split by map. Kept UNDER a separate prefix rather than
        # replacing the pooled tags: the pooled series is what every run before this one
        # recorded, and rewriting its meaning would silently invalidate the comparisons
        # already drawn from it. Shares are normalised WITHIN each map, so each map's
        # bands sum to 1 and a map that happened to supply few decisions this update is
        # not flattened by one that supplied many.
        for mp, counter in info.get("usage_kinds_map", {}).items():
            stem = os.path.splitext(mp)[0]
            tot = max(1, sum(counter.values()))
            for k, c in counter.items():
                w.add_scalar(f"usage_map/{stem}/kind_{k}", c / tot, s)
            for k, count in info.get("offered", {}).get(mp, {}).items():
                chosen = counter[k]
                w.add_scalar(f"actions/{stem}/{k}_offered", count, s)
                w.add_scalar(f"actions/{stem}/{k}_chosen", chosen, s)
                w.add_scalar(f"actions/{stem}/{k}_accepted",
                             info.get("accepted", {}).get(mp, {}).get(k, 0), s)
        for mp, counter in info.get("usage_units_map", {}).items():
            stem = os.path.splitext(mp)[0]
            tot = max(1, sum(counter.values()))
            for t, c in counter.items():
                w.add_scalar(f"usage_map/{stem}/unit_{UNIT_NAMES[t]}", c / tot, s)
        self.log_tactics(st.get("tac", []), s)
        by_fog = defaultdict(list)
        for fog, won in st.get("fog_win", []):
            by_fog["off" if fog == FOGS["off"] else "on"].append(won)
        for k, v in by_fog.items():
            w.add_scalar(f"train/winrate_fog_{k}", float(np.mean(v)), s)
        w.add_scalar("train/shaping_scale", self.shaping_scale(), s)
        if self.pfsp:
            w.add_scalar("league/pool_winrate", sum(v[1] for v in self.pfsp.values())
                         / max(1, sum(v[0] for v in self.pfsp.values())), s)
        w.add_scalar("train/curriculum_stage", self.cfg["stage"], s)
        w.add_scalar("train/phase", 0 if self.cfg["phase"] == "A" else 1, s)
        w.flush()
        wr = f"{np.mean(st['win']):.2f}" if st["win"] else "-"
        print(f"[train] upd={self.update} step={s} matches={self.matches_done} win={wr} "
              f"pl={losses['policy_loss']:+.3f} vl={losses['value_loss']:.3f} "
              f"ent={losses['entropy']:.2f} kl={losses['approx_kl']:.4f} "
              f"hit={self._aim_text(st)} "
              f"env={info['seconds']:.0f}s upd={update_secs:.0f}s", flush=True)

    def log_tactics(self, games: list, s: int) -> None:
        """Is it using its army well? Per map (tac/<map>/...) and pooled (tac/all/...):
        per unit type — share of actions, hit rate, kills and losses per game — plus
        multi-AP moves per game and the share of the army left under fire without cover
        at end of turn (exposure). A policy that wins on rifles alone, parks the tank or
        never launches a drone shows up here long before it shows in a win rate."""
        if not games:
            return
        groups: dict[str, list[dict]] = defaultdict(list)
        for mp, tac in games:
            groups[os.path.splitext(mp)[0]].append(tac)
            groups["all"].append(tac)
        w = self.writer
        for stem, tacs in groups.items():
            n = len(tacs)
            pre = f"tac/{stem}/"
            w.add_scalar(pre + "exposure", float(np.mean([t.get("exposure", 0.0) for t in tacs])), s)
            w.add_scalar(pre + "multi_ap_per_game", sum(t.get("multi_ap", 0) for t in tacs) / n, s)
            act, shots, hits, kills, lost, fielded = (Counter() for _ in range(6))
            for t in tacs:
                act.update(t.get("act", {}))
                shots.update(t.get("shots", {}))
                hits.update(t.get("hits", {}))
                kills.update(t.get("kills", {}))
                lost.update(t.get("lost", {}))
                fielded.update(t.get("fielded", {}))
            total = max(1, sum(act.values()))
            # A type seen in an earlier update but absent now must read 0, not keep its old
            # share: TensorBoard holds the last value of a tag, and the dashboard's table
            # would otherwise add up stale shares to more than 100%.
            seen = self._tac_kinds.setdefault(stem, set())
            seen |= set(act) | set(fielded)
            for kind in seen:
                w.add_scalar(pre + f"act_{kind}", act[kind] / total, s)
                w.add_scalar(pre + f"kills_{kind}", kills[kind] / n, s)
                if shots[kind]:
                    w.add_scalar(pre + f"hit_{kind}", hits[kind] / shots[kind], s)
                if fielded[kind]:
                    w.add_scalar(pre + f"lost_{kind}", lost[kind] / fielded[kind], s)

    @staticmethod
    def _aim_text(st: dict) -> str:
        shots = sum(x[1] for x in st.get("aim", []))
        return f"{sum(x[2] for x in st.get('aim', [])) / shots:.0%}" if shots else "-"


# --- CLI ----------------------------------------------------------------------------------

def run_dir_for(branch: str) -> str:
    return os.path.join(RUNS, branch)


def refuse_if_running(rd: str):
    """Two trainers on one branch would race on latest.pt and the TensorBoard log."""
    try:
        with open(os.path.join(rd, "status.json")) as f:
            st = json.load(f)
        if st.get("state") in ("running", "paused"):
            os.kill(int(st["pid"]), 0)
            sys.exit(f"{os.path.basename(rd)} is already training (pid {st['pid']}, "
                     f"{st['state']}) — stop it first")
    except (OSError, ValueError, KeyError):
        pass


def clear_flags(rd: str) -> None:
    """A STOP or PAUSE left behind by the previous run would stop or freeze the new one
    on its first update."""
    for name in ("STOP", "PAUSE"):
        try:
            os.remove(os.path.join(rd, name))
        except OSError:
            pass


def cmd_start(a):
    cfg = load_config(a.config)
    rd = run_dir_for(a.branch)
    refuse_if_running(rd)
    if os.path.exists(os.path.join(rd, "latest.pt")):
        sys.exit(f"branch {a.branch} exists — use resume, or pick another name")
    os.makedirs(rd, exist_ok=True)
    clear_flags(rd)
    Trainer(rd, cfg, pick_device(cfg)).train()


def pick_device(cfg: dict) -> str:
    """Where the PPO update runs (rollouts always act on the CPU). `auto` takes a GPU only
    if it computes the real network the way the CPU does, so a backend missing an op or
    getting one wrong costs speed, not the run."""
    d = cfg.get("device", "cpu")
    if d != "auto":
        return d
    gpus = []
    if torch.cuda.is_available():
        gpus.append("cuda")
    if getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():
        gpus.append("mps")
    for g in gpus:
        if device_matches_cpu(g):
            print(f"[train] PPO update on {g}", flush=True)
            return g
    return "cpu"


def device_matches_cpu(dev: str) -> bool:
    """One forward + backward of PolicyNet on `dev` against the CPU: logits, value and the
    first conv's gradient must agree."""
    try:
        torch.manual_seed(0)
        cpu_net = PolicyNet()
        dev_net = copy.deepcopy(cpu_net).to(dev)
        B, N = 3, 7
        batch = (torch.rand(B, N_CHANNELS, CANVAS, CANVAS), torch.rand(B, FLAT_DIM),
                 torch.rand(B, N, CAND_DIM), torch.randint(-1, CANVAS * CANVAS, (B, N, 2)),
                 torch.rand(B, N) < 0.8)
        batch[4][:, 0] = True
        got = []
        for net, d in ((cpu_net, "cpu"), (dev_net, dev)):
            logits, value = net(*(t.to(d) for t in batch))
            (torch.log_softmax(logits, 1)[:, 0].sum() + value.sum()).backward()
            got.append((logits.detach().cpu()[batch[4]], value.detach().cpu(),
                        net.conv[0].weight.grad.cpu()))
        ok = all(torch.allclose(a, b, atol=1e-3, rtol=1e-3) for a, b in zip(*got))
        if not ok:
            print(f"[train] {dev} disagrees with the CPU on the policy net; updating on cpu", flush=True)
        return ok
    except Exception as e:  # noqa: BLE001 - any backend failure means "don't use it"
        print(f"[train] {dev} failed its self-check ({type(e).__name__}: {e}); updating on cpu", flush=True)
        return False


def cmd_resume(a):
    rd = run_dir_for(a.branch)
    latest = os.path.join(rd, "latest.pt")
    if not os.path.exists(latest):
        sys.exit(f"no checkpoint in {rd}")
    refuse_if_running(rd)
    clear_flags(rd)
    cfg = load_config(a.config) if a.config else None
    if cfg is not None and int(cfg.get("shaping_decay_start", 0)) < 0:
        # "-1 = from when this config was first applied": a resume that hands the same
        # config file in again must keep the run's anchor, not restart the decay from now.
        prev = os.path.join(rd, "config.yaml")
        if os.path.exists(prev):
            with open(prev) as f:
                anchor = int((yaml.safe_load(f) or {}).get("shaping_decay_start", -1))
            if anchor >= 0:
                cfg["shaping_decay_start"] = anchor
    cfg = cfg or load_config(os.path.join(rd, "config.yaml"))
    t = Trainer(rd, cfg, pick_device(cfg))
    t.load(latest, keep_cfg=True)
    t.train()


def cmd_preflight(a):
    cfg = load_config(a.config)
    refresh_class_cache(cfg["godot"])
    env = GodotEnv(cfg["godot"])
    try:
        rows = preflight_config(cfg, env)
        print(json.dumps(rows, indent=2))
    finally:
        env.close()


def cmd_fork(a):
    rd = run_dir_for(a.branch)
    if os.path.exists(rd):
        sys.exit(f"branch {a.branch} already exists")
    src_cfg = os.path.join(os.path.dirname(os.path.abspath(a.checkpoint)), "config.yaml")
    cfg = load_config(a.config or (src_cfg if os.path.exists(src_cfg) else None))
    t = Trainer(rd, cfg, pick_device(cfg))
    t.load(a.checkpoint, keep_cfg=True)
    t.parent = os.path.abspath(a.checkpoint)
    t.champion_score = (-1.0, -1e30)  # the new branch needs its own measured champion
    t.save()
    print(f"[fork] {a.branch} <- {a.checkpoint} (step {t.global_step})")
    t.train()


def cmd_stop(a):
    rd = run_dir_for(a.branch)
    open(os.path.join(rd, "STOP"), "w").close()
    print(f"[stop] requested; {a.branch} saves a checkpoint after its current update")


def cmd_pause(a):
    rd = run_dir_for(a.branch)
    if not os.path.isdir(rd):
        sys.exit(f"no such branch: {a.branch}")
    open(os.path.join(rd, "PAUSE"), "w").close()
    print(f"[pause] requested; {a.branch} checkpoints after its current update and holds "
          f"(its Godot envs stay up, so continuing is instant)")


def cmd_continue(a):
    rd = run_dir_for(a.branch)
    flag = os.path.join(rd, "PAUSE")
    if os.path.exists(flag):
        os.remove(flag)
    print(f"[continue] {a.branch} resumes within a couple of seconds")


def cmd_status(a):
    branches = [a.branch] if a.branch else sorted(os.listdir(RUNS)) if os.path.exists(RUNS) else []
    for b in branches:
        rd = run_dir_for(b)
        latest = os.path.join(rd, "latest.pt")
        if not os.path.exists(latest):
            continue
        ck = torch.load(latest, map_location="cpu", weights_only=False)
        cks = glob.glob(os.path.join(rd, "ckpt_*.pt"))
        age = (time.time() - ck.get("saved_at", 0)) / 60
        print(f"{b}: step={ck['global_step']} update={ck['update']} matches={ck['matches_done']} "
              f"phase={ck['cfg']['phase']} stage={ck['cfg']['stage']} maps={len(ck['cfg']['maps'])} "
              f"checkpoints={len(cks)} parent={ck.get('parent')} saved {age:.0f} min ago")
        ev = os.path.join(rd, "eval_log.jsonl")
        if os.path.exists(ev):
            with open(ev) as f:
                lines = f.read().strip().splitlines()
            if lines:
                print("   last eval:", lines[-1])


def cmd_eval(a):
    ck = torch.load(a.checkpoint, map_location="cpu", weights_only=False)
    cfg = ck["cfg"]
    t = Trainer(os.path.join(RUNS, "_eval"), cfg)
    t.load(a.checkpoint, keep_cfg=True)
    t.envs = VecEnv(cfg["n_envs"], cfg["godot"],
                    log_dir=os.path.join(t.run_dir, "envlogs"))
    try:
        r = t.evaluate(a.games, record_dir=a.record, keep=a.games if a.record else 0)
        print(json.dumps(r))
    finally:
        t.envs.close()


def cmd_export(a):
    ck = torch.load(a.checkpoint, map_location="cpu", weights_only=False)
    net = PolicyNet()
    load_compat(net, ck["model"])
    net.eval()
    from features import FLAT_DIM
    grid = torch.zeros(1, N_CHANNELS, CANVAS, CANVAS)
    flat = torch.zeros(1, FLAT_DIM)
    cand = torch.zeros(1, 8, CAND_DIM)
    cells = torch.zeros(1, 8, 2, dtype=torch.int64)
    torch.onnx.export(OnnxWrapper(net), (grid, flat, cand, cells), a.out, opset_version=17,
                      input_names=["grid", "flat", "cand", "cells"], output_names=["logits", "value"],
                      dynamic_axes={"cand": {1: "n"}, "cells": {1: "n"}, "logits": {0: "n"}},
                      dynamo=False)
    print(f"[export] {a.out} ({os.path.getsize(a.out)} bytes) — policy logits + value head")


PLAY_DIR = os.path.join(os.path.dirname(PROJECT), "mcf-play-latest")


def latest_game_dir() -> str:
    """The game "Play vs latest" opens: the newest main from GitHub, not this checkout.

    This checkout is whatever the training run is on — often a branch or a commit weeks
    behind — so the button used to open that fixed version. The newest main is kept in a
    sibling worktree (PLAY_DIR), fetched and hard-reset on every play; training is never
    touched. Hard reset, not checkout: Godot's import rewrites files in the worktree, and a
    checkout over them refused — which silently fell back to the old game.
    Raises if the newest game cannot be had: opening an old one quietly is the bug."""
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")

    def git(*args, cwd=PROJECT):
        r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True,
                           timeout=180, env=env)
        if r.returncode != 0:
            raise RuntimeError(f"git {' '.join(args)}: {(r.stderr or r.stdout).strip()}")
        return r.stdout.strip()

    try:
        git("fetch", "--quiet", "origin", "main")
    except RuntimeError:
        # The dashboard runs in the background (nohup), where the SSH key or its agent may
        # not be reachable; the repository is public, so the same main comes over HTTPS
        # with no key at all.
        url = _public_url(git("remote", "get-url", "origin"))
        git("fetch", "--quiet", url, "+refs/heads/main:refs/remotes/origin/main")
    ok = os.path.isdir(PLAY_DIR)
    if ok:
        try:
            git("reset", "--quiet", "--hard", "origin/main", cwd=PLAY_DIR)
        except RuntimeError:
            ok = False
    if not ok:
        # Missing or broken (deleted by hand, stale worktree record): start it over.
        shutil.rmtree(PLAY_DIR, ignore_errors=True)
        git("worktree", "prune")
        git("worktree", "add", "--force", "--detach", PLAY_DIR, "origin/main")
    return PLAY_DIR


def _public_url(url: str) -> str:
    """git@github.com:owner/repo.git or ssh://git@github.com/owner/repo.git -> https://github.com/owner/repo.git"""
    url = url.strip()
    if url.startswith("git@"):
        host, path = url[4:].split(":", 1)
        return f"https://{host}/{path}"
    if url.startswith("ssh://"):
        rest = url[len("ssh://"):]
        return "https://" + rest.split("@", 1)[-1]
    return url


def game_version(path: str) -> str:
    try:
        return subprocess.run(["git", "log", "-1", "--format=%h %cd · %s", "--date=short"],
                              cwd=path, capture_output=True, text=True,
                              timeout=30).stdout.strip()
    except Exception:  # noqa: BLE001
        return "?"


def cmd_play(a):
    """Real game against a checkpoint: a local policy server plus the game, opened straight
    on the lobby with that policy already in the opponent slot (`--vs-latest`).

    Launching the game at the main menu was the reason "Play vs latest" did not play the
    latest: the solo lobby seats a scripted AI (Medium) by default, so unless you switched
    the slot to AI - Learned by hand, the policy server sat idle and you played the script."""
    import socket as _socket

    def taken(p: int) -> bool:
        s = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
        try:
            return s.connect_ex(("127.0.0.1", p)) == 0
        finally:
            s.close()

    ck = torch.load(a.checkpoint, map_location="cpu", weights_only=False)
    cfg = with_defaults(ck.get("cfg", {}))
    # A stale script-class cache opens the game on a gray window (see refresh_class_cache).
    refresh_class_cache(a.godot)
    # A server left over from an earlier `play` still holding the port would have the game
    # silently talk to THAT checkpoint. Refusing (the old behaviour) turned into "nothing
    # happens" behind the dashboard button; taking the next free port gives the same
    # guarantee — the game is pointed only at the server started here.
    port = next((p for p in range(a.port, a.port + 20) if not taken(p)), None)
    if port is None:
        sys.exit(f"ports {a.port}-{a.port + 19} are all taken — stop old policy servers "
                 f"(pkill -f policy_server.py)")

    # Serve with the same observation/features code as the game being launched.
    # The training checkout can be weeks older than that game.
    try:
        game = latest_game_dir()
    except Exception as e:
        sys.exit(f"could not get the newest game from GitHub: {e}")
    refresh_class_cache(a.godot, game)
    srv = subprocess.Popen([sys.executable, os.path.join(game, "rl", "policy_server.py"),
                            a.checkpoint, "--port", str(port)])
    try:
        # Wait for it to actually listen, and fail loudly if it never does.
        deadline = time.time() + 30.0
        while not taken(port):
            if srv.poll() is not None:
                sys.exit(f"policy server exited immediately (rc={srv.returncode}) — "
                         f"the game would have fallen back to the scripted AI")
            if time.time() > deadline:
                sys.exit(f"policy server did not start listening on {port} within 30s")
            time.sleep(0.2)
        branch = os.path.basename(os.path.dirname(os.path.abspath(a.checkpoint)))
        label = (f"{branch} · update {ck.get('update', '?')} · "
                 f"step {int(ck.get('global_step') or 0):,}")
        print(f"[play] serving {a.checkpoint} on :{port}\n"
              f"       {label} | round_cap {cfg['round_cap']} max_actors {cfg['max_actors']} "
              f"max_candidates {cfg['max_candidates']}", flush=True)

        # The controller has to show the policy a candidate list of the same shape it
        # trained on, so the checkpoint's own caps travel with it into the game — and so
        # does round_cap, which the observation normalises the round number by.
        env = dict(os.environ, MCF_RL_POLICY=f"127.0.0.1:{port}",
                   MCF_RL_MAX_ACTORS=str(cfg["max_actors"]),
                   MCF_RL_MAX_CANDIDATES=str(cfg["max_candidates"]),
                   MCF_RL_ROUND_CAP=str(cfg["round_cap"]),
                   MCF_RL_MODEL_LABEL=label)
        print(f"[play] game: {game_version(game)}", flush=True)
        subprocess.call([a.godot, "--path", game, "--", "--vs-latest"], env=env)
    finally:
        srv.terminate()
        try:
            srv.wait(timeout=5)
        except subprocess.TimeoutExpired:
            srv.kill()
            srv.wait()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = p.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("preflight"); s.add_argument("config"); s.set_defaults(fn=cmd_preflight)
    s = sp.add_parser("start"); s.add_argument("config"); s.add_argument("--branch", required=True); s.set_defaults(fn=cmd_start)
    s = sp.add_parser("resume"); s.add_argument("branch"); s.add_argument("--config"); s.set_defaults(fn=cmd_resume)
    s = sp.add_parser("fork"); s.add_argument("checkpoint"); s.add_argument("--branch", required=True); s.add_argument("--config"); s.set_defaults(fn=cmd_fork)
    s = sp.add_parser("stop"); s.add_argument("branch"); s.set_defaults(fn=cmd_stop)
    s = sp.add_parser("pause"); s.add_argument("branch"); s.set_defaults(fn=cmd_pause)
    s = sp.add_parser("continue"); s.add_argument("branch"); s.set_defaults(fn=cmd_continue)
    s = sp.add_parser("status"); s.add_argument("branch", nargs="?"); s.set_defaults(fn=cmd_status)
    s = sp.add_parser("eval"); s.add_argument("checkpoint"); s.add_argument("--games", type=int, default=10)
    s.add_argument("--record"); s.set_defaults(fn=cmd_eval)
    s = sp.add_parser("export"); s.add_argument("checkpoint"); s.add_argument("out"); s.set_defaults(fn=cmd_export)
    s = sp.add_parser("play"); s.add_argument("checkpoint"); s.add_argument("--port", type=int, default=7791)
    s.add_argument("--godot", default="godot"); s.set_defaults(fn=cmd_play)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
