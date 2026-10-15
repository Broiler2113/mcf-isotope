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
import json, os
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
                os.kill(int(status['pid']), 0)
                live = True
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
touch "rl/runs/$BRANCH/SUPERVISOR_OFF"
bash rl/run.sh stop "$BRANCH"
for ((attempt=0; attempt<900; attempt++)); do
  if ! bash rl/run.sh alive "$BRANCH"; then break; fi
  sleep 2
done
if bash rl/run.sh alive "$BRANCH"; then
  echo 'Trainer is still finishing its update; code was not changed.'
  exit 1
fi
# Cleanup can run before the update and has no torch dependency. Keep reserve for
# the backup; never spend the final 500 MiB just to make an upgrade copy.
RESOURCE_HELPER=$(mktemp /tmp/isotope-resources.XXXXXX)
trap 'rm -f "$RESOURCE_HELPER"' EXIT
git show "$TARGET:rl/resources.py" > "$RESOURCE_HELPER"
"$RL_PY" "$RESOURCE_HELPER" --runs "$PROJECT_DIR/rl/runs"
"$RL_PY" - "$BRANCH" <<'PY'
from pathlib import Path
import shutil, sys, time
root = Path('rl/runs') / sys.argv[1]
source = root / 'latest.pt'
if shutil.disk_usage(root).free - source.stat().st_size < 500 * 1024**2:
    raise SystemExit('Not enough free space above 500 MiB for the backup; latest.pt is intact.')
shutil.copy2(source, root / ('pre-upgrade-' + time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '.pt'))
PY
git merge --ff-only "$TARGET"
bash rl/run.sh dashboard
bash rl/run.sh autonomous "$BRANCH"
echo "Installed: $BRANCH; automatic cleanup begins around 1 GiB free and targets 2 GiB."
echo 'The latest/best models and league opponents are protected. No admin password is needed.'
echo 'Pause and Stop in the dashboard still take effect.'
