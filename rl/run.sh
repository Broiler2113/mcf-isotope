#!/usr/bin/env bash
# Launcher for training + monitoring. Plain background processes (nohup), pid files in
# rl/runs/, logs in rl/runs/<name>.log — no tmux, no sudo, works on macOS and Linux.
#   bash rl/run.sh up                              # TensorBoard (127.0.0.1:6006) + dashboard (:8501) [+ tunnel on Linux]
#   bash rl/run.sh down                            # stop dashboard/TensorBoard and every trainer (graceful)
#   bash rl/run.sh start  <config.yaml> <branch>   # new run
#   bash rl/run.sh resume <branch> [config.yaml]   # continue from latest checkpoint
#   bash rl/run.sh restart <branch> <config.yaml>  # stop, wait for the checkpoint, resume (11.3)
#   bash rl/run.sh fork   <ckpt rel. to runs/> <new-branch>
#   bash rl/run.sh stop   <branch>                 # graceful: checkpoint after this update
#   bash rl/run.sh supervise <branch> [config]     # keep it alive: resume crashes and resource stops
#   bash rl/run.sh pause  <branch>                 # checkpoint and hold; Godot envs stay up
#   bash rl/run.sh continue <branch>               # release a paused run
#   bash rl/run.sh status | logs <name> | alive <branch>
# Reads rl/.env (MCF_RLM_PASSWORD, GODOT, VENV, TUNNEL_TOKEN) — written by rl/setup.sh, never committed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/.env" ] && set -a && . "$HERE/.env" && set +a
VENV="${VENV:-$HOME/.venvs/mcf-rl}"
PY="$VENV/bin/python"
RUNS="$HERE/runs"; mkdir -p "$RUNS"
TB_PORT="${TB_PORT:-6006}"
DASH_PORT="${DASH_PORT:-8501}"
LOG_MAX_MB="${LOG_MAX_MB:-64}"
export PATH="$HOME/.local/bin:$PATH" GODOT="${GODOT:-godot}" MCF_RL_PYTHON="$PY" PYTHONUNBUFFERED=1

abspath() { ( cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd)" "$(basename "$1")" ); }   # macOS has no realpath on older releases
pid_alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }
alive() {   # trainer of <branch> still running? (status.json heartbeat + pid check, no torch import)
  python3 - "$RUNS/$1/status.json" <<'PYEOF'
import json, os, sys
try:
    s = json.load(open(sys.argv[1])); os.kill(int(s["pid"]), 0)
    sys.exit(0 if s["state"] in ("running", "paused") else 1)   # paused is still a live process
except Exception:
    sys.exit(1)
PYEOF
}
rotate() {  # keep runs/<name>.log under LOG_MAX_MB by moving it aside once, at spawn time
  local f="$RUNS/$1.log"
  [ -f "$f" ] || return 0
  local kb; kb=$(( $(wc -c < "$f") / 1024 ))
  if [ "$kb" -gt $(( LOG_MAX_MB * 1024 )) ]; then mv -f "$f" "$f.1"; fi   # one generation; .1 is overwritten
}
spawn() {  # spawn <name> <command...>: background, log to runs/<name>.log, pid to runs/<name>.pid
  local name="$1"; shift
  if pid_alive "$RUNS/$name.pid"; then echo "$name already running (pid $(cat "$RUNS/$name.pid"))"; return 0; fi
  rotate "$name"   # a trainer that has crashed and resumed for a month appends forever otherwise
  ( cd "$HERE"; nohup "$@" >> "$RUNS/$name.log" 2>&1 & echo $! > "$RUNS/$name.pid" )   # "cd;" not "cd &&": & must bind to nohup alone so $! is its pid
  echo "$name: pid $(cat "$RUNS/$name.pid"), log $RUNS/$name.log"
}
train() {  # train <branch> <train.py args...>
  local b="$1"; shift
  spawn "$b" "$PY" train.py "$@"
}

case "${1:-}" in
  up)
    spawn tensorboard "$VENV/bin/tensorboard" --logdir runs --host 127.0.0.1 --port "$TB_PORT" --reload_interval 30
    spawn dashboard "$VENV/bin/streamlit" run dashboard.py --server.port "$DASH_PORT" --server.address 127.0.0.1 --server.headless true --browser.gatherUsageStats false
    # macOS is skipped ON PURPOSE, and not for portability: on this laptop the tunnel is
    # owned by the launchd agent ~/Library/LaunchAgents/com.mcf.rlm-tunnel.plist
    # (RunAtLoad + KeepAlive, logging to ~/Library/Logs/mcf-rlm-tunnel.log). Spawning a
    # second cloudflared from here would leave two processes serving one tunnel and make
    # "which one is broken" unanswerable — briefly the case while diagnosing this.
    #
    # KeepAlive only restarts the process when it EXITS. It cannot see the failure that
    # actually happens: cloudflared alive, holding zero edge connections, public host on
    # Cloudflare 1033 while localhost:8501 answers 200. That gap is covered by the tunnel
    # watchdog in rl/tools/supervise.sh, which probes end to end and kickstarts the agent.
    if [ "$(uname)" != Darwin ] && [ -n "${TUNNEL_TOKEN:-}" ]; then spawn tunnel cloudflared tunnel run --token "$TUNNEL_TOKEN"; fi
    echo "tensorboard http://127.0.0.1:$TB_PORT   dashboard http://127.0.0.1:$DASH_PORT";;
  down)
    for p in "$RUNS"/*.pid; do
      [ -f "$p" ] || continue
      pid_alive "$p" && kill "$(cat "$p")" 2>/dev/null && echo "stopping $(basename "$p" .pid)"   # SIGTERM: trainers checkpoint first
      rm -f "$p"
    done;;
  start)   train "$3" start "$(abspath "$2")" --branch "$3";;
  resume)  if [ -n "${3:-}" ]; then train "$2" resume "$2" --config "$(abspath "$3")"; else train "$2" resume "$2"; fi;;
  restart)
    CFG="$(abspath "$3")"
    "$PY" "$HERE/train.py" stop "$2"
    rm -f "$RUNS/$2.pid"
    spawn "restart-$2" bash -c "while bash '$HERE/run.sh' alive '$2'; do sleep 5; done; bash '$HERE/run.sh' resume '$2' '$CFG'"
    echo "restart queued for $2: resumes with $CFG once the current update has checkpointed";;
  fork)    # optional 4th arg: the config the fork should train under. Without it the fork
           # inherits the parent's config.yaml, which is right for "same task, new branch"
           # and wrong for every fork that exists BECAUSE the task changed (a new map pool,
           # a new opponent). train.py fork has always accepted --config; only this line
           # was missing, so the config had to be written into the run dir by hand.
           if [ -n "${4:-}" ]; then train "$3" fork "$RUNS/$2" --branch "$3" --config "$(abspath "$4")"
           else train "$3" fork "$RUNS/$2" --branch "$3"; fi;;
  stop)    "$PY" "$HERE/train.py" stop "$2"; rm -f "$RUNS/$2.pid";;
  supervise)
    # Backgrounded through spawn like everything else, so it gets a pid file and
    # `run.sh down` stops it too — a supervisor that outlived `down` would resume the
    # very branch you just stopped.
    CFG="${3:-$RUNS/$2/config.yaml}"
    [ -f "$CFG" ] || { echo "no config at $CFG — pass one: run.sh supervise $2 <config.yaml>"; exit 2; }
    spawn "supervisor-$2" bash "$HERE/tools/supervise.sh" "$2" "$(abspath "$CFG")";;
  pause)    "$PY" "$HERE/train.py" pause "$2";;      # pid stays: a paused run is a live process
  continue) "$PY" "$HERE/train.py" continue "$2";;
  status)  "$PY" "$HERE/train.py" status "${2:-}"
           for p in "$RUNS"/*.pid; do [ -f "$p" ] && pid_alive "$p" && echo "process: $(basename "$p" .pid) (pid $(cat "$p"))"; done; true;;
  logs)    tail -f "$RUNS/$2.log";;
  alive)   alive "$2";;
  *) sed -n 2,15p "$0"; exit 2;;
esac
