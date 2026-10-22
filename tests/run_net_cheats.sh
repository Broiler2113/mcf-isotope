#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
godot_bin="${GODOT:-godot}"
"$godot_bin" --headless --path . --script res://tests/net_cheats_peer.gd -- host > /tmp/isotope-cheats-host.log 2>&1 &
host_pid=$!
sleep 1
"$godot_bin" --headless --path . --script res://tests/net_cheats_peer.gd -- guest > /tmp/isotope-cheats-guest.log 2>&1
guest_rc=$?
wait "$host_pid"
host_rc=$?
cat /tmp/isotope-cheats-host.log /tmp/isotope-cheats-guest.log
if [ "$guest_rc" -ne 0 ] || [ "$host_rc" -ne 0 ]; then exit 1; fi
if rg --no-filename 'SCRIPT ERROR|^ERROR:|^FAIL' /tmp/isotope-cheats-host.log /tmp/isotope-cheats-guest.log | rg -v '^ERROR: [0-9]+ resources still in use at exit'; then exit 1; fi
