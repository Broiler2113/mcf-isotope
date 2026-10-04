#!/usr/bin/env bash
# Регрессионные прогоны проекта. Запускать из корня проекта:  bash tests/run_all.sh
# Передать --update, чтобы пересобрать эталонный след после ОСОЗНАННОГО изменения правил.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

GODOT="${GODOT:-godot}"
EXTRA=""
[ "${1:-}" = "--update" ] && EXTRA="-- --update"

fail=0
for script in tests/check_scripts.gd tests/run_codec.gd tests/run_headless.gd \
              tests/run_lockstep.gd tests/run_player_actions.gd \
              tests/run_lobby_maps.gd tests/run_combat_safety.gd \
              tests/run_ui_assets.gd tests/run_ai_conduct.gd \
              tests/run_mirror_stamp.gd tests/run_modular_tank.gd \
              tests/run_mines_and_corpses.gd tests/run_batch13.gd \
              tests/run_shuttle.gd tests/run_borg.gd tests/run_batch17.gd \
              tests/run_legal_intents.gd tests/run_intent_budget.gd tests/run_learned_controller.gd \
              tests/run_learned_town.gd tests/run_mapgen.gd tests/run_play_vs_learned.gd tests/run_fog.gd \
              tests/run_incremental.gd tests/run_fog_viewer.gd tests/run_group_move.gd tests/run_team_session.gd \
              tests/run_ui_drones.gd tests/run_rl_tactics.gd tests/run_match_analysis.gd tests/run_soil_rulers.gd tests/run_batch_zones.gd tests/run_borg_corpses.gd tests/run_mp_perf.gd; do
  echo "=== $script ==="
  # shellcheck disable=SC2086
  "$GODOT" --headless --script "res://$script" $EXTRA
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "--- FAILED: $script (exit $rc)"
    fail=1
  fi
done

# Сетевая партия на двух процессах (batch 12): лобби → расстановка → бой по ENet.
echo "=== tests/run_net_match.sh ==="
bash tests/run_net_match.sh || fail=1

if [ $fail -ne 0 ]; then
  echo "regression run FAILED"
  exit 1
fi
echo "regression run OK"
