#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MCF_RECLAIM_SYNC
MCF_RECLAIM_SYNC=$(mktemp -d)
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true; rm -rf "$MCF_RECLAIM_SYNC"' EXIT
roles=(host guest observer)
if [[ "${MCF_RECLAIM_SOLO:-0}" == 1 ]]; then roles=(host guest); fi
for role in "${roles[@]}"; do
  mkdir -p "$MCF_RECLAIM_SYNC/$role-home"
  XDG_DATA_HOME="$MCF_RECLAIM_SYNC/$role-home" "${GODOT:-godot}" --headless --path . --script res://tests/net_reclaim.gd -- "$role" > "$MCF_RECLAIM_SYNC/$role.log" 2>&1 &
  pids+=("$!")
  sleep 1
done
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
for role in "${roles[@]}"; do cat "$MCF_RECLAIM_SYNC/$role.log"; done
exit "$status"
