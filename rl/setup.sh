#!/usr/bin/env bash
# One-shot environment for the trainer + dashboard. No sudo, no Homebrew: everything goes
# to ~/.local/bin, ~/Applications and ~/.venvs. Linux or macOS (Apple Silicon / Intel).
#   bash rl/setup.sh                       # uv, venv with CPU/MPS torch, Godot 4.7, rl/.env
#   bash rl/setup.sh <tunnel-token>        # ...and the rlm.mindcontrolfactor.com connector (at login)
#   TORCH_INDEX=cu124 bash rl/setup.sh     # CUDA build on a Linux box with an NVIDIA GPU
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VENV="${VENV:-$HOME/.venvs/mcf-rl}"
IDX="${TORCH_INDEX:-cpu}"
TOKEN="${1:-}"
BIN="$HOME/.local/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"
OS="$(uname)"; ARCH="$(uname -m)"

# --- uv (python + venv manager) --------------------------------------------------------------
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
[ -d "$VENV" ] || uv venv "$VENV" --python 3.12
uv pip install --python "$VENV/bin/python" torch --index-url "https://download.pytorch.org/whl/$IDX"
uv pip install --python "$VENV/bin/python" -r "$HERE/requirements.txt"

# --- Godot 4.7 (official build, user-space) ---------------------------------------------------
GODOT_BIN="$(command -v godot || true)"
if [ -z "$GODOT_BIN" ] && [ "$OS" = Darwin ]; then
  APP="$HOME/Applications/Godot.app"
  if [ ! -x "$APP/Contents/MacOS/Godot" ]; then
    mkdir -p "$HOME/Applications"
    curl -L -o /tmp/godot.zip https://github.com/godotengine/godot/releases/download/4.7-stable/Godot_v4.7-stable_macos.universal.zip
    unzip -qo /tmp/godot.zip -d "$HOME/Applications" && rm /tmp/godot.zip
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true   # Gatekeeper: not installed via the App Store
  fi
  GODOT_BIN="$APP/Contents/MacOS/Godot"
elif [ -z "$GODOT_BIN" ]; then
  curl -L -o /tmp/godot.zip "https://github.com/godotengine/godot/releases/download/4.7-stable/Godot_v4.7-stable_linux.$ARCH.zip"
  unzip -qo /tmp/godot.zip -d "$BIN" && rm /tmp/godot.zip && mv "$BIN/Godot_v4.7-stable_linux.$ARCH" "$BIN/godot"
  GODOT_BIN="$BIN/godot"
fi

# --- rl/.env: dashboard password, Godot binary, venv -----------------------------------------
ENV="$HERE/.env"
touch "$ENV"; chmod 600 "$ENV"
grep -q '^GODOT=' "$ENV" || echo "GODOT=$GODOT_BIN" >> "$ENV"
grep -q '^VENV=' "$ENV" || echo "VENV=$VENV" >> "$ENV"
grep -q '^MCF_RLM_PASSWORD=' "$ENV" || echo "MCF_RLM_PASSWORD=$("$VENV/bin/python" -c 'import secrets; print(secrets.token_urlsafe(12))')" >> "$ENV"
set -a; . "$ENV"; set +a

# Godot's global class cache must know LegalIntents/LearnedController before a headless
# --script run (env_server.gd); one import pass does it.
"$GODOT" --version
( cd "$HERE/.." && "$GODOT" --headless --path . --import >/dev/null 2>&1 || true )

# --- cloudflared connector: rlm.mindcontrolfactor.com → this machine's :8501 -----------------
if [ -n "$TOKEN" ]; then
  if ! command -v cloudflared >/dev/null; then
    if [ "$OS" = Darwin ]; then
      [ "$ARCH" = arm64 ] && CFA=arm64 || CFA=amd64
      curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-$CFA.tgz | tar -xz -C "$BIN"
    else
      [ "$ARCH" = aarch64 ] && CFA=arm64 || CFA=amd64
      curl -L -o "$BIN/cloudflared" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CFA
    fi
    chmod +x "$BIN/cloudflared"
  fi
  grep -q '^TUNNEL_TOKEN=' "$ENV" || echo "TUNNEL_TOKEN=$TOKEN" >> "$ENV"
  if [ "$OS" = Darwin ]; then
    # User-level LaunchAgent (no sudo): starts at login, restarts if it dies.
    PL="$HOME/Library/LaunchAgents/com.mcf.rlm-tunnel.plist"; mkdir -p "$(dirname "$PL")"
    cat > "$PL" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.mcf.rlm-tunnel</string>
  <key>ProgramArguments</key><array>
    <string>$BIN/cloudflared</string><string>tunnel</string><string>run</string><string>--token</string><string>$TOKEN</string>
  </array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/mcf-rlm-tunnel.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/mcf-rlm-tunnel.log</string>
</dict></plist>
EOF
    launchctl unload "$PL" 2>/dev/null || true
    launchctl load "$PL"
    echo "tunnel connector: LaunchAgent com.mcf.rlm-tunnel (log: ~/Library/Logs/mcf-rlm-tunnel.log)"
  else
    echo "tunnel connector: start it with  bash rl/run.sh up  (Linux: no service without sudo)"
  fi
fi

echo
echo "ok: $VENV"
echo "dashboard password (also in $ENV): $MCF_RLM_PASSWORD"
echo "next:  bash rl/run.sh up                                    # dashboard :8501 + tensorboard :6006"
echo "       bash rl/run.sh start rl/config/laptop.yaml phaseA-1  # or press Start on the dashboard"
