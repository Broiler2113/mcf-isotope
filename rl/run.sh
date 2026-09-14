#!/usr/bin/env bash
# Start/attach the training session in tmux: trainer in one window, TensorBoard in another.
#   bash rl/run.sh start  <config.yaml> <branch>   # new run
#   bash rl/run.sh resume <branch>                 # continue from latest checkpoint
#   bash rl/run.sh stop   <branch>                 # graceful: checkpoint after this update
#   bash rl/run.sh attach                          # tmux attach (Ctrl-b d to detach)
#   bash rl/run.sh status
# TensorBoard binds to 127.0.0.1:6006 ONLY. Reach it with an SSH tunnel:
#   ssh -L 6006:127.0.0.1:6006 root@<this host>   → open http://localhost:6006
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VENV="${VENV:-$HOME/.venvs/mcf-rl}"
PY="$VENV/bin/python"
SESSION="mcf-rl"
TB_PORT="${TB_PORT:-6006}"

ensure_tb() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" -n tensorboard \
      "cd '$HERE' && '$VENV/bin/tensorboard' --logdir runs --host 127.0.0.1 --port $TB_PORT --reload_interval 30; read"
  fi
}

case "${1:-}" in
  start)
    ensure_tb
    CFG="$(realpath "$2")"
    tmux new-window -t "$SESSION" -n "train-$3" \
      "cd '$HERE' && PYTHONUNBUFFERED=1 '$PY' train.py start '$CFG' --branch '$3' 2>&1 | tee -a 'runs/$3.log'; read"
    echo "started branch $3 in tmux session $SESSION (bash rl/run.sh attach)";;
  resume)
    ensure_tb
    [ -n "${3:-}" ] && CFG="--config $(realpath "$3")" || CFG=""
    tmux new-window -t "$SESSION" -n "train-$2" \
      "cd '$HERE' && PYTHONUNBUFFERED=1 '$PY' train.py resume '$2' $CFG 2>&1 | tee -a 'runs/$2.log'; read"
    echo "resumed branch $2";;
  stop)   "$PY" "$HERE/train.py" stop "$2";;
  status) "$PY" "$HERE/train.py" status "${2:-}";;
  attach) tmux attach -t "$SESSION";;
  *) sed -n 2,10p "$0"; exit 2;;
esac
