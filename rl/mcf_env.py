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
import socket
import subprocess
import time
from dataclasses import dataclass

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
        self.sock: socket.socket | None = None
        self.sent_at = 0.0
        self.start()

    def start(self) -> None:
        # Replies come back over a local socket, not stdout: Godot copies everything print()
        # writes into user://logs/godot.log, and a reply is ~56 KiB (see env_server.gd).
        lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        lsock.bind(("127.0.0.1", 0))
        lsock.listen(1)
        lsock.settimeout(1.0)
        self.proc = subprocess.Popen(
            [self.godot, "--headless", "--path", self.project, "--script", SERVER_SCRIPT,
             "--", f"--reply-port={lsock.getsockname()[1]}"],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            bufsize=0,
            # Own process group so a trainer shutdown can kill every env together (9.5).
            preexec_fn=os.setsid if os.name == "posix" else None,
        )
        try:
            for _ in range(60):
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
        self.sent_at = time.monotonic()

    def _readline(self) -> bytes:
        """One line from the env, or EnvDied once it has been silent for `timeout`."""
        assert self.proc is not None and self.sock is not None
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
            if not select.select([self.sock], [], [], min(left, 5.0))[0]:
                continue
            self._fill()

    def _fill(self) -> None:
        """Append whatever the socket has (caller knows it is readable)."""
        try:
            chunk = self.sock.recv(1 << 16)
        except OSError:
            chunk = b""
        if not chunk:
            raise EnvDied("env process exited (rc=%s)" % self.proc.poll())
        self.buf += chunk

    def has_reply(self) -> bool:
        """A complete protocol line is already buffered (recv() will not block)."""
        return b"\n" in self.buf

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
        self.proc = None

    def restart(self) -> None:
        self.kill()
        self.start()


class VecEnv:
    """N envs, each running at its own pace: the caller sends to whichever envs it has
    decided for, and `wait_any` hands back whichever have replied. (Stepping them in
    lockstep waited on the slowest env every step, and an end-turn that lets the scripted
    opponent play takes ~8x as long as an own action.)"""

    def __init__(self, n: int, godot: str = "godot"):
        self.envs = [GodotEnv(godot) for _ in range(n)]

    def __len__(self) -> int:
        return len(self.envs)

    def wait_any(self, idxs: list[int]) -> list[int]:
        """The envs among `idxs` whose reply is in (recv() will not block); waits for at
        least one. An env silent for its timeout is killed and raises EnvDied."""
        while True:
            ready = [i for i in idxs if self.envs[i].has_reply()]
            if ready:
                return ready
            socks = {self.envs[i].sock: i for i in idxs}
            readable = select.select(list(socks), [], [], 1.0)[0]
            for s in readable:
                self.envs[socks[s]]._fill()
            if not readable:
                now = time.monotonic()
                for i in idxs:
                    e = self.envs[i]
                    if now - e.sent_at > e.timeout:
                        e.kill()
                        raise EnvDied(f"env {i} silent for {e.timeout:.0f}s — killed")

    def close(self) -> None:
        for e in self.envs:
            e.close()

    def kill(self) -> None:
        for e in self.envs:
            e.kill()
