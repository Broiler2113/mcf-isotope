#!/usr/bin/env bash
# Keep one branch alive. Restarts a crash, a vanished process, and a RESOURCE stop (the
# trainer ran out of disk, or out of memory it could not shrink under); leaves an operator
# stop alone, so `run.sh stop` and the dashboard's Stop still mean stop.
#
# The resource case used to be excluded together with the operator one, on the grounds that
# relaunching into mem_limit_mb gives a restart loop rather than a trainer. That was true
# when the memory ceiling ended the run outright; it now shrinks the rollout and carries on,
# so a memory stop means the base process itself did not fit and a restart is worth one try.
# A disk stop is worth retrying too — space comes back when something else on the machine
# releases it — but slowly, which is what RESOURCE_BACKOFF is for. Without this the trainer
# sat stopped for hours overnight while a watchdog pressed Start for it 28 times.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="${1:-town-3}"
CFG="${2:-$HERE/config/town.yaml}"
LOG="$HERE/runs/supervisor-$BRANCH.log"
# Public URL the tunnel watchdog probes. Read from rl/.env so the token and the hostname
# live in the same untracked place; empty disables the watchdog.
[ -f "$HERE/.env" ] && set -a && . "$HERE/.env" && set +a
TUNNEL_URL="${TUNNEL_URL:-}"
say() { echo "$(date '+%F %T') $*" >> "$LOG"; }
say "supervising $BRANCH"
MEMORY_RETRY=10
while true; do
  # --- tunnel watchdog -----------------------------------------------------------
  #
  # Checking that cloudflared is RUNNING is not enough, and that is the whole point of
  # this block. The failure seen twice now is a live process holding no edge connections:
  # `ps` shows it up, localhost:8501 answers 200, and the public host serves Cloudflare
  # 1033. A pid check calls that healthy. Only an end-to-end request can tell.
  #
  # So: ask the PUBLIC url. If it answers, nothing to do. If it does not, ask localhost
  # first — when the dashboard itself is down the tunnel is innocent and restarting it
  # would be noise. Only "local fine, public broken" means the tunnel, and that is the
  # case a restart actually fixes.
  if [ -n "${TUNNEL_URL:-}" ]; then
    pub=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$TUNNEL_URL" || echo 000)
    if [ "$pub" != 200 ]; then
      loc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            "http://127.0.0.1:${DASH_PORT:-8501}/" || echo 000)
      if [ "$loc" = 200 ]; then
        # Restart THROUGH the owner, never around it. cloudflared belongs to the launchd
        # agent com.mcf.rlm-tunnel (KeepAlive), so spawning a replacement here would give
        # one tunnel two processes; `kickstart -k` kills and relaunches the agent's own
        # instance, leaving exactly one. On anything without launchd, fall back to run.sh.
        say "tunnel down: public=$pub local=$loc -> kickstarting com.mcf.rlm-tunnel"
        # SIGCONT first. A SUSPENDED cloudflared (state T) is one of the shapes this
        # failure takes, and a stopped process never reaches the signal handler that makes
        # it shut down, so the kickstart leaves the old instance behind and the tunnel ends
        # up with two processes - worse than the fault being repaired. Resuming it first
        # lets it actually die.
        pkill -CONT -f 'cloudflared tunnel run' 2>/dev/null
        if command -v launchctl >/dev/null 2>&1 \
           && launchctl print "gui/$(id -u)/com.mcf.rlm-tunnel" >/dev/null 2>&1; then
          launchctl kickstart -k "gui/$(id -u)/com.mcf.rlm-tunnel" >> "$LOG" 2>&1
        else
          pkill -f 'cloudflared tunnel run' 2>/dev/null
          sleep 3
          bash "$HERE/run.sh" up >> "$LOG" 2>&1
        fi
        sleep 20
      else
        say "public=$pub but local=$loc too - dashboard problem, not the tunnel"
      fi
    fi
  fi

  [ -f "$HERE/runs/$BRANCH/SUPERVISOR_OFF" ] && { sleep 60; continue; }
  # Keep diagnostic files bounded even while the trainer is stopped. Memory
  # cleanup belongs to the live process; deleting logs cannot release RAM.
  RL_RESOURCE_PY="${VENV:-$HOME/.venvs/mcf-rl}/bin/python"
  "$RL_RESOURCE_PY" "$HERE/resources.py" >> "$LOG" 2>&1
  # A STOP still lying in the run directory is the operator's: never resume over it, even
  # if the trainer recorded a resource reason on its way out (a stop that landed while
  # the disk sat under its floor once came back as "disk" and was resumed).
  [ -f "$HERE/runs/$BRANCH/STOP" ] && { sleep 60; continue; }
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
# A clean stop says WHY in stop_reason: "memory"/"disk" are the machine's doing and worth
# resuming, an operator stop leaves it empty and must be left alone.
reason = str(s.get("stop_reason") or "")
print(f"resource:{reason}" if reason in ("memory", "disk") else s.get("state", "unknown"))
PY
)
  case "$verdict" in
    crashed|dead)
      say "verdict=$verdict -> resuming"
      bash "$HERE/run.sh" resume "$BRANCH" "$CFG" >> "$LOG" 2>&1
      sleep 180 ;;                       # let it boot before judging again
    resource:memory)
      # A fresh process releases Metal graph/allocator memory that empty_cache
      # cannot. Resume promptly once, then back off if the machine still cannot fit.
      say "verdict=$verdict -> resuming in ${MEMORY_RETRY}s (checkpoint preserved)"
      sleep "$MEMORY_RETRY"
      [ -f "$HERE/runs/$BRANCH/SUPERVISOR_OFF" ] && continue
      [ -f "$HERE/runs/$BRANCH/STOP" ] && continue
      bash "$HERE/run.sh" resume "$BRANCH" "$CFG" >> "$LOG" 2>&1
      MEMORY_RETRY=$(( MEMORY_RETRY < 300 ? MEMORY_RETRY * 2 : 600 ))
      sleep 10 ;;
    resource:disk)
      # Space or memory. Back off so a machine that genuinely has neither is not thrashed,
      # and so the log reads as "retrying every 10 min", not a loop.
      say "verdict=$verdict -> resuming (resource stop)"
      bash "$HERE/run.sh" resume "$BRANCH" "$CFG" >> "$LOG" 2>&1
      sleep "${RESOURCE_BACKOFF:-600}" ;;
    ok) MEMORY_RETRY=10; sleep 30 ;;
    *) sleep 30 ;;
  esac
done
