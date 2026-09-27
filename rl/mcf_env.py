"""Bridge to headless Godot env servers (spec Section 1 C1, 5.1, 9.1).

One `GodotEnv` wraps one `godot --headless --script res://rl/env_server.gd` process and
speaks JSON lines over its stdin/stdout. `VecEnv` fans a command out to N of them and
gathers the replies, so the N simulations run in parallel while the trainer waits.
"""
from __future__ import annotations

import json
import os
import select
import signal
import subprocess
import time
from dataclasses import dataclass

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER_SCRIPT = "res://rl/env_server.gd"

# A reply that never comes is the one failure mode a blocking readline cannot survive:
# the trainer waits forever, the heartbeat goes stale, and nothing says why. Every read
# is bounded; past the bound the env is declared dead and the trainer restarts it.
# Generous, because one reply covers a whole AI turn on a company-sized map.
READ_TIMEOUT = float(os.environ.get("MCF_RL_ENV_TIMEOUT", "900"))

# AIController.Difficulty; -1 = the trainer serves the opponent's actions itself (Phase B).
EASY, NORMAL, HARD, EXTERNAL = 0, 1, 2, -1
FOG_OFF, FOG_STANDARD, FOG_REALISTIC = 0, 1, 2


@dataclass
class EpisodeConfig:
    map_path: str
    seed: int
    side: int = 0
    opponent: int = NORMAL
    round_cap: int = 10
    max_steps: int = 3000        # env steps (both sides) before the episode is called a draw
    civilians: bool = False
    random_events: bool = False
    fog: int = FOG_STANDARD
    friendly_fire: bool = True
    # Экипажи заперты в корпусах. Для карт, весь смысл которых — воевать техникой
    # (rl/maps/town_tank.json): без запрета политика паркует танк и уходит пешком.
    # Флаг едет в резолвер, а значит связывает ОБЕ стороны, а не только обучаемого.
    disembark: bool = True
    record: bool = False
    max_candidates: int = 0      # 0 = every legal intent; see env_server._cap_legal
    max_actors: int = 0          # 0 = enumerate for every unit; see env_server._actor_subset

    def to_cmd(self) -> dict:
        return {
            "cmd": "reset", "map": self.map_path, "seed": self.seed, "side": self.side,
            "opponent": self.opponent, "round_cap": self.round_cap, "max_steps": self.max_steps,
            "civilians": self.civilians, "random_events": self.random_events,
            "fog": self.fog, "friendly_fire": self.friendly_fire,
            "disembark": self.disembark, "record": self.record,
            "max_candidates": self.max_candidates, "max_actors": self.max_actors,
        }


class EnvDied(RuntimeError):
    pass


class GodotEnv:
    """One headless Godot process. All calls are synchronous unless split into send/recv."""

    def __init__(self, godot: str = "godot", project: str = PROJECT,
                 log_path: str | None = None):
        self.godot = godot
        self.project = project
        self.log_path = log_path
        self.proc: subprocess.Popen | None = None
        self.last: dict | None = None
        self.cfg: EpisodeConfig | None = None
        self._buf = b""
        self.start()

    def start(self) -> None:
        # Raw byte pipes, not text mode: recv() polls the fd with select, and a
        # TextIOWrapper could hold a complete line in its own buffer where select
        # cannot see it — the reply would then look like a hang until the timeout.
        # --log-file moves Godot's stdout mirror OFF the shared default log.
        #
        # Godot mirrors stdout into app_userdata/<project>/logs/godot.log, and for these
        # processes stdout IS the JSON protocol — every observation, every legal-intent
        # list, every board dump written to disk a second time. Measured across six envs:
        # 19 MB/min, ~1.1 GB/hr, all six holding the SAME godot.log open for append (lsof).
        # It filled the disk to zero, took the trainer down on its disk floor, and was the
        # real source of a drain chased across two nights of checks.
        #
        # `debug/file_logging/enable_file_logging=false` is already set in project.godot
        # for exactly this reason and DOES NOT WORK: a probe shows ProjectSettings really
        # does read back false at runtime, so the engine must build the logger before it
        # applies the setting and never re-checks. The commit that added it believed it
        # had fixed this; it had not.
        #
        # NOT /dev/null: `--log-file /dev/null` makes Godot crash with signal 11 on this
        # build (verified — run_codec segfaults instead of passing). A real path is fine,
        # and giving each env its own keeps the trainer able to bound them.
        argv = [self.godot, "--headless", "--path", self.project]
        if self.log_path:
            argv += ["--log-file", self.log_path]
        argv += ["--script", SERVER_SCRIPT]
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            bufsize=0,
            # Own process group so a trainer shutdown can kill every env together (9.5).
            preexec_fn=os.setsid if os.name == "posix" else None,
        )
        self._buf = b""
        # Wait for the server before the first command: a ping proves the script loaded.
        self.send({"cmd": "ping"})
        self.recv(timeout=min(READ_TIMEOUT, 120.0))

    def send(self, cmd: dict) -> None:
        assert self.proc is not None and self.proc.stdin is not None
        try:
            self.proc.stdin.write(json.dumps(cmd).encode() + b"\n")
        except (BrokenPipeError, OSError) as e:
            raise EnvDied(f"env stdin closed: {e}")

    def _readline(self, deadline: float) -> bytes:
        """One line from the env, or EnvDied if it exits or goes quiet past `deadline`."""
        assert self.proc is not None and self.proc.stdout is not None
        while True:
            nl = self._buf.find(b"\n")
            if nl >= 0:
                line, self._buf = self._buf[:nl], self._buf[nl + 1:]
                return line
            left = deadline - time.monotonic()
            if left <= 0:
                raise EnvDied(f"env {self.proc.pid} stopped replying (waited "
                              f"{READ_TIMEOUT:.0f}s) — killed and restarted")
            if not select.select([self.proc.stdout], [], [], min(left, 30.0))[0]:
                if self.proc.poll() is not None:
                    raise EnvDied("env process exited (rc=%s)" % self.proc.poll())
                continue
            chunk = os.read(self.proc.stdout.fileno(), 1 << 20)
            if not chunk:
                raise EnvDied("env process exited (rc=%s)" % self.proc.poll())
            self._buf += chunk

    def recv(self, timeout: float = READ_TIMEOUT) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            line = self._readline(deadline)
            if line.startswith(b"{"):    # anything else is Godot's own chatter
                resp = json.loads(line)
                if not resp.get("ok", True):
                    raise RuntimeError("env error: %s" % resp.get("error"))
                return resp

    def call(self, cmd: dict) -> dict:
        self.send(cmd)
        return self.recv()

    def reset(self, cfg: EpisodeConfig) -> dict:
        self.cfg = cfg
        self.last = self.call(cfg.to_cmd())
        return self.last

    def step(self, action: int) -> dict:
        self.last = self.call({"cmd": "step", "action": int(action)})
        return self.last

    def save_replay(self, path: str) -> bool:
        return bool(self.call({"cmd": "save_replay", "path": path}).get("ok"))

    def close(self) -> None:
        if self.proc is None:
            return
        try:
            self.send({"cmd": "quit"})
            self.proc.wait(timeout=3)
        except Exception:
            pass
        self.kill()

    def kill(self) -> None:
        if self.proc is None:
            return
        try:
            if os.name == "posix":
                os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
            else:
                self.proc.kill()
        except Exception:
            pass
        self.proc = None

    def restart(self) -> None:
        self.kill()
        self.start()


class VecEnv:
    """N envs stepped in lockstep. `step_async` writes every command first, then
    `step_wait` reads the replies, so the Godot processes work concurrently."""

    def __init__(self, n: int, godot: str = "godot", log_dir: str | None = None):
        self.n = n
        self.godot = godot
        self.log_dir = log_dir
        self.envs: list[GodotEnv] = []
        self.rebuild()

    def __len__(self) -> int:
        return len(self.envs)

    def _log_for(self, i: int) -> str | None:
        """Per-env Godot log path, or None to leave the engine default alone."""
        if not self.log_dir:
            return None
        os.makedirs(self.log_dir, exist_ok=True)
        return os.path.join(self.log_dir, f"env{i}.log")

    def trim_logs(self, keep_mb: float = 8.0) -> int:
        """Truncate the per-env Godot logs once they pass keep_mb. Returns MB reclaimed.

        Redirecting the logs does not make them smaller — it only moves ~1.1 GB/hr
        somewhere the trainer owns. They are append-only engine noise nobody reads, so
        truncating in place is safe: every env holds its file O_APPEND, and a POSIX append
        write after truncate simply resumes at the new end of file.
        """
        freed = 0.0
        for i in range(self.n):
            p = self._log_for(i)
            if not p or not os.path.exists(p):
                continue
            try:
                mb = os.path.getsize(p) / (1024.0 * 1024.0)
                if mb >= keep_mb:
                    with open(p, "r+") as f:
                        f.truncate(0)
                    freed += mb
            except OSError:
                pass
        return int(freed)

    def rebuild(self, attempts: int = 6) -> None:
        """Kill everything and boot a fresh set in place. Retried with backoff: a Godot
        that fails to start (a machine briefly out of memory, a locked project folder)
        must cost the run a few minutes, not the run."""
        self.kill()
        self.envs = []
        delay = 5.0
        for attempt in range(1, attempts + 1):
            try:
                self.envs = [GodotEnv(self.godot, log_path=self._log_for(i))
                             for i in range(self.n)]
                return
            except (EnvDied, OSError) as e:
                self.kill()
                self.envs = []
                if attempt == attempts:
                    raise EnvDied(f"could not start {self.n} envs after {attempts} tries: {e}")
                print(f"[env] start failed ({e}); retry {attempt}/{attempts} in {delay:.0f}s",
                      flush=True)
                time.sleep(delay)
                delay = min(delay * 2, 120.0)

    def reset_all(self, cfgs: list[EpisodeConfig]) -> list[dict]:
        for env, cfg in zip(self.envs, cfgs):
            env.cfg = cfg
            env.send(cfg.to_cmd())
        out = []
        for env in self.envs:
            env.last = env.recv()
            out.append(env.last)
        return out

    def step_async(self, actions: dict[int, int]) -> None:
        for i, a in actions.items():
            self.envs[i].send({"cmd": "step", "action": int(a)})

    def step_wait(self, idxs: list[int]) -> dict[int, dict]:
        out = {}
        for i in idxs:
            self.envs[i].last = self.envs[i].recv()
            out[i] = self.envs[i].last
        return out

    def close(self) -> None:
        for e in self.envs:
            e.close()

    def kill(self) -> None:
        for e in self.envs:
            e.kill()
