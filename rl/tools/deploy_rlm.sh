#!/usr/bin/env bash
# Run from the training checkout. Fetch this script with git show before invoking it
# so an old checkout can perform the entire upgrade without overwriting a live env.
set -euo pipefail
PARENT="${1:-tactical-2}"
NEXT="${2:-tactical-3}"
PROJECT_DIR="$(git rev-parse --show-toplevel)"
cd "$PROJECT_DIR"
case "$PARENT:$NEXT" in *[!a-zA-Z0-9_.:-]*|:*|*:) echo 'Invalid branch name'; exit 2;; esac
[ "$PARENT" != "$NEXT" ] || { echo 'Choose a new training branch'; exit 2; }
[ -f "rl/runs/$PARENT/latest.pt" ] || { echo "Missing checkpoint for $PARENT on this machine"; exit 2; }
[ ! -e "rl/runs/$NEXT" ] || { echo "Training branch $NEXT already exists"; exit 2; }
git diff --quiet && git diff --cached --quiet || { echo 'Commit or preserve local tracked changes before upgrading'; exit 2; }
git fetch origin main
git merge-base --is-ancestor HEAD origin/main || { echo 'Checkout has diverged from origin/main; resolve it before upgrading'; exit 2; }
# Refuse an update that would overwrite local untracked files, before stopping work.
python3 - <<'PY'
import subprocess
incoming = set(subprocess.check_output(['git', 'diff', '--name-only', '-z', 'HEAD', 'origin/main']).split(b'\0'))
untracked = set(subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z']).split(b'\0'))
conflicts = (incoming & untracked) - {b''}
if conflicts:
    raise SystemExit('Update would overwrite untracked files: ' + ', '.join(p.decode() for p in conflicts))
PY

# Save the in-flight update before any game files change. An old supervisor must not
# restart the source branch while the new branch is being checked and started.
touch "rl/runs/$PARENT/SUPERVISOR_OFF"
bash rl/run.sh stop "$PARENT"
for ((attempt=0; attempt<900; attempt++)); do
  if ! bash rl/run.sh alive "$PARENT"; then break; fi
  sleep 2
done
if bash rl/run.sh alive "$PARENT"; then
  echo 'Trainer is still finishing its update; no code was changed. Retry after it stops.'
  exit 1
fi
BACKUP="rl/runs/$PARENT/pre-upgrade-$(date -u +%Y%m%dT%H%M%SZ).pt"
cp "rl/runs/$PARENT/latest.pt" "$BACKUP"
echo "Checkpoint preserved: $BACKUP"
git merge --ff-only origin/main
[ ! -f rl/.env ] || { set -a; . rl/.env; set +a; }
RL_PY="${VENV:-$HOME/.venvs/mcf-rl}/bin/python"
export PATH="$HOME/.local/bin:$PATH"
"$RL_PY" rl/train.py preflight rl/config/tactical.yaml
bash rl/run.sh fork "$PARENT/latest.pt" "$NEXT" rl/config/tactical.yaml
# Wait until actual learning advances, not just until the process exists.
"$RL_PY" - "$PARENT" "$NEXT" <<'PY'
import json, pathlib, sys, time
import torch
root = pathlib.Path('rl/runs')
parent, branch = sys.argv[1:]
step = torch.load(root / parent / 'latest.pt', map_location='cpu', weights_only=False)['global_step']
deadline = time.monotonic() + 1800
while time.monotonic() < deadline:
    try:
        state = json.loads((root / branch / 'status.json').read_text())
    except (OSError, ValueError):
        state = {}
    if state.get('state') in ('crashed', 'stopped'):
        raise SystemExit(f'New trainer did not stay running: {state.get("error", state.get("stop_reason", "stopped"))}. Source checkpoint is preserved.')
    if state.get('state') == 'running' and state.get('step', 0) > step:
        print(f'{branch} advanced beyond source step {step}: {state["step"]}; rules {state.get("code")}')
        break
    time.sleep(2)
else:
    raise SystemExit('New trainer has not advanced yet; inspect its log before retrying. No checkpoints were deleted.')
PY
bash rl/run.sh supervise "$NEXT"
bash rl/run.sh dashboard
echo "Deployed $(git rev-parse --short HEAD); $NEXT is training; $PARENT remains preserved and stopped."
