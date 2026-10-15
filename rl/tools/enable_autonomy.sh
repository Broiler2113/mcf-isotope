#!/usr/bin/env bash
# Run a fetched copy from the training checkout, even when that checkout is older.
# Usage: bash /tmp/isotope-enable-autonomy.sh [branch] [git-ref]
set -euo pipefail
PROJECT_DIR="$(git rev-parse --show-toplevel)"
cd "$PROJECT_DIR"
TARGET="${2:-origin/main}"
git diff --quiet && git diff --cached --quiet || { echo 'Preserve local tracked changes before updating.'; exit 2; }
git merge-base --is-ancestor HEAD "$TARGET" || { echo 'Checkout has diverged; no training files changed.'; exit 2; }
BRANCH="${1:-}"
if [ -z "$BRANCH" ]; then
  BRANCH=$(python3 - <<'PY'
import json, shlex, subprocess
from pathlib import Path
states = []
for path in Path('rl/runs').glob('*/status.json'):
    if not (path.parent / 'latest.pt').is_file():
        continue
    try:
        status = json.loads(path.read_text())
        live = False
        if status.get('state') in ('running', 'paused'):
            try:
                command = subprocess.run(['ps', '-p', str(int(status['pid'])), '-o', 'command='],
                                         capture_output=True, text=True)
                args = shlex.split(command.stdout)
                live = any(Path(a).name == 'train.py' for a in args) and path.parent.name in args
            except (OSError, ValueError, KeyError):
                pass
        states.append((live, path.stat().st_mtime, path.parent.name))
    except (OSError, ValueError):
        pass
if sum(live for live, _, _ in states) > 1:
    raise SystemExit('Several trainers are live. Pass the branch to continue explicitly.')
if not states:
    raise SystemExit('No resumable training branch found.')
print(max(states)[2])
PY
)
fi
case "$BRANCH" in ''|.|..|*[!a-zA-Z0-9_.-]*) echo 'Invalid branch name'; exit 2;; esac
[ -f "rl/runs/$BRANCH/latest.pt" ] || { echo "No checkpoint for $BRANCH"; exit 2; }
echo "Continuing $BRANCH under persistent supervision."
[ ! -f rl/.env ] || { set -a; . rl/.env; set +a; }
RL_PY="${VENV:-$HOME/.venvs/mcf-rl}/bin/python"
export MCF_RL_PYTHON="$RL_PY"
# Check untracked collisions before stopping the existing process.
python3 - "$TARGET" <<'PY'
import subprocess, sys
incoming = set(subprocess.check_output(['git', 'diff', '--name-only', '-z', 'HEAD', sys.argv[1]]).split(b'\0'))
untracked = set(subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z']).split(b'\0'))
if (incoming & untracked) - {b''}:
    raise SystemExit('Update would overwrite untracked files; preserve them first.')
PY
alive_branch() {
  python3 - "$BRANCH" <<'PY'
import json, shlex, subprocess, sys
from pathlib import Path
try:
    state = json.loads((Path('rl/runs') / sys.argv[1] / 'status.json').read_text())
    command = subprocess.run(['ps', '-p', str(int(state['pid'])), '-o', 'command='],
                             capture_output=True, text=True)
    args = shlex.split(command.stdout)
    sys.exit(0 if any(Path(a).name == 'train.py' for a in args) and sys.argv[1] in args else 1)
except (OSError, ValueError, KeyError):
    sys.exit(1)
PY
}
touch "rl/runs/$BRANCH/SUPERVISOR_OFF"
bash rl/run.sh stop "$BRANCH"
for ((attempt=0; attempt<900; attempt++)); do
  if ! alive_branch; then break; fi
  sleep 2
done
if alive_branch; then
  echo 'Trainer is still finishing its update; code was not changed.'
  exit 1
fi
# Cleanup can run before the update and has no torch dependency. Keep reserve for
# the backup; never spend the final 500 MiB just to make an upgrade copy.
RESOURCE_HELPER=$(mktemp /tmp/isotope-resources.XXXXXX)
trap 'rm -f "$RESOURCE_HELPER"' EXIT
git show "$TARGET:rl/resources.py" > "$RESOURCE_HELPER"
"$RL_PY" "$RESOURCE_HELPER" --runs "$PROJECT_DIR/rl/runs"
BACKUP="$PROJECT_DIR/rl/runs/$BRANCH/pre-upgrade-$(date -u +%Y%m%dT%H%M%SZ).pt"
"$RL_PY" - "$BRANCH" "$BACKUP" <<'PY'
from pathlib import Path
import shutil, sys
root = Path('rl/runs') / sys.argv[1]
source = root / 'latest.pt'
if shutil.disk_usage(root).free - source.stat().st_size < 500 * 1024**2:
    raise SystemExit('Not enough free space above 500 MiB for the backup; latest.pt is intact.')
shutil.copy2(source, sys.argv[2])
PY
git merge --ff-only "$TARGET"
bash rl/run.sh dashboard
bash rl/run.sh autonomous "$BRANCH"
echo "Installed: $BRANCH; automatic cleanup begins around 1 GiB free and targets 2 GiB."
echo 'The latest/best models and league opponents are protected. No admin password is needed.'
echo 'Pause and Stop in the dashboard still take effect.'
"$RL_PY" - "$BRANCH" "$BACKUP" <<'PY'
from pathlib import Path
import json, os, shutil, sys, time
import torch
root = Path('rl/runs') / sys.argv[1]
before = int(torch.load(sys.argv[2], map_location='cpu', weights_only=False)['global_step'])
deadline = time.monotonic() + 900
while time.monotonic() < deadline:
    try:
        state = json.loads((root / 'status.json').read_text())
        if state.get('state') == 'running' and int(state.get('step', 0)) > before:
            os.kill(int(state['pid']), 0)
            free = shutil.disk_usage(root).free / 1024**2
            if free >= 500:
                print(f"Verified {root.name}: step {before:,} -> {state['step']:,}; disk free {free:,.0f} MiB", flush=True)
                break
        print(f"Waiting for learning to advance: {state.get('state')} step={state.get('step')} {state.get('activity', '')}", flush=True)
    except (OSError, ValueError, KeyError):
        print('Waiting for the first training heartbeat...', flush=True)
    time.sleep(15)
else:
    raise SystemExit('Service installed, but learning has not advanced yet. Check rl/runs/autonomy.log and the branch log.')
PY
