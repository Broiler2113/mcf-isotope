extends "res://tests/NetSmokeBase.gd"

## Сценарий из отчёта «Isotope issues fix 2» (batch 14): хост заранее выставляет второй
## слот в «Player», гость садится в него, карта — поставочный «town» с мирными, туман
## STANDARD, у хоста челнок с оператором дронов. Проверяется, что гость ВИДИТ армию
## хоста в своём состоянии (все id совпадают), ни одно действие хоста не отвергается
## на госте «Unit not found», и после хода хоста никто не объявляет победу.
var _denied := 0
func _initialize() -> void:
	tag = "host-t"
	start_net(true)
	step("lobby up", func() -> bool: return scene_is("Lobby.gd") and current_scene._status != null,
		func() -> void:
			var lob = current_scene
			lob._on_slot_kind(2, 1)  # reserve the seat by hand
			lob._fog_opt.select(1); lob._fog_opt.item_selected.emit(1)
			# Мирных выключаем: слот из полутора сотен жителей играется десятки секунд,
			# а проверяется здесь не он, а совпадение досок и отсутствие отказов.
			lob._no_neutrals_check.button_pressed = true
			for i in lob._map_opt.item_count:
				if lob._map_opt.get_item_text(i).find("town") >= 0:
					lob._map_opt.select(i); lob._map_opt.item_selected.emit(i)
			lob._on_slot_budget(2000.0, 0); lob._on_slot_budget(2000.0, 1))
	step("guest seated in the reserved slot", func() -> bool:
		var r: Roster = current_scene.roster
		return r.slots.size() == 2 and r.slots[1].kind == Roster.SlotKind.HUMAN and r.slots[1].peer_id > 1)
	step("start", func() -> bool: return _step_t > 1.5, func() -> void: current_scene._on_start())
	step("placement up", func() -> bool: return scene_is("Placement.gd") and current_scene._status != null,
		func() -> void:
			var pl = current_scene
			var zone: Array = pl._zone_cells(0)
			ck(zone.size() > 20, "host zone has room (%d)" % zone.size())
			var placed := 0
			pl.brush_unit = "shuttle"
			for c in zone:
				if placed == 0 and pl._footprint_placeable("shuttle", c, 0):
					pl._click_cell(c); placed += 1
			pl.brush_unit = "drone_operator"
			for c in zone:
				if placed < 2 and pl._placed_at(c) == -1 and pl._footprint_placeable("drone_operator", c, 0):
					pl._click_cell(c); placed += 1
			pl.brush_unit = "light_infantry"
			for c in zone:
				if placed < 6 and pl._placed_at(c) == -1 and pl._footprint_placeable("light_infantry", c, 0):
					pl._click_cell(c); placed += 1
			ck(pl._side_unit_count(0) == 6, "host placed 6 things (%d)" % pl._side_unit_count(0))
			pl._on_net_ready())
	step("battle up", func() -> bool: return scene_is("Main.gd") and current_scene.net != null,
		func() -> void:
			var m = current_scene
			print("[host-t] units=%d vehicles=%d" % [m.state.all_units().size(), m.state.all_vehicles().size()])
			print("[host-t] digest ", load("res://tests/TestSupport.gd").digest(m.state).hash()))
	step("host's turn: move every infantryman one cell, then end", func() -> bool:
		poke_dice()
		var m = current_scene
		return m.state.active_player() == 0 and not m._animating and not m._net_playing,
		func() -> void:
			var m = current_scene
			var n := 0
			for u in m.state.living_units_of(0):
				if u.is_drone or u.aboard_vehicle_id != -1:
					continue
				var reach = m.resolver.reachable_for(u, u.speed())
				for c in reach.cost:
					if c != u.coord and reach.cost[c] <= 2:
						m._on_intent_ready(MoveIntent.new(u.id, c)); n += 1
						break
				if n >= 3: break
			ck(n >= 3, "host ordered %d moves" % n))
	step("end turn", func() -> bool:
		poke_dice()
		var m = current_scene
		return not m._animating and not m._net_playing and m.state.active_player() == 0 and _step_t > 1.5,
		func() -> void: current_scene._on_intent_ready(EndTurnIntent.new()))
	step("turn passed to the guest without a victory", func() -> bool:
		poke_dice()
		var m = current_scene
		return m.state.active_player() == 1 and not m._animating and not m._net_playing,
		func() -> void:
			var m = current_scene
			ck(not m._match_over, "no victory on the host")
			for l in m.state.log.lines:
				if str(l).find("[denied]") >= 0: _denied += 1
			ck(_denied == 0, "no denied actions on the host (%d)" % _denied)
			print("[host-t] digest ", load("res://tests/TestSupport.gd").digest(m.state).hash()))
	step("hold", func() -> bool: return _step_t > 4.0)
