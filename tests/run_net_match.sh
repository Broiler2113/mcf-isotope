#!/usr/bin/env bash
# Сетевой дымовой прогон (batch 12): ДВА процесса Godot на localhost — хост и гость —
# проходят настоящие сцены лобби → расстановка → бой через ENet. Запускать из корня:
#   bash tests/run_net_match.sh
# Порт NetworkSession.DEFAULT_PORT должен быть свободен.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
GODOT="${GODOT:-godot}"
fail=0
for pair in "asym" "mirror"; do
  echo "=== net match: $pair ==="
  "$GODOT" --headless --script "res://tests/net_host_$pair.gd" > "/tmp/mcf_net_host_$pair.log" 2>&1 &
  hpid=$!
  sleep 2
  "$GODOT" --headless --script "res://tests/net_guest_$pair.gd" > "/tmp/mcf_net_guest_$pair.log" 2>&1
  grc=$?
  wait $hpid
  hrc=$?
  grep -h "net smoke\|FAIL" "/tmp/mcf_net_host_$pair.log" "/tmp/mcf_net_guest_$pair.log"
  if [ $hrc -ne 0 ] || [ $grc -ne 0 ]; then
    echo "--- FAILED: net match $pair (host $hrc, guest $grc) — see /tmp/mcf_net_*_$pair.log"
    fail=1
  fi
done
[ $fail -ne 0 ] && { echo "net match FAILED"; exit 1; }
echo "net match OK"
