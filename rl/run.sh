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
export PATH="$HOME/.local/bin:$PATH" GODOT="${GODOT:-godot}" MCF_RL_PYTHON="$PY" PYTHONUNBUFFERED=1

abspath() { ( cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd)" "$(basename "$1")" ); }   # macOS has no realpath on older releases
pid_alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }
alive() {   # trainer of <branch> still running? (status.json heartbeat + pid check, no torch import)
  python3 - "$RUNS/$1/status.json" <<'PYEOF'
import json, os, sys
try:
    s = json.load(open(sys.argv[1])); os.kill(int(s["pid"]), 0); sys.exit(0 if s["state"] == "running" else 1)
except Exception:
    sys.exit(1)
PYEOF
}
spawn() {  # spawn <name> <command...>: background, log to runs/<name>.log, pid to runs/<name>.pid
  local name="$1"; shift
  if pid_alive "$RUNS/$name.pid"; then echo "$name already running (pid $(cat "$RUNS/$name.pid"))"; return 0; fi
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
  fork)    train "$3" fork "$RUNS/$2" --branch "$3";;
  stop)    "$PY" "$HERE/train.py" stop "$2"; rm -f "$RUNS/$2.pid";;
  status)  "$PY" "$HERE/train.py" status "${2:-}"
           for p in "$RUNS"/*.pid; do [ -f "$p" ] && pid_alive "$p" && echo "process: $(basename "$p" .pid) (pid $(cat "$p"))"; done; true;;
  logs)    tail -f "$RUNS/$2.log";;
  alive)   alive "$2";;
  *) sed -n 2,12p "$0"; exit 2;;
esac
