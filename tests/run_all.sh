#!/usr/bin/env bash
# Регрессионные прогоны проекта. Запускать из корня проекта:  bash tests/run_all.sh
# Передать --update, чтобы пересобрать эталонный след после ОСОЗНАННОГО изменения правил.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

GODOT="${GODOT:-godot}"
EXTRA=""
[ "${1:-}" = "--update" ] && EXTRA="-- --update"

fail=0
run_suite() {
  echo "=== $1 ==="
  # shellcheck disable=SC2086
  "$GODOT" --headless --script "res://$1" $EXTRA
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "--- FAILED: $1 (exit $rc)"
    fail=1
  fi
}

run_suite tests/check_scripts.gd
# Every suite of every system folder (tests/README.md, «Layout»): a new run_*.gd in one of
# them runs without touching this file.
for dir in perf net combat vehicles ai events fog mapgen editor ui files audio; do
  for script in tests/$dir/run_*.gd; do
    run_suite "$script"
  done
done
# The learned AI and its native policy stay at the top level: rl/ and CI call them by path.
for script in tests/run_legal_intents.gd tests/run_intent_budget.gd tests/run_learned_controller.gd \
              tests/run_native_policy.gd tests/run_learned_town.gd tests/run_play_vs_learned.gd \
              tests/run_rl_tactics.gd tests/run_rl_learning.gd tests/run_rl_giant_defense.gd; do
  run_suite "$script"
done

# Стенд производительности (perf pass, §27.22) в режиме сверки: малая и средняя партии
# HARD против HARD с туманом, мирными и техникой, сетевой близнец, сохранение и повтор —
# итоговые хеши обязаны совпасть с tests/bench/expected.txt. Время здесь не проверяется.
echo "=== tests/bench/run_bench.gd ==="
# shellcheck disable=SC2086
"$GODOT" --headless --script res://tests/bench/run_bench.gd -- small medium --reps 1 ${EXTRA:+--update} || fail=1

# Приёмник отчётов об ошибках (0.12): сервер в tools/bugs, проверка без сети наружу.
echo "=== tools/bugs/test_isotope_bugs.py ==="
python3 tools/bugs/test_isotope_bugs.py || fail=1
python3 tests/bench/test_compare_timings.py || fail=1
python3 native/policy/test_manifest.py || fail=1

# Сетевая партия на двух процессах (batch 12): лобби → расстановка → бой по ENet.
echo "=== tests/run_net_match.sh ==="
bash tests/run_net_match.sh || fail=1
bash tests/run_net_reclaim.sh || fail=1
MCF_RECLAIM_SOLO=1 bash tests/run_net_reclaim.sh || fail=1
bash tests/run_net_spectators.sh || fail=1
bash tests/run_net_kick.sh || fail=1
bash tests/run_net_relay.sh || fail=1

if [ $fail -ne 0 ]; then
  echo "regression run FAILED"
  exit 1
fi
echo "regression run OK"
