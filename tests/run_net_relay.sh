#!/usr/bin/env bash
# Internet play (0.11): the same two-process matches as run_net_match.sh, but host and guest
# talk through a local copy of the Isotope relay (tools/relay/isotope_relay.py).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
GODOT="${GODOT:-godot}"
python3 tools/relay/isotope_relay.py --self-test || exit 1
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 tools/relay/isotope_relay.py --port "$PORT" > /tmp/mcf_relay.log 2>&1 &
rpid=$!
sleep 1
fail=0
for pair in "asym" "town" "unready"; do
  echo "=== relay match: $pair ==="
  export MCF_TEST_RELAY="127.0.0.1:$PORT" MCF_TEST_RELAY_TAG="$pair"
  "$GODOT" --headless --script "res://tests/net_host_$pair.gd" > "/tmp/mcf_relay_host_$pair.log" 2>&1 &
  hpid=$!
  "$GODOT" --headless --script "res://tests/net_guest_$pair.gd" > "/tmp/mcf_relay_guest_$pair.log" 2>&1
  grc=$?
  wait $hpid
  hrc=$?
  grep -h "net smoke\|FAIL" "/tmp/mcf_relay_host_$pair.log" "/tmp/mcf_relay_guest_$pair.log"
  if [ $hrc -ne 0 ] || [ $grc -ne 0 ]; then
    echo "--- FAILED: relay match $pair (host $hrc, guest $grc) — see /tmp/mcf_relay_*_$pair.log"
    fail=1
  fi
done
kill $rpid 2>/dev/null
[ $fail -ne 0 ] && { echo "relay match FAILED"; exit 1; }
echo "relay match OK"
