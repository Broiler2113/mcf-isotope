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
  # Godot mirrors stdout - which for the env servers IS the JSON protocol - into
  # app_userdata/.../logs/godot.log, at ~1.5 GB/hr with four envs. Two attempts to turn
  # that off through project.godot did nothing (the second used the correct
  # section-stripped key and still had no effect, so the setting appears not to apply to
  # `--script` runs). Truncating on a timer is crude but certain, and the file holds
  # nothing the trainer has not already consumed.
  LOGF="$HOME/Library/Application Support/Godot/app_userdata/MCF Isotope/logs/godot.log"
  if [ -f "$LOGF" ] && [ "$(wc -c < "$LOGF")" -gt 209715200 ]; then
    : > "$LOGF"
    say "truncated godot.log (was >200MB)"
  fi
  find "$HOME/Library/Application Support/Godot/app_userdata/MCF Isotope/logs" \
       -name 'godot2*.log' -delete 2>/dev/null

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
