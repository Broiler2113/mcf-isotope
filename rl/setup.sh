#!/usr/bin/env bash
# One-shot environment for the trainer + dashboard. Linux or macOS (Apple Silicon).
#   bash rl/setup.sh                       # venv with CPU/MPS torch, tmux, cloudflared, rl/.env
#   bash rl/setup.sh <tunnel-token>        # ...and install the rlm.mindcontrolfactor.com connector
#   TORCH_INDEX=cu124 bash rl/setup.sh     # CUDA build on a Linux box with an NVIDIA GPU
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VENV="${VENV:-$HOME/.venvs/mcf-rl}"
IDX="${TORCH_INDEX:-cpu}"
TOKEN="${1:-}"

# --- host tools ---------------------------------------------------------------------------
if [ "$(uname)" = Darwin ]; then
  command -v brew >/dev/null || { echo "install Homebrew first: https://brew.sh"; exit 1; }
  for t in tmux cloudflared; do command -v "$t" >/dev/null || brew install "$t"; done
  command -v uv >/dev/null || brew install uv
  [ -x /Applications/Godot.app/Contents/MacOS/Godot ] || command -v godot >/dev/null || brew install --cask godot
else
  command -v tmux >/dev/null || sudo apt-get install -y tmux
  command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"

# --- python ---------------------------------------------------------------------------------
[ -d "$VENV" ] || uv venv "$VENV" --python 3.12
uv pip install --python "$VENV/bin/python" torch --index-url "https://download.pytorch.org/whl/$IDX"
uv pip install --python "$VENV/bin/python" -r "$HERE/requirements.txt"

# --- rl/.env: password for the dashboard, Godot binary ---------------------------------------
ENV="$HERE/.env"
touch "$ENV"; chmod 600 "$ENV"
GODOT_BIN="$(command -v godot || true)"
[ -z "$GODOT_BIN" ] && [ -x /Applications/Godot.app/Contents/MacOS/Godot ] && GODOT_BIN=/Applications/Godot.app/Contents/MacOS/Godot
grep -q '^GODOT=' "$ENV" || echo "GODOT=${GODOT_BIN:-godot}" >> "$ENV"
grep -q '^VENV=' "$ENV" || echo "VENV=$VENV" >> "$ENV"
grep -q '^MCF_RLM_PASSWORD=' "$ENV" || echo "MCF_RLM_PASSWORD=$("$VENV/bin/python" -c 'import secrets; print(secrets.token_urlsafe(12))')" >> "$ENV"
set -a; . "$ENV"; set +a

# Godot's global class cache must know LegalIntents/LearnedController before a headless
# --script run (env_server.gd); one import pass does it.
if [ -n "${GODOT_BIN:-}" ]; then
  "$GODOT" --version
  ( cd "$HERE/.." && "$GODOT" --headless --path . --import >/dev/null 2>&1 || true )
else
  echo "!! Godot 4.7 not found — install it, then set GODOT=/path/to/godot in $ENV"
fi

# --- cloudflared connector: rlm.mindcontrolfactor.com → this machine's :8501 -----------------
if [ -n "$TOKEN" ]; then
  sudo cloudflared service install "$TOKEN"     # launchd (macOS) / systemd (Linux), starts at boot
fi

echo
echo "ok: $VENV"
echo "dashboard password (also in $ENV): $MCF_RLM_PASSWORD"
echo "next:  bash rl/run.sh up                                 # dashboard :8501 + tensorboard :6006"
echo "       bash rl/run.sh start rl/config/laptop.yaml phaseA-1   # or press Start on the dashboard"
