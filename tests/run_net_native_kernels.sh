#!/usr/bin/env bash
# Real lobby/placement/combat peers with native and reference kernels mixed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
godot_bin="${GODOT:-godot}"
for native_side in host guest; do
  host_mode=off
  guest_mode=off
  if [ "$native_side" = host ]; then host_mode=on; else guest_mode=on; fi
  host_log="/tmp/isotope-native-net-host-$native_side.log"
  guest_log="/tmp/isotope-native-net-guest-$native_side.log"
  env MCF_NATIVE_KERNELS="$host_mode" MCF_NATIVE_VISUALS="$host_mode" "$godot_bin" --headless --path . --script res://tests/net_host_town.gd > "$host_log" 2>&1 &
  host_pid=$!
  trap 'kill "$host_pid" 2>/dev/null || true' EXIT
  sleep 2
  env MCF_NATIVE_KERNELS="$guest_mode" MCF_NATIVE_VISUALS="$guest_mode" "$godot_bin" --headless --path . --script res://tests/net_guest_town.gd > "$guest_log" 2>&1
  guest_rc=$?
  wait "$host_pid"
  host_rc=$?
  trap - EXIT
  if [ "$host_rc" -ne 0 ] || [ "$guest_rc" -ne 0 ]; then
    cat "$host_log" "$guest_log"
    exit 1
  fi
  # NetSmokeBase exits with its UI scene live; its existing teardown-only resource
  # diagnostics also occur in the reference peer. Runtime errors still fail.
  if rg --no-filename 'SCRIPT ERROR|^ERROR:|^FAIL' "$host_log" "$guest_log" | rg -v '^ERROR: ([0-9]+ resources still in use at exit|[0-9]+ RID allocations .* were leaked at exit\.)'; then exit 1; fi
  rg --no-filename 'net smoke' "$host_log" "$guest_log"
  echo "Mixed native/reference multiplayer passed with native $native_side."
done
