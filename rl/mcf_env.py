"""Bridge to headless Godot env servers (spec Section 1 C1, 5.1, 9.1).

One `GodotEnv` wraps one `godot --headless --script res://rl/env_server.gd` process and
takes JSON-line commands on stdin and answers on a local socket. `VecEnv` runs N of them,
each at its own pace: `wait_any` hands back whichever envs have replied.
"""
from __future__ import annotations

import json
import os
import re
import select
import signal
import socket
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

# AIController.Difficulty.HARD — the only scripted opponent RL plays (NORMAL and EASY are
# retired from training and evaluation); -1 = the trainer serves the opponent's actions
# itself (Phase B).
HARD, EXTERNAL = 2, -1
FOG_OFF, FOG_STANDARD, FOG_REALISTIC = 0, 1, 2


@dataclass
class EpisodeConfig:
    map_path: str
    seed: int
    side: int = 0
    opponent: int = HARD
    round_cap: int = 10
    max_steps: int = 3000        # env steps (both sides) before the episode is called a draw
    civilians: bool = False
    random_events: bool = False
    random_event_interval: int = 6  # player handoffs, with the game's 2/3 event chance
    hazard_coef: float = 0.0       # discounted potential for public event danger
    fog: int = FOG_STANDARD
    friendly_fire: bool = True
    # Экипажи заперты в корпусах. Для карт, весь смысл которых — воевать техникой
    # (rl/maps/town_tank.json): без запрета политика паркует танк и уходит пешком.
    # Флаг едет в резолвер, а значит связывает ОБЕ стороны, а не только обучаемого.
    disembark: bool = True
    record: bool = False
    max_candidates: int = 0      # 0 = every legal intent; see env_server._cap_legal
    max_actors: int = 0          # 0 = enumerate for every unit; see env_server._actor_subset
    # --- tactical env (config/tactical.yaml) ---
    opponent_style: int = 0      # AIController.Style for the HARD opponent: 0 standard, 1 rush, 2 turtle, 3 flank
    shaping_scale: float = 1.0   # multiplies the per-action bonuses (R_SHOT, R_VEHICLE); decays in training
    potential_coef: float = 0.0  # weight of the position potential (env_server._phi); 0 = off
    gamma: float = 0.99         # discount per learner decision, including opponent reply
    army: str = ""               # "" as on the map, "shuffle" = mirrored type swap (fixed maps)

    def to_cmd(self) -> dict:
        return {
            "cmd": "reset", "map": self.map_path, "seed": self.seed, "side": self.side,
            "opponent": self.opponent, "round_cap": self.round_cap, "max_steps": self.max_steps,
            "civilians": self.civilians, "random_events": self.random_events,
            "random_event_interval": self.random_event_interval, "hazard_coef": self.hazard_coef,
            "fog": self.fog, "friendly_fire": self.friendly_fire,
            "disembark": self.disembark, "record": self.record,
            "max_candidates": self.max_candidates, "max_actors": self.max_actors,
            "opponent_style": self.opponent_style, "shaping_scale": self.shaping_scale,
            "potential_coef": self.potential_coef, "army": self.army, "gamma": self.gamma,
        }


class EnvDied(RuntimeError):
    pass


def refresh_class_cache(godot: str = "godot", project: str = PROJECT) -> bool:
    """Import the project when Godot's script-class cache is out of date. True if it ran.

    Godot registers `class_name`s only on import (the editor does it on focus). A pull
    that adds or renames one — release 23 added MapGen — leaves the cache stale, and every
    script naming that class then fails to parse when the game is run from source: the
    lobby became a gray window, and an env server would crash-loop the same way. Cheap to
    check (read the declarations, compare with the cache), so it runs before every launch;
    the import itself only when they differ."""
    declared = set()
    for d, dirs, files in os.walk(project):
        dirs[:] = [x for x in dirs if not x.startswith(".") and x not in ("runs", "graphify-out")]
        for f in files:
            if f.endswith(".gd"):
                with open(os.path.join(d, f), encoding="utf-8", errors="ignore") as fh:
                    for line in fh:
                        m = re.match(r"\s*class_name\s+(\w+)", line)
                        if m:
                            declared.add(m.group(1))
                            break
    try:
        with open(os.path.join(project, ".godot", "global_script_class_cache.cfg")) as fh:
            known = set(re.findall(r'"class": &"(\w+)"', fh.read()))
    except OSError:
        known = set()
    if declared == known:
        return False
    print(f"[env] script classes changed ({', '.join(sorted(declared ^ known)[:6])}) — "
          f"re-importing the project", flush=True)
    subprocess.run([godot, "--headless", "--path", project, "--import"], timeout=900,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return True


class GodotEnv:
    """One headless Godot process. Commands go in on stdin; replies come back on a local
    TCP socket (env_server.gd `--reply-port`). All calls are synchronous unless split into
    send / recv, or driven through VecEnv.wait_any."""

    def __init__(self, godot: str = "godot", project: str = PROJECT,
                 log_path: str | None = None):
        self.godot = godot
        self.project = project
        self.log_path = log_path
        self.proc: subprocess.Popen | None = None
        self.sock: socket.socket | None = None
        self.last: dict | None = None
        self.cfg: EpisodeConfig | None = None
        self.label: str = ""
        self.sent_at = 0.0
        self._buf = b""
        self.start()

    def start(self) -> None:
        # Replies travel over a socket, NOT stdout. Godot mirrors everything print() writes
        # into its file log, and for these processes stdout used to BE the JSON protocol:
        # every observation and legal-intent list written to disk a second time, ~1.1 GB/hr
        # across six envs. --log-file below moved that off the shared default log and
        # trim_logs() bounded it; taking the protocol off print() stops the writes at the
        # source, so the per-env logs now hold only Godot's own messages.
        #
        # `debug/file_logging/enable_file_logging=false` in project.godot does NOT stop it
        # for --script runs (verified), and `--log-file /dev/null` makes this Godot build
        # crash with signal 11 — a real path is honoured.
        lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        lsock.bind(("127.0.0.1", 0))
        lsock.listen(1)
        lsock.settimeout(1.0)
        argv = [self.godot, "--headless", "--path", self.project]
        if self.log_path:
            argv += ["--log-file", self.log_path]
        argv += ["--script", SERVER_SCRIPT, "--", f"--reply-port={lsock.getsockname()[1]}"]
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            bufsize=0,
            # Own process group so a trainer shutdown can kill every env together (9.5).
            preexec_fn=os.setsid if os.name == "posix" else None,
        )
        try:
            for _ in range(120):
                try:
                    self.sock, _ = lsock.accept()
                    break
                except socket.timeout:
                    if self.proc.poll() is not None:
                        break
            if self.sock is None:
                rc = self.proc.poll()
                self.kill()
                raise EnvDied(f"env never connected back (rc={rc})")
        finally:
            lsock.close()
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
        self.sent_at = time.monotonic()

    def _fill(self) -> None:
        """Append what the socket has (the caller knows it is readable)."""
        try:
            chunk = self.sock.recv(1 << 20)
        except OSError:
            chunk = b""
        if not chunk:
            raise EnvDied("env process exited (rc=%s)" % (self.proc.poll() if self.proc else None))
        self._buf += chunk

    def has_reply(self) -> bool:
        """A complete line is already buffered, so recv() will not block."""
        return b"\n" in self._buf

    def _readline(self, deadline: float) -> bytes:
        """One line from the env, or EnvDied if it exits or goes quiet past `deadline`."""
        assert self.proc is not None and self.sock is not None
        while True:
            nl = self._buf.find(b"\n")
            if nl >= 0:
                line, self._buf = self._buf[:nl], self._buf[nl + 1:]
                return line
            left = deadline - time.monotonic()
            if left <= 0:
                pid = self.proc.pid
                self.kill()
                raise EnvDied(f"env {pid} stopped replying (waited "
                              f"{READ_TIMEOUT:.0f}s) — killed and restarted")
            if not select.select([self.sock], [], [], min(left, 30.0))[0]:
                if self.proc.poll() is not None:
                    raise EnvDied("env process exited (rc=%s)" % self.proc.poll())
                continue
            self._fill()

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
        if self.sock is not None:
            self.sock.close()
            self.sock = None
        if self.proc is None:
            return
        try:
            if os.name == "posix":
                os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
            else:
                self.proc.kill()
        except Exception:
            pass
        if self.proc.stdin is not None:
            self.proc.stdin.close()
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass
        self.proc = None

    def restart(self) -> None:
        self.kill()
        self.start()


class VecEnv:
    """N envs, each running at its own pace: the caller sends to whichever envs it has
    decided for, and `wait_any` hands back whichever have replied. (Stepping them in
    lockstep waited on the slowest env every step, and an end-turn that lets the scripted
    opponent play takes ~8x as long as an own action.)"""

    def __init__(self, n: int, godot: str = "godot", log_dir: str | None = None):
        self.n = n
        self.godot = godot
        self.log_dir = log_dir
        self.envs: list[GodotEnv] = []
        refresh_class_cache(godot)          # before any env parses a script
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

        Redirecting the logs does not make them smaller — it only moves the writes
        somewhere the trainer owns. They are engine noise nobody reads, so truncating in
        place is safe and does free the blocks.

        MEASURED IN BLOCKS, NOT st_size, and that is not a detail. Godot does NOT open
        these with O_APPEND — it keeps its own file offset — so after truncate(0) the next
        write lands at the old offset and leaves a hole. The file is then SPARSE: env0.log
        measured 624 MB by st_size against 22 MB of real blocks. Summing st_size made the
        trimmer report "trimmed 3375 MB" for an update that had actually reclaimed about a
        hundred, which is both alarming and false. st_blocks is what the filesystem is
        actually holding, so that is what the threshold and the report use.
        """
        freed = 0.0
        for i in range(self.n):
            p = self._log_for(i)
            if not p or not os.path.exists(p):
                continue
            try:
                mb = os.stat(p).st_blocks * 512 / (1024.0 * 1024.0)
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

    def wait_any(self, idxs: list[int]) -> list[int]:
        """The envs among `idxs` whose reply is in (recv() will not block); waits for at
        least one. An env silent for READ_TIMEOUT is killed and raises EnvDied."""
        while True:
            ready = [i for i in idxs if self.envs[i].has_reply()]
            if ready:
                return ready
            socks = {self.envs[i].sock: i for i in idxs}
            readable = select.select(list(socks), [], [], 1.0)[0]
            for s in readable:
                self.envs[socks[s]]._fill()
            if not readable:
                on_wait = getattr(self, "on_wait", None)
                if on_wait is not None:
                    on_wait()
                now = time.monotonic()
                for i in idxs:
                    e = self.envs[i]
                    if now - e.sent_at > READ_TIMEOUT:
                        e.kill()
                        raise EnvDied(f"env {i} stopped replying (waited {READ_TIMEOUT:.0f}s)"
                                      " — killed and restarted")

    def close(self) -> None:
        for e in self.envs:
            e.close()

    def kill(self) -> None:
        for e in self.envs:
            e.kill()
