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
import sys
import time
from dataclasses import dataclass, field
from typing import Any

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER_SCRIPT = "res://rl/env_server.gd"

# A reply that never comes used to block the trainer forever (readline has no timeout):
# one wedged Godot and the run is dead until someone notices the flat dashboard. Past this
# many seconds of silence the env is killed and restarted like any other EnvDied.
REPLY_TIMEOUT = float(os.environ.get("MCF_RL_ENV_TIMEOUT", "300"))

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
    record: bool = False

    def to_cmd(self) -> dict:
        return {
            "cmd": "reset", "map": self.map_path, "seed": self.seed, "side": self.side,
            "opponent": self.opponent, "round_cap": self.round_cap, "max_steps": self.max_steps,
            "civilians": self.civilians, "random_events": self.random_events,
            "fog": self.fog, "friendly_fire": self.friendly_fire, "record": self.record,
        }


class EnvDied(RuntimeError):
    pass


class GodotEnv:
    """One headless Godot process. All calls are synchronous unless split into send/recv."""

    def __init__(self, godot: str = "godot", project: str = PROJECT,
                 timeout: float = REPLY_TIMEOUT):
        self.godot = godot
        self.project = project
        self.timeout = timeout
        self.proc: subprocess.Popen | None = None
        self.last: dict | None = None
        self.cfg: EpisodeConfig | None = None
        self.label: str = ""
        self.buf = bytearray()
        self.start()

    def start(self) -> None:
        # Binary, unbuffered: the timeout in _readline needs the bytes the OS has, not
        # whatever a TextIOWrapper is holding back (select would lie about those).
        self.proc = subprocess.Popen(
            [self.godot, "--headless", "--path", self.project, "--script", SERVER_SCRIPT],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            bufsize=0,
            # Own process group so a trainer shutdown can kill every env together (9.5).
            preexec_fn=os.setsid if os.name == "posix" else None,
        )
        self.buf.clear()
        # Wait for the server before the first command: a ping proves the script loaded.
        self.send({"cmd": "ping"})
        self.recv()

    def send(self, cmd: dict) -> None:
        assert self.proc is not None and self.proc.stdin is not None
        try:
            self.proc.stdin.write((json.dumps(cmd) + "\n").encode())
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError) as e:
            raise EnvDied(f"env stdin closed: {e}")

    def _readline(self) -> bytes:
        """One line from the env, or EnvDied once it has been silent for `timeout`."""
        assert self.proc is not None and self.proc.stdout is not None
        deadline = time.monotonic() + self.timeout
        while True:
            nl = self.buf.find(b"\n")
            if nl >= 0:
                line = bytes(self.buf[:nl])
                del self.buf[:nl + 1]
                return line
            left = deadline - time.monotonic()
            if left <= 0:
                self.kill()
                raise EnvDied(f"env silent for {self.timeout:.0f}s — killed")
            if os.name == "posix":
                if not select.select([self.proc.stdout], [], [], min(left, 5.0))[0]:
                    continue
                chunk = os.read(self.proc.stdout.fileno(), 1 << 16)
            else:
                chunk = self.proc.stdout.readline()   # no timeout off posix
            if not chunk:
                raise EnvDied("env process exited (rc=%s)" % self.proc.poll())
            self.buf += chunk

    def recv(self) -> dict:
        while True:
            line = self._readline()
            if line.startswith(b"{"):
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

    def __init__(self, n: int, godot: str = "godot"):
        self.envs = [GodotEnv(godot) for _ in range(n)]

    def __len__(self) -> int:
        return len(self.envs)

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
