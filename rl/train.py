#!/usr/bin/env python
"""RL Enemy AI v1 trainer and launcher (spec Sections 6, 8, 9, 10, 13.1).

    train.py start  <config.yaml> --branch NAME     new run (rl/runs/NAME)
    train.py resume <branch>                          continue from latest checkpoint
    train.py fork   <checkpoint.pt> --branch NAME [--config c.yaml]
    train.py stop   <branch>                          graceful stop after this update
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
import signal
import subprocess
import sys
import time
from collections import Counter, defaultdict
from dataclasses import dataclass

import numpy as np
import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import torch_compat  # noqa: F401,E402
import torch  # noqa: E402
import torch.nn.functional as F  # noqa: E402
from torch.utils.tensorboard import SummaryWriter  # noqa: E402

from features import (CANVAS, INTENT_KINDS, N_ACTOR_TYPES, candidate_rows,  # noqa: E402
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
    godot="godot", n_envs=2, maps=["rl/maps/arena_34x26.json"], stage=1,
    phase="A", opponent="normal", pool_ai_fraction=0.15, pool_size=6,
    round_cap=10, civilians=False, random_events=False, fog="standard", friendly_fire=True,
    rollout_steps=256, epochs=4, minibatch=32, lr=3e-4, gamma=0.99, lam=0.95, clip=0.2,
    ent_coef=0.01, vf_coef=0.5, max_grad_norm=0.5, total_steps=20_000_000,
    checkpoint_every=5, eval_every=10, eval_games=6, replays_per_checkpoint=2,
    map_rotate_matches=5, seed=1, torch_threads=0,
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
    return cfg


# --- rollout storage --------------------------------------------------------------------

@dataclass
class Step:
    grid: np.ndarray
    flat: np.ndarray
    cand: np.ndarray
    cells: np.ndarray
    action: int
    logp: float
    value: float
    reward: float = 0.0
    done: bool = False


def collate(steps: list[Step], device):
    n = max(s.cand.shape[0] for s in steps)
    B = len(steps)
    cand = np.zeros((B, n, steps[0].cand.shape[1]), dtype=np.float32)
    cells = np.full((B, n, 2), -1, dtype=np.int64)
    mask = np.zeros((B, n), dtype=bool)
    for i, s in enumerate(steps):
        k = s.cand.shape[0]
        cand[i, :k] = s.cand
        cells[i, :k] = s.cells
        mask[i, :k] = True
    grid = torch.from_numpy(np.stack([s.grid for s in steps]).astype(np.float32)).to(device)
    flat = torch.from_numpy(np.stack([s.flat for s in steps])).to(device)
    return (grid, flat, torch.from_numpy(cand).to(device), torch.from_numpy(cells).to(device),
            torch.from_numpy(mask).to(device))


def encode(resp: dict) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    obs = resp["obs"]
    g = grid_tensor(obs).astype(np.float16)
    f = flat_vector(obs)
    c, cells = candidate_rows(obs, resp["legal"])
    return g, f, c, cells


def choose(net: PolicyNet, encoded: list, device, greedy=False):
    steps = [Step(g, f, c, cl, 0, 0.0, 0.0) for g, f, c, cl in encoded]
    batch = collate(steps, device)
    a, lp, v = net.act(*batch, greedy=greedy)
    return a.cpu().numpy(), lp.cpu().numpy(), v.cpu().numpy()


# --- trainer ---------------------------------------------------------------------------

class Trainer:
    def __init__(self, run_dir: str, cfg: dict, device="cpu"):
        self.run_dir = run_dir
        self.cfg = cfg
        self.device = device
        os.makedirs(run_dir, exist_ok=True)
        self.net = PolicyNet().to(device)
        self.opt = torch.optim.Adam(self.net.parameters(), lr=cfg["lr"], eps=1e-5)
        self.global_step = 0
        self.update = 0
        self.matches_done = 0
        self.map_idx = 0
        self.parent = None
        self.rng = random.Random(cfg["seed"])
        self.writer = SummaryWriter(os.path.join(run_dir, "tb"))
        self.envs: VecEnv | None = None
        self.stop_requested = False
        self.pool_cache: dict[str, PolicyNet] = {}
        self.episode_seed = cfg["seed"] * 1000

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
        torch.save(self.state_dict(), tmp)
        os.replace(tmp, path)          # never leave a half-written checkpoint behind
        latest = os.path.join(self.run_dir, "latest.pt")
        torch.save(self.state_dict(), latest + ".tmp")
        os.replace(latest + ".tmp", latest)
        return path

    def load(self, path: str, keep_cfg: bool = False):
        ck = torch.load(path, map_location=self.device, weights_only=False)
        self.net.load_state_dict(ck["model"])
        self.opt.load_state_dict(ck["opt"])
        if not keep_cfg:
            self.cfg = ck["cfg"]
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
            side=self.episode_seed % 2, opponent=opp, round_cap=self.cfg["round_cap"],
            civilians=self.cfg["civilians"], random_events=self.cfg["random_events"],
            fog=FOGS[self.cfg["fog"]], friendly_fire=self.cfg["friendly_fire"], record=record,
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
        self.pool_cache.pop("self", None)
        while min(len(b) for b in buffers) < T:
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
                    buffers[i].append(Step(g, f, c, cl, int(a[j]), float(lp[j]), float(v[j])))
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
            if buffers[i][-1].done or env.last is None or env.last["done"]:
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
        advs = (advs - advs.mean()) / (advs.std() + 1e-8)
        N = len(flat_steps)
        mb = cfg["minibatch"]
        out = defaultdict(list)
        for _ in range(cfg["epochs"]):
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
                ratio = (logp - old_logp).exp()
                pg = -torch.min(ratio * adv, ratio.clamp(1 - cfg["clip"], 1 + cfg["clip"]) * adv).mean()
                vloss = F.mse_loss(value, ret)
                loss = pg + cfg["vf_coef"] * vloss - cfg["ent_coef"] * entropy
                self.opt.zero_grad()
                loss.backward()
                torch.nn.utils.clip_grad_norm_(self.net.parameters(), cfg["max_grad_norm"])
                self.opt.step()
                with torch.no_grad():
                    out["policy_loss"].append(pg.item())
                    out["value_loss"].append(vloss.item())
                    out["entropy"].append(entropy.item())
                    out["approx_kl"].append((old_logp - logp).mean().item())
                    out["clipfrac"].append(((ratio - 1).abs() > cfg["clip"]).float().mean().item())
        self.global_step += N
        self.update += 1
        return {k: float(np.mean(v)) for k, v in out.items()}

    # -- evaluation (10.3): greedy, fixed seeds, not training data --
    def evaluate(self, opponent: str, games: int, record_dir: str | None = None,
                 keep: int = 0, net: PolicyNet | None = None) -> dict:
        net = net or self.net
        n = len(self.envs)
        results, diffs, rounds = [], [], []
        played = 0
        seed_base = 900_000 + self.update * 100
        while played < games:
            batch = min(n, games - played)
            cfgs = []
            for j in range(batch):
                k = played + j
                cfgs.append(EpisodeConfig(
                    map_path=self.cfg["maps"][k % len(self.cfg["maps"])], seed=seed_base + k,
                    side=k % 2, opponent=OPPONENTS[opponent], round_cap=self.cfg["round_cap"],
                    civilians=self.cfg["civilians"], random_events=self.cfg["random_events"],
                    fog=FOGS[self.cfg["fog"]], friendly_fire=self.cfg["friendly_fire"],
                    record=record_dir is not None and k < keep))
            for j in range(batch):
                self.envs.envs[j].cfg = cfgs[j]
                self.envs.envs[j].send(cfgs[j].to_cmd())
            for j in range(batch):
                self.envs.envs[j].last = self.envs.envs[j].recv()
            active = list(range(batch))
            while active:
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
                        if record_dir is not None and k < keep:
                            os.makedirs(record_dir, exist_ok=True)
                            self.envs.envs[j].save_replay(
                                os.path.join(record_dir, f"vs_{opponent}_{k + 1}_{results[-1]}.mcfr"))
                    else:
                        still.append(j)
                active = still
            played += batch
        for env in self.envs.envs:
            env.last = None   # evaluation episodes are over; training resets next collect
        wins = sum(r == "win" for r in results)
        draws = sum(r.startswith("draw") for r in results)
        return dict(games=len(results), winrate=wins / max(1, len(results)),
                    drawrate=draws / max(1, len(results)), value_diff=float(np.mean(diffs)),
                    rounds=float(np.mean(rounds)))

    # -- main loop --
    def train(self):
        cfg = self.cfg
        if cfg["torch_threads"]:
            torch.set_num_threads(cfg["torch_threads"])
        with open(os.path.join(self.run_dir, "config.yaml"), "w") as f:
            yaml.safe_dump(cfg, f)
        self.envs = VecEnv(cfg["n_envs"], cfg["godot"])
        stop_flag = os.path.join(self.run_dir, "STOP")

        def on_signal(signum, frame):
            print(f"[train] signal {signum}: finishing this update, then saving", flush=True)
            self.stop_requested = True
        signal.signal(signal.SIGINT, on_signal)
        signal.signal(signal.SIGTERM, on_signal)
        print(f"[train] branch={os.path.basename(self.run_dir)} phase={cfg['phase']} "
              f"stage={cfg['stage']} maps={len(cfg['maps'])} envs={cfg['n_envs']} "
              f"step={self.global_step} update={self.update}", flush=True)
        try:
            while self.global_step < cfg["total_steps"] and not self.stop_requested:
                try:
                    buffers, info = self.collect()
                except EnvDied as e:
                    print(f"[train] {e}; restarting envs", flush=True)
                    self.envs.kill()
                    self.envs = VecEnv(cfg["n_envs"], cfg["godot"])
                    continue
                t0 = time.time()
                losses = self.ppo_update(buffers)
                self.log(info, losses, time.time() - t0)
                if self.update % cfg["checkpoint_every"] == 0:
                    path = self.save()
                    print(f"[train] checkpoint {path}", flush=True)
                if self.update % cfg["eval_every"] == 0:
                    self.run_eval()
                if os.path.exists(stop_flag):
                    os.remove(stop_flag)
                    print("[train] STOP flag found", flush=True)
                    break
        finally:
            path = self.save()
            print(f"[train] final checkpoint {path}", flush=True)
            self.envs.close()
            self.writer.close()

    def run_eval(self):
        rec = os.path.join(self.run_dir, "replays", f"checkpoint_{self.global_step:09d}")
        for opp in ("normal", "hard"):
            r = self.evaluate(opp, self.cfg["eval_games"], record_dir=rec,
                              keep=self.cfg["replays_per_checkpoint"])
            self.writer.add_scalar(f"eval/winrate_{opp}", r["winrate"], self.global_step)
            self.writer.add_scalar(f"eval/drawrate_{opp}", r["drawrate"], self.global_step)
            self.writer.add_scalar(f"eval/value_diff_{opp}", r["value_diff"], self.global_step)
            self.writer.add_scalar(f"eval/rounds_{opp}", r["rounds"], self.global_step)
            print(f"[eval] step={self.global_step} vs {opp}: win {r['winrate']:.2f} "
                  f"draw {r['drawrate']:.2f} diff {r['value_diff']:+.2f} rounds {r['rounds']:.1f}", flush=True)
        with open(os.path.join(self.run_dir, "eval_log.jsonl"), "a") as f:
            f.write(json.dumps({"step": self.global_step, "update": self.update, "time": time.time(),
                                **{k: v for k, v in r.items()}}) + "\n")

    def log(self, info: dict, losses: dict, update_secs: float):
        st = info["stats"]
        w, s = self.writer, self.global_step
        steps = self.cfg["rollout_steps"] * self.cfg["n_envs"]
        w.add_scalar("speed/env_steps_per_sec", steps / max(1e-6, info["seconds"]), s)
        w.add_scalar("speed/update_secs", update_secs, s)
        w.add_scalar("speed/matches_done", self.matches_done, s)
        for k, v in losses.items():
            w.add_scalar(f"ppo/{k}", v, s)
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


def cmd_start(a):
    cfg = load_config(a.config)
    rd = run_dir_for(a.branch)
    if os.path.exists(os.path.join(rd, "latest.pt")):
        sys.exit(f"branch {a.branch} exists — use resume, or pick another name")
    Trainer(rd, cfg).train()


def cmd_resume(a):
    rd = run_dir_for(a.branch)
    latest = os.path.join(rd, "latest.pt")
    if not os.path.exists(latest):
        sys.exit(f"no checkpoint in {rd}")
    cfg = load_config(a.config) if a.config else None
    t = Trainer(rd, cfg or load_config(os.path.join(rd, "config.yaml")))
    t.load(latest, keep_cfg=True)
    t.train()


def cmd_fork(a):
    rd = run_dir_for(a.branch)
    if os.path.exists(rd):
        sys.exit(f"branch {a.branch} already exists")
    src_cfg = os.path.join(os.path.dirname(os.path.abspath(a.checkpoint)), "config.yaml")
    cfg = load_config(a.config or (src_cfg if os.path.exists(src_cfg) else None))
    t = Trainer(rd, cfg)
    t.load(a.checkpoint, keep_cfg=True)
    t.parent = os.path.abspath(a.checkpoint)
    t.save()
    print(f"[fork] {a.branch} <- {a.checkpoint} (step {t.global_step})")
    t.train()


def cmd_stop(a):
    rd = run_dir_for(a.branch)
    open(os.path.join(rd, "STOP"), "w").close()
    print(f"[stop] requested; {a.branch} saves a checkpoint after its current update")


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
    from features import CAND_DIM, FLAT_DIM, N_CHANNELS
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
        env = dict(os.environ, MCF_RL_POLICY=f"127.0.0.1:{port}")
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
