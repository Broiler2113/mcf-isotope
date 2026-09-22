#!/usr/bin/env bash
# Keep one branch alive through genuine failures. Deliberately does NOT restart a branch
# that stopped cleanly: that is either an operator stop or mem_limit_mb, and relaunching
# into either produces a restart loop rather than a running trainer.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="${1:-town-3}"
CFG="${2:-$HERE/config/town.yaml}"
LOG="$HERE/runs/supervisor-$BRANCH.log"
say() { echo "$(date '+%F %T') $*" >> "$LOG"; }
say "supervising $BRANCH"
while true; do
  [ -f "$HERE/runs/$BRANCH/SUPERVISOR_OFF" ] && { sleep 60; continue; }
  verdict=$(python3 - "$HERE/runs/$BRANCH/status.json" <<'PY'
import json, os, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    print("unknown"); raise SystemExit
if s.get("state") == "crashed":
    print("crashed"); raise SystemExit
if s.get("state") in ("running", "paused"):
    try:
        os.kill(int(s["pid"]), 0); print("ok")
    except (OSError, ValueError, KeyError):
        print("dead")
    raise SystemExit
print(s.get("state", "unknown"))
PY
)
  case "$verdict" in
    crashed|dead)
      say "verdict=$verdict -> resuming"
      bash "$HERE/run.sh" resume "$BRANCH" "$CFG" >> "$LOG" 2>&1
      sleep 180 ;;                       # let it boot before judging again
    *) sleep 60 ;;
  esac
done
