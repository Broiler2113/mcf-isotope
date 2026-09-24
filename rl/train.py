#!/usr/bin/env python
"""RL Enemy AI v1 trainer and launcher (spec Sections 6, 8, 9, 10, 13.1).

    train.py start  <config.yaml> --branch NAME     new run (rl/runs/NAME)
    train.py resume <branch>                          continue from latest checkpoint
    train.py fork   <checkpoint.pt> --branch NAME [--config c.yaml]
    train.py stop   <branch>                          graceful stop after this update
    train.py pause  <branch>                          checkpoint and hold; envs stay up
    train.py continue <branch>                        release a paused run
    train.py status [branch]
    train.py eval   <checkpoint.pt> [--games N] [--opponent normal|hard|easy] [--record DIR]
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
import json
import os
import random
import shutil
import signal
import subprocess
import sys
import time
import traceback
from collections import Counter, OrderedDict, defaultdict
from dataclasses import dataclass

import numpy as np
import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import torch_compat  # noqa: F401,E402
import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402
from torch.utils.tensorboard import SummaryWriter  # noqa: E402

from features import (CAND_DIM, CANVAS, N_CHANNELS, Sparse, candidate_rows,  # noqa: E402
                      flat_vector, grid_tensor)
from mcf_env import (EASY, EXTERNAL, HARD, NORMAL, PROJECT, EnvDied,  # noqa: E402
                     EpisodeConfig, VecEnv)
from model import OnnxWrapper, PolicyNet  # noqa: E402

RUNS = os.path.join(PROJECT, "rl", "runs")
OPPONENTS = {"easy": EASY, "normal": NORMAL, "hard": HARD}
FOGS = {"off": 0, "standard": 1, "realistic": 2}
UNIT_NAMES = ["light_infantry", "heavy_infantry", "machinegunner", "sniper", "anti_tank",
              "engineer", "flamethrower", "assault", "marksman", "miner", "sapper",
              "shield_bearer", "drone_operator", "commander", "civilian", "drone",
              "tank", "shuttle", "borg"]

DEFAULTS = dict(
    godot=os.environ.get("GODOT", "godot"),   # rl/.env sets GODOT; a config's godot: overrides
    n_envs=2, maps=["rl/maps/arena_34x26.json"], stage=1,
    phase="A", opponent="normal", pool_ai_fraction=0.15, pool_size=6,
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
    # Which scripted opponents an evaluation measures against. HARD only, because NORMAL
    # was very nearly the same measurement: six arena games came back identical to their
    # HARD counterparts step for step, and AIController differentiates the two in exactly
    # one line (a shot-scoring tiebreak at 1053) — everything else keyed off difficulty is
    # EASY-only. Two columns that agree by construction cost twice the eval time and say
    # one thing. HARD is also the graduation opponent (8.2), so it is the one that counts.
    eval_opponents=["hard"],
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
    rollout_budget_mb=0,      # >0: end a rollout early once the buffer reaches this
)


def load_config(path: str | None) -> dict:
    cfg = dict(DEFAULTS)
    if path:
        with open(path) as f:
            cfg.update(yaml.safe_load(f) or {})
    cfg["maps"] = [m if os.path.isabs(m) else os.path.join(PROJECT, m) for m in cfg["maps"]]
    for m in cfg["maps"]:
        if not os.path.exists(m):
            sys.exit(f"map not found: {m}")
    bad = [o for o in cfg["eval_opponents"] if o not in OPPONENTS]
    if bad:
        sys.exit(f"eval_opponents: unknown {bad}; pick from {sorted(OPPONENTS)}")
    return cfg


def with_defaults(cfg: dict) -> dict:
    """A config read out of an old checkpoint predates keys added since. Fill them in
    rather than sprinkling .get() over the trainer."""
    return dict(DEFAULTS) | dict(cfg or {})


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
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
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
    grid = np.zeros((B, N_CHANNELS, CANVAS, CANVAS), dtype=np.float32)
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


def encode(resp: dict) -> tuple[Sparse, np.ndarray, Sparse, np.ndarray]:
    obs = resp["obs"]
    g = Sparse(grid_tensor(obs))
    f = flat_vector(obs)
    c, cells = candidate_rows(obs, resp["legal"])
    return g, f, Sparse(c), cells.astype(np.int32)


def choose(net: PolicyNet, encoded: list, device, greedy=False):
    steps = [Step(g, f, c, cl, 0, 0.0, 0.0) for g, f, c, cl in encoded]
    batch = collate(steps, device)
    a, lp, v = net.act(*batch, greedy=greedy)
    return a.cpu().numpy(), lp.cpu().numpy(), v.cpu().numpy()


# --- trainer ---------------------------------------------------------------------------

class Trainer:
    def __init__(self, run_dir: str, cfg: dict, device="cpu"):
        self.run_dir = run_dir
        self.cfg = with_defaults(cfg)
        self.device = device
        os.makedirs(run_dir, exist_ok=True)
        self.net = PolicyNet().to(device)
        self.opt = torch.optim.Adam(self.net.parameters(), lr=self.cfg["lr"], eps=1e-5)
        self.global_step = 0
        self.update = 0
        self.matches_done = 0
        self.map_idx = 0
        self.parent = None
        self.rng = random.Random(self.cfg["seed"])
        self.writer = SummaryWriter(os.path.join(run_dir, "tb"))
        self.envs: VecEnv | None = None
        self.stop_requested = False
        # Ordered so the least recently used frozen opponent is the one evicted: one
        # PolicyNet per pool member is a few MB, and an unbounded dict grew without end.
        self.pool_cache: OrderedDict[str, PolicyNet] = OrderedDict()
        self.episode_seed = self.cfg["seed"] * 1000
        self._last_status = 0.0
        self.last_eval: dict = {}
        self._disk = (0.0, 0.0)          # (measured at, MB)

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
        return dict(model=self.net.state_dict(), opt=self.opt.state_dict(), cfg=self.cfg,
                    global_step=self.global_step, update=self.update,
                    matches_done=self.matches_done, map_idx=self.map_idx,
                    parent=self.parent, rng=self.rng.getstate(),
                    episode_seed=self.episode_seed, branch=os.path.basename(self.run_dir),
                    saved_at=time.time())

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
        meta = {k: v for k, v in sd.items() if k not in ("model", "opt", "rng")}
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
            for path in cks[:-keep_n]:
                try:
                    step = int(os.path.basename(path)[5:-3])
                except ValueError:
                    continue
                if every > 0 and step % every == 0:
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

    def write_status(self, state: str, activity: str = "", done: int = 0, total: int = 0, **extra):
        """Heartbeat for the dashboard: who is training, how far, what it is doing right now
        (activity + done/total progress), and whether the pid is alive. Written at every
        stage change and every few seconds inside a rollout, so "nothing moved" is visible.

        Carries memory and disk too. When the OS kills the run there is no exception to
        catch and no traceback to write — the last heartbeat before the kill is the only
        evidence, so it has to say what the run was costing at that moment."""
        st = dict(state=state, pid=os.getpid(), step=self.global_step, update=self.update,
                  matches=self.matches_done, phase=self.cfg["phase"], stage=self.cfg["stage"],
                  activity=activity, done=done, total=total, time=time.time(),
                  next_eval_update=self.next_eval_update(), eval=self.last_eval,
                  disk_mb=self.disk_mb(), disk_free_mb=round(free_mb(self.run_dir)),
                  **mem_report(), **extra)
        self._last_status = time.time()
        tmp = os.path.join(self.run_dir, "status.json.tmp")
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, os.path.join(self.run_dir, "status.json"))

    def load(self, path: str, keep_cfg: bool = False):
        ck = torch.load(path, map_location=self.device, weights_only=False)
        self.net.load_state_dict(ck["model"])
        self.opt.load_state_dict(ck["opt"])
        if not keep_cfg:
            self.cfg = with_defaults(ck["cfg"])
        self.global_step = ck["global_step"]
        self.update = ck["update"]
        self.matches_done = ck["matches_done"]
        self.map_idx = ck["map_idx"] % max(1, len(self.cfg["maps"]))
        self.parent = ck.get("parent")
        self.rng.setstate(ck["rng"])
        self.episode_seed = ck.get("episode_seed", self.episode_seed)
        for g in self.opt.param_groups:
            g["lr"] = self.cfg["lr"]

    # -- opponents (8.2) --
    def pool_checkpoints(self) -> list[str]:
        cks = sorted(glob.glob(os.path.join(self.run_dir, "ckpt_*.pt")))
        return cks[-self.cfg["pool_size"]:]

    def pool_net(self, path: str) -> PolicyNet:
        if path == "self":
            net = copy.deepcopy(self.net).eval()
            self.pool_cache["self"] = net
            return net
        if path not in self.pool_cache:
            net = PolicyNet().to(self.device)
            net.load_state_dict(torch.load(path, map_location=self.device, weights_only=False)["model"])
            self.pool_cache[path] = net.eval()
            # The pool is pool_size members plus "self"; anything beyond that is a
            # checkpoint that rotated out of the pool and will not be asked for again.
            while len(self.pool_cache) > self.cfg["pool_size"] + 1:
                self.pool_cache.popitem(last=False)
        self.pool_cache.move_to_end(path)
        return self.pool_cache[path]

    def pick_opponent(self) -> tuple[int, str]:
        """(env opponent code, label). Phase A: the scripted AI. Phase B: the pool."""
        if self.cfg["phase"] == "A" or self.rng.random() < self.cfg["pool_ai_fraction"]:
            return OPPONENTS[self.cfg["opponent"]], "ai:" + self.cfg["opponent"]
        members = ["self"] + self.pool_checkpoints()
        return EXTERNAL, "pool:" + self.rng.choice(members)

    def next_episode(self, record: bool = False) -> tuple[EpisodeConfig, str]:
        # Rotation: every map_rotate_matches completed matches, the next map (8.2.2).
        maps = self.cfg["maps"]
        self.map_idx = (self.matches_done // self.cfg["map_rotate_matches"]) % len(maps)
        opp, label = self.pick_opponent()
        self.episode_seed += 1
        cfg = EpisodeConfig(
            map_path=maps[self.map_idx], seed=self.episode_seed,
            side=self.episode_seed % 2, opponent=opp, round_cap=self.cfg["round_cap"], max_steps=self.cfg.get("max_steps", 3000),
            civilians=self.cfg["civilians"], random_events=self.cfg["random_events"],
            fog=FOGS[self.cfg["fog"]], friendly_fire=self.cfg["friendly_fire"], record=record,
            max_candidates=self.cfg["max_candidates"], max_actors=self.cfg["max_actors"],
        )
        return cfg, label

    # -- rollout (5.1) --
    def collect(self) -> tuple[list[list[Step]], dict]:
        cfg = self.cfg
        n = len(self.envs)
        T = cfg["rollout_steps"]
        buffers: list[list[Step]] = [[] for _ in range(n)]
        carry = [0.0] * n
        labels = [""] * n
        stats = defaultdict(list)
        usage_units = Counter()
        usage_kinds = Counter()
        illegal = 0
        # Reset envs that are not mid-episode.
        cfgs = []
        for i, env in enumerate(self.envs.envs):
            if env.last is None or env.last.get("done", True):
                ec, labels[i] = self.next_episode()
                cfgs.append((i, ec))
            else:
                labels[i] = getattr(env, "label", "ai:" + cfg["opponent"])
        for i, ec in cfgs:
            self.envs.envs[i].cfg = ec
            self.envs.envs[i].send(ec.to_cmd())
        for i, ec in cfgs:
            env = self.envs.envs[i]
            env.last = env.recv()
            env.label = labels[i]
        t0 = time.time()
        budget = float(cfg["rollout_budget_mb"]) * 2**20
        buf_bytes = 0
        self.pool_cache.pop("self", None)
        self.write_status("running", "collecting rollout", 0, T * n)
        while min(len(b) for b in buffers) < T:
            if budget > 0 and buf_bytes > budget and min(len(b) for b in buffers) > 0:
                # A map whose decision points carry thousands of candidates makes the
                # per-step cost unpredictable. Cutting the rollout short costs this
                # update some samples; running out of memory costs the whole run.
                print(f"[train] rollout capped at {buf_bytes / 2**20:.0f} MB "
                      f"({min(len(b) for b in buffers)}/{T} steps per env)", flush=True)
                break
            if time.time() - self._last_status > 3:
                done = sum(len(b) for b in buffers)
                self.write_status("running", "collecting rollout", done, T * n,
                                  env_steps_per_sec=done / max(1e-6, time.time() - t0),
                                  buffer_mb=round(buf_bytes / 2**20, 1),
                                  rounds=[int(e.last["info"]["round"]) for e in self.envs.envs if e.last])
            trainee_idx, opp_idx = [], []
            for i, env in enumerate(self.envs.envs):
                r = env.last
                if r["done"]:
                    continue
                if r["acting"] == env.cfg.side:
                    trainee_idx.append(i)
                else:
                    opp_idx.append(i)
            actions = {}
            if trainee_idx:
                enc = [encode(self.envs.envs[i].last) for i in trainee_idx]
                a, lp, v = choose(self.net, enc, self.device)
                for j, i in enumerate(trainee_idx):
                    g, f, c, cl = enc[j]
                    step = Step(g, f, c, cl, int(a[j]), float(lp[j]), float(v[j]))
                    buffers[i].append(step)
                    buf_bytes += step.nbytes
                    actions[i] = int(a[j])
                    legal = self.envs.envs[i].last["legal"][int(a[j])]
                    usage_kinds[legal["i"]["t"]] += 1
                    at = legal.get("at", -1)
                    if at is not None and at >= 0:
                        usage_units[at] += 1
            # Phase B: opponent decision points served by a frozen pool member.
            by_net = defaultdict(list)
            for i in opp_idx:
                by_net[self.envs.envs[i].label.split(":", 1)[1]].append(i)
            for path, idxs in by_net.items():
                net = self.pool_net(path)
                enc = [encode(self.envs.envs[i].last) for i in idxs]
                a, _, _ = choose(net, enc, self.device)
                for j, i in enumerate(idxs):
                    actions[i] = int(a[j])
            self.envs.step_async(actions)
            replies = self.envs.step_wait(list(actions.keys()))
            resets = []
            for i, r in replies.items():
                env = self.envs.envs[i]
                carry[i] += r["reward"]
                stats["legal_ms"].append(r["info"].get("legal_ms", 0.0))
                was_trainee = i in trainee_idx
                if r["done"]:
                    # Reward since the last trainee decision belongs to that decision.
                    if buffers[i]:
                        buffers[i][-1].reward += carry[i]
                        buffers[i][-1].done = True
                    carry[i] = 0.0
                    info = r["info"]
                    res = info.get("result", "draw")
                    stats["win"].append(1.0 if res == "win" else 0.0)
                    stats["draw"].append(1.0 if res.startswith("draw") else 0.0)
                    stats["rounds"].append(info["round"])
                    stats["value_diff"].append(info["value_diff"])
                    stats["illegal"].append(info["illegal"])
                    stats["result"].append((env.label, os.path.basename(env.cfg.map_path), res))
                    illegal += info["illegal"]
                    self.matches_done += 1
                    ec, label = self.next_episode()
                    env.label = label
                    resets.append((i, ec))
                elif was_trainee and r["acting"] == env.cfg.side:
                    buffers[i][-1].reward += carry[i]
                    carry[i] = 0.0
                elif was_trainee:
                    pass  # opponent's turn now; reward keeps accumulating in carry
            for i, ec in resets:
                self.envs.envs[i].cfg = ec
                self.envs.envs[i].send(ec.to_cmd())
            for i, ec in resets:
                self.envs.envs[i].last = self.envs.envs[i].recv()
        # Give un-finished last steps their pending reward (kept as not-done; bootstrap).
        for i in range(n):
            if buffers[i] and carry[i] != 0.0:
                buffers[i][-1].reward += carry[i]
                carry[i] = 0.0
        dt = time.time() - t0
        info = dict(stats=stats, usage_units=usage_units, usage_kinds=usage_kinds,
                    illegal=illegal, seconds=dt)
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
                _, _, v = choose(self.net, enc, self.device)
                last_vals.append(float(v[0]))
            else:
                last_vals.append(float(buffers[i][-1].value))
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
        for epoch in range(cfg["epochs"]):
            epoch_kl = []
            order = np.random.permutation(N)
            for start in range(0, N, mb):
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
            # One epoch is the granularity: checking per minibatch would abandon an update
            # halfway through a shuffle and bias which samples ever get used.
            if cfg["target_kl"] and float(np.mean(epoch_kl)) > cfg["target_kl"]:
                stopped_at = epoch + 1
                break
        self.global_step += N
        self.update += 1
        res = {k: float(np.mean(v)) for k, v in out.items()}
        res["epochs_run"] = float(stopped_at)
        return res

    # -- evaluation (10.3): greedy, fixed seeds, not training data --
    def evaluate(self, opponent: str, games: int, record_dir: str | None = None,
                 keep: int = 0, net: PolicyNet | None = None) -> dict:
        net = net or self.net
        n = len(self.envs)
        results, diffs, rounds = [], [], []
        per_game: list[dict] = []     # one row per game, for the dashboard's drill-down
        played = 0
        seed_base = 900_000 + self.update * 100
        while played < games:
            self.write_status("running", f"evaluating vs {opponent}", played, games)
            batch = min(n, games - played)
            cfgs = []
            for j in range(batch):
                k = played + j
                cfgs.append(EpisodeConfig(
                    map_path=self.cfg["maps"][k % len(self.cfg["maps"])], seed=seed_base + k,
                    side=k % 2, opponent=OPPONENTS[opponent], round_cap=self.cfg["round_cap"], max_steps=self.cfg.get("max_steps", 3000),
                    civilians=self.cfg["civilians"], random_events=self.cfg["random_events"],
                    fog=FOGS[self.cfg["fog"]], friendly_fire=self.cfg["friendly_fire"],
                    max_candidates=self.cfg["max_candidates"],
                    max_actors=self.cfg["max_actors"],
                    # Пишем КАЖДУЮ партию оценки, а не первые `keep`. Признак записи
                    # задаётся на reset'е, а кто победил — известно только в конце, так
                    # что «сохранять все победы» невозможно, если не включить запись
                    # заранее. Эпизод от этого не меняется: ReplayRecorder.capture_opening()
                    # сам зовёт play_civilian_slots(), ту же самую, что и ветка без записи.
                    # На диск попадают не все — см. ниже.
                    record=record_dir is not None))
            for j in range(batch):
                self.envs.envs[j].cfg = cfgs[j]
                self.envs.envs[j].send(cfgs[j].to_cmd())
            for j in range(batch):
                self.envs.envs[j].last = self.envs.envs[j].recv()
            active = list(range(batch))
            while active:
                # A batch of company-scale games runs for many minutes. Without a
                # heartbeat in here the dashboard sees nothing move and calls the run
                # stale, which is exactly the "no progress" confusion this panel exists
                # to prevent. Report the rounds each game has reached, so a game that is
                # genuinely stuck is distinguishable from one that is merely long.
                if time.time() - self._last_status > 5:
                    self.write_status(
                        "running", f"evaluating vs {opponent}", played, games,
                        eval_rounds=[int(self.envs.envs[j].last["info"]["round"])
                                     for j in active if self.envs.envs[j].last],
                        eval_steps=[int(self.envs.envs[j].last["info"].get("steps", 0))
                                    for j in active if self.envs.envs[j].last])
                enc = [encode(self.envs.envs[j].last) for j in active]
                a, _, _ = choose(net, enc, self.device, greedy=True)
                self.envs.step_async({j: int(a[q]) for q, j in enumerate(active)})
                replies = self.envs.step_wait(active)
                still = []
                for j in active:
                    r = replies[j]
                    if r["done"]:
                        info = r["info"]
                        results.append(info.get("result", "draw"))
                        diffs.append(info["value_diff"])
                        rounds.append(info["round"])
                        k = played + j
                        # An aggregate win rate hides which games went wrong and how. One
                        # row per game means the dashboard can show that a 0% win rate was
                        # four honest losses and four stalls, not eight of the same thing.
                        row = dict(
                            step=self.global_step, update=self.update, opponent=opponent,
                            game=k + 1, result=results[-1], by=info.get("by", ""),
                            value_diff=info["value_diff"],
                            rounds=info["round"], steps=info.get("steps"),
                            illegal=info.get("illegal"),
                            # Своих, сгоревших от расползания огня: смерть, которой можно
                            # избежать с гарантией, поэтому её видно отдельной колонкой.
                            fire_losses=info.get("fire_losses"),
                            seed=cfgs[j].seed, side=cfgs[j].side,
                            map=os.path.basename(cfgs[j].map_path), time=time.time())
                        per_game.append(row)
                        # Appended as each game ends, not batched at the finish: a long
                        # evaluation should show its results filling in, and if it dies
                        # halfway the games it did play are already on disk.
                        with open(os.path.join(self.run_dir, "eval_games.jsonl"), "a") as f:
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
                            if self.envs.envs[j].save_replay(rp):
                                with open(rp + ".json", "w") as f:
                                    json.dump(dict(branch=os.path.basename(self.run_dir),
                                                   step=self.global_step, update=self.update,
                                                   opponent=opponent,
                                                   result=results[-1], by=info.get("by", ""),
                                                   value_diff=info["value_diff"],
                                                   rounds=info["round"], map=cfgs[j].map_path,
                                                   side=cfgs[j].side, game=k + 1,
                                                   time=time.time()), f)
                                if results[-1] == "win":
                                    print(f"[eval]   WIN recorded -> {rp}", flush=True)
                    else:
                        still.append(j)
                active = still
            played += batch
        for env in self.envs.envs:
            env.last = None   # evaluation episodes are over; training resets next collect
        wins = sum(r == "win" for r in results)
        draws = sum(r.startswith("draw") for r in results)
        # How the games ended, not just how many were won. An untrained greedy policy
        # tends to stall on a free action and never end its turn, so the episode dies on
        # max_steps ("draw_steps") before the scripted opponent has played at all — and
        # then NORMAL and HARD report identical numbers, which looks like a broken
        # evaluation rather than what it is. The breakdown makes that legible.
        outcomes = Counter(results)
        return dict(games=len(results), winrate=wins / max(1, len(results)),
                    lossrate=outcomes["loss"] / max(1, len(results)),
                    drawrate=draws / max(1, len(results)), value_diff=float(np.mean(diffs)),
                    rounds=float(np.mean(rounds)),
                    stallrate=outcomes["draw_steps"] / max(1, len(results)),
                    outcomes=dict(outcomes))

    # -- main loop --
    def train(self):
        cfg = self.cfg
        if cfg["torch_threads"]:
            torch.set_num_threads(cfg["torch_threads"])
        with open(os.path.join(self.run_dir, "config.yaml"), "w") as f:
            yaml.safe_dump(cfg, f)
        self.write_status("running", f"starting {cfg['n_envs']} Godot envs", 0, 0)
        self.envs = VecEnv(cfg["n_envs"], cfg["godot"])
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
                self.write_status("running", "PPO update", 0, 0)
                losses = self.ppo_update(buffers)
                del buffers            # the rollout is the biggest thing alive; drop it
                                       # before eval opens a second front on memory
                self.log(info, losses, time.time() - t0)
                self.write_status("running", "update done", 0, 0)
                if self.update % cfg["checkpoint_every"] == 0:
                    path = self.save()
                    print(f"[train] checkpoint {path}", flush=True)
                # Evaluate on schedule, but also whenever this branch has no win rate at
                # all yet. eval_every is tens of updates and an update can take minutes,
                # so a fresh run used to show a blank "win vs NORMAL / HARD" for hours
                # and read as broken (§11.2). The second clause also rescues a branch
                # trained before this rule existed: it evaluates on its next update.
                if self.update % cfg["eval_every"] == 0 or not self.has_eval_history():
                    self.run_eval()
                if self.over_memory_budget() or self.under_disk_floor():
                    break
                if os.path.exists(stop_flag):
                    os.remove(stop_flag)
                    print("[train] STOP flag found", flush=True)
                    break
        except (KeyboardInterrupt, SystemExit):
            raise                        # an asked-for stop, not a crash
        except BaseException as e:       # noqa: BLE001 - the reason must survive to disk
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
            self.write_status("crashed" if crash else "stopped", **crash)

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
        free = free_mb(self.run_dir)
        if free >= floor:
            return False
        print(f"[train] disk floor reached: {free:.0f} MB free < {floor:.0f} MB "
              f"— checkpointing and exiting while the write can still succeed", flush=True)
        self.write_status("running", f"below disk_floor_mb ({free:.0f} MB free) — exiting", 0, 0)
        return True

    def over_memory_budget(self) -> bool:
        limit = float(self.cfg["mem_limit_mb"])
        if limit <= 0:
            return False
        used = mem_report().get("total_mb", 0.0)
        if used < limit:
            return False
        # Exiting here is the friendly failure: a checkpoint is written and the reason
        # is on the dashboard. An OOM kill leaves neither.
        print(f"[train] memory budget reached: {used:.0f} MB >= {limit:.0f} MB "
              f"(trainer + envs) — checkpointing and exiting", flush=True)
        self.write_status("running", f"over mem_limit_mb ({used:.0f} MB) — exiting", 0, 0)
        return True

    def run_eval(self):
        """Both reference opponents, every time. An eval that dies with its Godot env
        must not take the run with it — the win rate is a diagnostic, not the training
        signal, so a failed one is logged as such and training carries on."""
        rec = os.path.join(self.run_dir, "replays", f"checkpoint_{self.global_step:09d}")
        row = {"step": self.global_step, "update": self.update, "time": time.time(),
               "phase": self.cfg["phase"], "stage": self.cfg["stage"]}
        for opp in self.cfg["eval_opponents"]:
            try:
                r = self.evaluate(opp, self.cfg["eval_games"], record_dir=rec,
                                  keep=self.cfg["replays_per_checkpoint"])
            except EnvDied as e:
                print(f"[eval] vs {opp} aborted: {e}", flush=True)
                row[f"error_{opp}"] = str(e)
                self.envs.rebuild()
                continue
            row.update({f"{k}_{opp}": v for k, v in r.items()})
            for k in ("winrate", "lossrate", "drawrate", "value_diff", "rounds", "stallrate"):
                self.writer.add_scalar(f"eval/{k}_{opp}", r[k], self.global_step)
            print(f"[eval] step={self.global_step} vs {opp}: win {r['winrate']:.2f} "
                  f"draw {r['drawrate']:.2f} diff {r['value_diff']:+.2f} "
                  f"rounds {r['rounds']:.1f} outcomes {r['outcomes']}", flush=True)
        self.writer.flush()
        self.last_eval = row
        with open(os.path.join(self.run_dir, "eval_log.jsonl"), "a") as f:
            f.write(json.dumps(row) + "\n")
        self.prune()

    def log(self, info: dict, losses: dict, update_secs: float):
        st = info["stats"]
        w, s = self.writer, self.global_step
        steps = self.cfg["rollout_steps"] * self.cfg["n_envs"]
        w.add_scalar("speed/env_steps_per_sec", steps / max(1e-6, info["seconds"]), s)
        w.add_scalar("speed/update_secs", update_secs, s)
        w.add_scalar("speed/matches_done", self.matches_done, s)
        if st["legal_ms"]:
            # Where a slow step actually goes: on company-sized maps the legal-intent
            # enumerator is most of it, and max_actors is the knob that moves this number.
            w.add_scalar("speed/env_legal_ms", float(np.mean(st["legal_ms"])), s)
        mem = mem_report()
        for k in ("rss_mb", "envs_mb", "free_mb"):
            if k in mem:
                w.add_scalar(f"mem/{k}", mem[k], s)
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
        w.add_scalar("train/curriculum_stage", self.cfg["stage"], s)
        w.add_scalar("train/phase", 0 if self.cfg["phase"] == "A" else 1, s)
        w.flush()
        wr = f"{np.mean(st['win']):.2f}" if st["win"] else "-"
        print(f"[train] upd={self.update} step={s} matches={self.matches_done} win={wr} "
              f"pl={losses['policy_loss']:+.3f} vl={losses['value_loss']:.3f} "
              f"ent={losses['entropy']:.2f} kl={losses['approx_kl']:.4f} "
              f"env={info['seconds']:.0f}s upd={update_secs:.0f}s", flush=True)


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
    d = cfg.get("device", "cpu")
    if d != "auto":
        return d
    if torch.cuda.is_available():
        return "cuda"
    if getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def cmd_resume(a):
    rd = run_dir_for(a.branch)
    latest = os.path.join(rd, "latest.pt")
    if not os.path.exists(latest):
        sys.exit(f"no checkpoint in {rd}")
    refuse_if_running(rd)
    clear_flags(rd)
    cfg = load_config(a.config) if a.config else None
    cfg = cfg or load_config(os.path.join(rd, "config.yaml"))
    t = Trainer(rd, cfg, pick_device(cfg))
    t.load(latest, keep_cfg=True)
    t.train()


def cmd_fork(a):
    rd = run_dir_for(a.branch)
    if os.path.exists(rd):
        sys.exit(f"branch {a.branch} already exists")
    src_cfg = os.path.join(os.path.dirname(os.path.abspath(a.checkpoint)), "config.yaml")
    cfg = load_config(a.config or (src_cfg if os.path.exists(src_cfg) else None))
    t = Trainer(rd, cfg, pick_device(cfg))
    t.load(a.checkpoint, keep_cfg=True)
    t.parent = os.path.abspath(a.checkpoint)
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
    t.envs = VecEnv(cfg["n_envs"], cfg["godot"])
    try:
        r = t.evaluate(a.opponent, a.games, record_dir=a.record, keep=a.games if a.record else 0)
        print(json.dumps(r))
    finally:
        t.envs.close()


def cmd_export(a):
    ck = torch.load(a.checkpoint, map_location="cpu", weights_only=False)
    net = PolicyNet()
    net.load_state_dict(ck["model"])
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


def cmd_play(a):
    """Real game with the checkpoint in the AI slot: a local policy server plus the game
    launched with MCF_RL_POLICY pointing at it (LearnedController.gd connects)."""
    port = a.port
    srv = subprocess.Popen([sys.executable, os.path.join(PROJECT, "rl", "policy_server.py"),
                            a.checkpoint, "--port", str(port)])
    try:
        # The controller has to show the policy a candidate list of the same shape it
        # trained on, so the checkpoint's own caps travel with it into the game.
        ck = torch.load(a.checkpoint, map_location="cpu", weights_only=False)
        cfg = with_defaults(ck.get("cfg", {}))
        env = dict(os.environ, MCF_RL_POLICY=f"127.0.0.1:{port}",
                   MCF_RL_MAX_ACTORS=str(cfg["max_actors"]),
                   MCF_RL_MAX_CANDIDATES=str(cfg["max_candidates"]))
        subprocess.call([a.godot, "--path", PROJECT], env=env)
    finally:
        srv.terminate()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = p.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("start"); s.add_argument("config"); s.add_argument("--branch", required=True); s.set_defaults(fn=cmd_start)
    s = sp.add_parser("resume"); s.add_argument("branch"); s.add_argument("--config"); s.set_defaults(fn=cmd_resume)
    s = sp.add_parser("fork"); s.add_argument("checkpoint"); s.add_argument("--branch", required=True); s.add_argument("--config"); s.set_defaults(fn=cmd_fork)
    s = sp.add_parser("stop"); s.add_argument("branch"); s.set_defaults(fn=cmd_stop)
    s = sp.add_parser("pause"); s.add_argument("branch"); s.set_defaults(fn=cmd_pause)
    s = sp.add_parser("continue"); s.add_argument("branch"); s.set_defaults(fn=cmd_continue)
    s = sp.add_parser("status"); s.add_argument("branch", nargs="?"); s.set_defaults(fn=cmd_status)
    s = sp.add_parser("eval"); s.add_argument("checkpoint"); s.add_argument("--games", type=int, default=10)
    s.add_argument("--opponent", choices=list(OPPONENTS), default="normal"); s.add_argument("--record"); s.set_defaults(fn=cmd_eval)
    s = sp.add_parser("export"); s.add_argument("checkpoint"); s.add_argument("out"); s.set_defaults(fn=cmd_export)
    s = sp.add_parser("play"); s.add_argument("checkpoint"); s.add_argument("--port", type=int, default=7791)
    s.add_argument("--godot", default="godot"); s.set_defaults(fn=cmd_play)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
