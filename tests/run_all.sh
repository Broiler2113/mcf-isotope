#!/usr/bin/env bash
# Регрессионные прогоны проекта. Запускать из корня проекта:  bash tests/run_all.sh
# Передать --update, чтобы пересобрать эталонный след после ОСОЗНАННОГО изменения правил.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

GODOT="${GODOT:-godot}"
EXTRA=""
[ "${1:-}" = "--update" ] && EXTRA="-- --update"

fail=0
for script in tests/run_headless.gd tests/run_lockstep.gd; do
  echo "=== $script ==="
  # shellcheck disable=SC2086
  "$GODOT" --headless --script "res://$script" $EXTRA
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "--- FAILED: $script (exit $rc)"
    fail=1
  fi
done

if [ $fail -ne 0 ]; then
  echo "regression run FAILED"
  exit 1
fi
echo "regression run OK"
