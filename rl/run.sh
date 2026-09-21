#!/usr/bin/env bash
# Launcher for training + monitoring, everything in one tmux session ("mcf-rl").
#   bash rl/run.sh up                              # TensorBoard (127.0.0.1:6006) + dashboard (:8501)
#   bash rl/run.sh start  <config.yaml> <branch>   # new run
#   bash rl/run.sh resume <branch> [config.yaml]   # continue from latest checkpoint
#   bash rl/run.sh restart <branch> <config.yaml>  # stop, wait for the checkpoint, resume (11.3)
#   bash rl/run.sh fork   <ckpt rel. to runs/> <new-branch>
#   bash rl/run.sh stop   <branch>                 # graceful: checkpoint after this update
#   bash rl/run.sh status | attach | down          # attach: Ctrl-b d to detach
#   bash rl/run.sh alive <branch>                  # exit 0 while that trainer runs
# Reads rl/.env (MCF_RLM_PASSWORD, GODOT, VENV) — written by rl/setup.sh, never committed.
# The dashboard is what rlm.mindcontrolfactor.com shows via the laptop's cloudflared tunnel
# (rl/setup.sh installs it); TensorBoard stays loopback-only.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/.env" ] && set -a && . "$HERE/.env" && set +a
VENV="${VENV:-$HOME/.venvs/mcf-rl}"
PY="$VENV/bin/python"
SESSION="mcf-rl"
TB_PORT="${TB_PORT:-6006}"
DASH_PORT="${DASH_PORT:-8501}"
export GODOT="${GODOT:-godot}" MCF_RL_PYTHON="$PY"

alive() {   # trainer of <branch> still running? (status.json heartbeat + pid check, no torch import)
  python3 - "$HERE/runs/$1/status.json" <<'PYEOF'
import json, os, sys
try:
    s = json.load(open(sys.argv[1])); os.kill(int(s["pid"]), 0); sys.exit(0 if s["state"] == "running" else 1)
except Exception:
    sys.exit(1)
PYEOF
}
abspath() { ( cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd)" "$(basename "$1")" ); }   # macOS has no realpath on older releases

ensure_session() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" -n tensorboard \
      "cd '$HERE' && '$VENV/bin/tensorboard' --logdir runs --host 127.0.0.1 --port $TB_PORT --reload_interval 30; read"
  fi
}
window() {  # window <name> <command>
  ensure_session
  tmux new-window -d -t "$SESSION" -n "$1" "cd '$HERE' && $2; read"
}
train_window() {  # train_window <branch> <train.py args...>
  local b="$1"; shift
  mkdir -p "$HERE/runs"
  window "train-$b" "PYTHONUNBUFFERED=1 '$PY' train.py $* 2>&1 | tee -a 'runs/$b.log'"
}

case "${1:-}" in
  up)
    ensure_session
    tmux list-windows -t "$SESSION" -F '#W' | grep -qx dashboard || \
      window dashboard "'$VENV/bin/streamlit' run dashboard.py --server.port $DASH_PORT --server.address 127.0.0.1 --server.headless true --browser.gatherUsageStats false"
    echo "tensorboard http://127.0.0.1:$TB_PORT   dashboard http://127.0.0.1:$DASH_PORT  (tmux: bash rl/run.sh attach)";;
  start)
    train_window "$3" start "'$(abspath "$2")'" --branch "'$3'"
    echo "started branch $3";;
  resume)
    [ -n "${3:-}" ] && CFG="--config '$(abspath "$3")'" || CFG=""
    train_window "$2" resume "'$2'" $CFG
    echo "resumed branch $2";;
  restart)
    CFG="$(abspath "$3")"
    "$PY" "$HERE/train.py" stop "$2"
    window "restart-$2" "while bash '$HERE/run.sh' alive '$2'; do sleep 5; done; bash '$HERE/run.sh' resume '$2' '$CFG'"
    echo "restart queued for $2: resumes with $CFG once the current update has checkpointed";;
  fork)
    train_window "$3" fork "'$HERE/runs/$2'" --branch "'$3'"
    echo "forked $3 from $2";;
  stop)   "$PY" "$HERE/train.py" stop "$2";;
  alive)  alive "$2";;
  status) "$PY" "$HERE/train.py" status "${2:-}";;
  attach) tmux attach -t "$SESSION";;
  down)   tmux kill-session -t "$SESSION" 2>/dev/null || true; echo "session closed (trainers got SIGHUP → they checkpoint and exit)";;
  *) sed -n 2,10p "$0"; exit 2;;
esac
