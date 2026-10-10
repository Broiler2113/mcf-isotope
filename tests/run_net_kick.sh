#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
godot --headless --script tests/net_host_kick.gd > /tmp/mcf_kick_host.log 2>&1 &
host_pid=$!
sleep 2
godot --headless --script tests/net_guest_kick.gd > /tmp/mcf_kick_guest.log 2>&1 &
guest_pid=$!
fail=0
wait "$host_pid" || fail=1
wait "$guest_pid" || fail=1
rg 'net smoke|FAIL|SCRIPT ERROR' /tmp/mcf_kick_{host,guest}.log
exit "$fail"
