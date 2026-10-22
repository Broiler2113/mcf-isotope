#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
godot_bin="${GODOT:-godot}"
"$godot_bin" --headless --path . --script res://tests/net_first_person_peer.gd -- host > /tmp/isotope-fp-host.log 2>&1 &
host_pid=$!
sleep 1
"$godot_bin" --headless --path . --script res://tests/net_first_person_peer.gd -- guest > /tmp/isotope-fp-guest.log 2>&1
guest_rc=$?
wait "$host_pid"
host_rc=$?
cat /tmp/isotope-fp-host.log /tmp/isotope-fp-guest.log
if [ "$guest_rc" -ne 0 ] || [ "$host_rc" -ne 0 ]; then exit 1; fi
if rg --no-filename 'SCRIPT ERROR|^ERROR:|^FAIL' /tmp/isotope-fp-host.log /tmp/isotope-fp-guest.log | rg -v '^ERROR: [0-9]+ resources still in use at exit'; then exit 1; fi
