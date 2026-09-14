#!/usr/bin/env bash
# One-shot environment for the trainer. Uses uv if present, else python3 -m venv.
#   bash rl/setup.sh            # CPU torch (VPS / laptops)
#   TORCH_INDEX=cu124 bash rl/setup.sh   # CUDA 12.4 build on the workstation
set -euo pipefail
VENV="${VENV:-$HOME/.venvs/mcf-rl}"
IDX="${TORCH_INDEX:-cpu}"
if command -v uv >/dev/null; then
  [ -d "$VENV" ] || uv venv "$VENV" --python 3.12
  uv pip install --python "$VENV/bin/python" torch --index-url "https://download.pytorch.org/whl/$IDX"
  uv pip install --python "$VENV/bin/python" -r "$(dirname "$0")/requirements.txt"
else
  [ -d "$VENV" ] || python3 -m venv "$VENV"
  "$VENV/bin/pip" install torch --index-url "https://download.pytorch.org/whl/$IDX"
  "$VENV/bin/pip" install -r "$(dirname "$0")/requirements.txt"
fi
echo "ok: $VENV"
