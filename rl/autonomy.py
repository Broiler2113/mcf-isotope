"""Persistent supervision for one training branch (macOS launchd or Linux systemd)."""
from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent


def trainer_alive(pid: int, branch: str) -> bool:
    """A stale/reused status pid must never cause an unrelated process to be killed."""
    result = subprocess.run(["ps", "-p", str(pid), "-o", "command="],
                            capture_output=True, text=True)
    args = shlex.split(result.stdout.strip())
    return any(Path(arg).name == "train.py" for arg in args) and branch in args


def verdict(branch: str, now: float | None = None) -> str:
    root = HERE / "runs" / branch
    try:
        status = json.loads((root / "status.json").read_text())
    except (OSError, ValueError):
        return "dead" if (root / "latest.pt").is_file() else "unknown"
    state = status.get("state", "unknown")
    pid = int(status.get("pid") or 0)
    if state in ("running", "paused"):
        if not trainer_alive(pid, branch):
            return "dead"
        age = (time.time() if now is None else now) - (root / "status.json").stat().st_mtime
        return "stale" if state == "running" and age > 900 else "ok"
    reason = str(status.get("stop_reason") or "")
    if reason in ("memory", "disk"):
        return "resource:" + reason
    if reason == "complete" and (root / "AUTONOMOUS").exists():
        return "complete"
    return state


def recover_stale(branch: str):
    root = HERE / "runs" / branch
    status = json.loads((root / "status.json").read_text())
    pid = int(status["pid"])
    def operator_control():
        return any((root / flag).exists() for flag in ("STOP", "OPERATOR_STOP", "PAUSE", "SUPERVISOR_OFF"))
    if verdict(branch) != "stale" or operator_control():
        return False
    os.kill(pid, signal.SIGTERM)
    for _ in range(120):
        if operator_control():
            return False
        if not trainer_alive(pid, branch):
            return True
        time.sleep(1)
    # A blocked engine cannot acknowledge the graceful stop. Release only verified
    # children of this trainer; their process groups own the Godot subprocesses.
    children = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True)
    for line in children.splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3 and int(fields[1]) == pid and "env_server.gd" in fields[2]:
            try:
                child = int(fields[0])
                if os.getpgid(child) == child:
                    os.killpg(child, signal.SIGKILL)
                else:
                    os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass
    if trainer_alive(pid, branch):
        os.kill(pid, signal.SIGKILL)
    return True


def extend(branch: str, config: str):
    import yaml
    root = HERE / "runs" / branch
    if not (root / "AUTONOMOUS").exists() or any((root / f).exists() for f in ("STOP", "OPERATOR_STOP")):
        return
    status = json.loads((root / "status.json").read_text())
    path = Path(config)
    cfg = yaml.safe_load(path.read_text())
    cfg["total_steps"] = max(int(cfg["total_steps"]), int(status["step"])) + 20_000_000
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(yaml.safe_dump(cfg))
    os.replace(temporary, path)
    print(f"[autonomy] extended {branch} target to {cfg['total_steps']} steps", flush=True)


def supervise(branch: str, config: str):
    root = HERE / "runs" / branch
    root.mkdir(parents=True, exist_ok=True)
    with (root / ".supervisor.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("This branch already has a supervisor")
        child = subprocess.Popen(["bash", str(HERE / "tools/supervise.sh"), branch, config],
                                 start_new_session=True)
        def shutdown(signum, frame):
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        signal.signal(signal.SIGTERM, shutdown)
        signal.signal(signal.SIGINT, shutdown)
        raise SystemExit(child.wait())


def install(branch: str):
    root = HERE / "runs" / branch
    if not (root / "latest.pt").is_file():
        raise SystemExit(f"No resumable checkpoint for {branch}")
    import yaml
    config = root / "config.yaml"
    cfg = yaml.safe_load(config.read_text())
    cfg.update(disk_floor_mb=500, disk_cleanup_trigger_mb=1024, disk_cleanup_target_mb=2048)
    temporary = config.with_suffix(".yaml.tmp")
    temporary.write_text(yaml.safe_dump(cfg))
    os.replace(temporary, config)
    label = "com.mcf.rlm-training"
    command = [sys.executable, str(Path(__file__).resolve()), "service", branch, str(config)]
    # Disable existing branch supervisors before the OS takes ownership. The lock
    # prevents duplicate supervisors even when a stale pid file survives a reboot.
    pidfile = HERE / "runs" / f"supervisor-{branch}.pid"
    if pidfile.exists():
        pid = int(pidfile.read_text())
        proc = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
        if ("supervise.sh" in proc.stdout or "autonomy.py supervise" in proc.stdout) and branch in shlex.split(proc.stdout):
            os.kill(pid, signal.SIGTERM)
        pidfile.unlink(missing_ok=True)
    (root / "AUTONOMOUS").touch()
    for flag in ("STOP", "OPERATOR_STOP", "PAUSE", "SUPERVISOR_OFF"):
        (root / flag).unlink(missing_ok=True)
    if not trainer_alive(int(json.loads((root / "status.json").read_text()).get("pid") or 0), branch):
        state = verdict(branch)
        if state == "complete":
            extend(branch, str(config))
        subprocess.run(["bash", str(HERE / "run.sh"), "resume", branch, str(config)], check=True)
    if sys.platform == "darwin":
        agents = Path.home() / "Library/LaunchAgents"
        agents.mkdir(parents=True, exist_ok=True)
        path = agents / f"{label}.plist"
        domain = f"gui/{os.getuid()}"
        subprocess.run(["launchctl", "bootout", f"{domain}/{label}"], capture_output=True)
        path.write_bytes(plistlib.dumps(dict(Label=label, ProgramArguments=command,
                             WorkingDirectory=str(HERE.parent), RunAtLoad=True, KeepAlive=True,
                             ThrottleInterval=30, ProcessType="Background",
                             StandardOutPath=str(HERE / "runs/autonomy.log"),
                             StandardErrorPath=str(HERE / "runs/autonomy.log"))))
        subprocess.run(["launchctl", "bootstrap", domain, str(path)], check=True)
    elif sys.platform.startswith("linux"):
        system = os.getuid() == 0
        directory = Path("/etc/systemd/system") if system else Path.home() / ".config/systemd/user"
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / "mcf-rlm-training.service"
        def quote(value):
            return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'
        path.write_text("[Unit]\nDescription=Isotope autonomous RLM training\nAfter=network.target\n"
                        "[Service]\nType=simple\nWorkingDirectory=" + quote(HERE.parent) +
                        "\nExecStart=" + " ".join(map(quote, command)) +
                        "\nRestart=always\nRestartSec=30\nTimeoutStopSec=30\n"
                        "[Install]\nWantedBy=" + ("multi-user.target" if system else "default.target") + "\n")
        ctl = ["systemctl"] + ([] if system else ["--user"])
        subprocess.run(ctl + ["daemon-reload"], check=True)
        subprocess.run(ctl + ["enable", "--now", path.name], check=True)
    else:
        raise SystemExit("Persistent training supports macOS and Linux")
    print(f"Installed persistent supervision for {branch}; free-space floor 500 MiB")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "service", "supervise", "verdict", "recover", "extend"))
    parser.add_argument("branch")
    parser.add_argument("config", nargs="?")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.branch) or args.branch in (".", ".."):
        parser.error("Invalid branch name")
    cfg = args.config or str(HERE / "runs" / args.branch / "config.yaml")
    if args.action == "install":
        install(args.branch)
    elif args.action == "verdict":
        print(verdict(args.branch))
    elif args.action == "recover":
        raise SystemExit(0 if recover_stale(args.branch) else 1)
    elif args.action == "extend":
        extend(args.branch, cfg)
    elif args.action == "service":
        subprocess.run(["bash", str(HERE / "run.sh"), "up"], check=True)
        supervise(args.branch, cfg)
    else:
        supervise(args.branch, cfg)


if __name__ == "__main__":
    main()
