#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
godot --headless --script tests/net_host_spectator.gd > /tmp/mcf_spectator_host.log 2>&1 &
host_pid=$!
sleep 2
godot --headless --script tests/net_guest_spectator.gd > /tmp/mcf_spectator_a.log 2>&1 &
a_pid=$!
godot --headless --script tests/net_guest_spectator.gd > /tmp/mcf_spectator_b.log 2>&1 &
b_pid=$!
fail=0
wait "$host_pid" || fail=1
wait "$a_pid" || fail=1
wait "$b_pid" || fail=1
rg 'net smoke|FAIL|SCRIPT ERROR' /tmp/mcf_spectator_{host,a,b}.log
exit "$fail"
