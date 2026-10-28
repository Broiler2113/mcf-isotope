extends SceneTree

var failures: PackedStringArray = []
var checks := 0

func ck(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)

func _initialize() -> void:
	_coverage()
	_visibility()
	_sees_gas_parity()
	_weapons()
	_atlas()
	if failures.is_empty():
		print("gas visibility: %d coverage, LOS, cache, weapon and autotile checks passed" % checks)
	else:
		for failure in failures:
			printerr(failure)
	quit(0 if failures.is_empty() else 1)

func _coverage() -> void:
	var m := MapData.blank_arena(16, 12)
	var features := [MCF.FEATURE_WALL, MCF.FEATURE_GLASS, MCF.FEATURE_ARMOR_GLASS,
		MCF.FEATURE_WOOD_WALL, MCF.FEATURE_SOIL, MCF.FEATURE_AIRLOCK, MCF.FEATURE_BOUNDARY]
	for i in features.size():
		m.set_cell(Vector2i(2 + i, 4), MCF.FLOOR_NORMAL, MCF.WALL_HEIGHT, false, features[i])
	m.set_cell(Vector2i(10, 4), MCF.FLOOR_NORMAL, 0.0, true, "")
	var state := m.build_state(971)
	var r := GameActionResolver.new(state)
	r.random_events.add_cloud(1, 2, 12, 6, 3)
	r._sync_gas()
	for i in features.size():
		var c := Vector2i(2 + i, 4)
		ck(not state.grid.cell(c).gas and not GasTiles.at(state.grid, c), features[i] + " excludes gas")
	ck(not state.grid.cell(Vector2i(10, 4)).gas, "vacuum excludes gas")
	ck(state.grid.cell(Vector2i(2, 3)).gas, "open floor carries gas")
	var c := state.grid.cell(Vector2i(2, 4))
	c.feature_id = ""
	c.cover_height = 0.0
	r.notify_cell_changed(c.coord)
	ck(c.gas, "demolishing a wall admits gas immediately")
	c.feature_id = MCF.FEATURE_GLASS
	c.cover_height = MCF.WALL_HEIGHT
	r.notify_cell_changed(c.coord)
	ck(not c.gas and not GasTiles.at(state.grid, c.coord), "building a window removes gas immediately")
	var door := state.grid.cell(Vector2i(7, 4))
	var visitor := state.spawn_unit(load("res://src/data/units/light_infantry.tres"), Vector2i(7, 3), 0)
	r.update_airlocks()
	ck(door.cover_height == 0.0 and door.gas, "opening an airlock admits surrounding gas")
	state.grid.move_occupant(visitor.coord, Vector2i(13, 10))
	r.update_airlocks()
	ck(door.cover_height == MCF.WALL_HEIGHT and not door.gas, "closing an airlock clears its gas")
	var restored := StateCodec.decode(StateCodec.encode(state))
	var rr := GameActionResolver.new(restored)
	StateCodec.apply_rules(rr, StateCodec.encode_rules(r))
	ck(not restored.grid.cell(c.coord).gas and restored.grid.cell(Vector2i(2, 3)).gas,
			"save/load rebuilds the same gas footprint")

func _visibility() -> void:
	for fog in [MCF.Fog.OFF, MCF.Fog.STANDARD, MCF.Fog.REALISTIC]:
		var m := MapData.blank_arena(12, 12)
		m.set_spawn(Vector2i(2, 5), "light_infantry", 0)
		m.set_spawn(Vector2i(8, 5), "light_infantry", 1)
		var state := m.build_state(971)
		var r := GameActionResolver.new(state)
		r.fog_mode = fog
		var origin := Vector2i(2, 5)
		var target := Vector2i(8, 5)
		# Through the cloud, target in gas, observer in gas, and an oblique ray.
		for cloud in [Vector2i(5, 5), target, origin, Vector2i(5, 6)]:
			ck(r.team_visible_coords(0).has(target), "clear arena starts visible")
			r.random_events.add_cloud(cloud.x, cloud.y, 1, 1, 3)
			r._sync_gas()
			if cloud.y == 5:
				# Gas is a curtain with fog off too (0.11.1, user rule).
				ck(not r.team_visible_coords(0).has(target), "warm team cache hides enemy into/out of/through gas")
				ck(r.los_blocked(origin, target, true, true, true), "gas blocks firing line including endpoints")
			var seen := r._seen_from(origin, 12, 0)
			for y in 12:
				for x in 12:
					var at := Vector2i(x, y)
					ck(seen.has(y * 12 + x) == not r._vision_blocked(origin, at, 0),
							"cached sweep agrees with direct LOS at " + str(at))
			r._clear_seen()
			ck(r._seen_from(origin, 12, 0) == seen, "cold and warm gas visibility agree")
			r.random_events.clouds.clear()
			r._sync_gas()
			ck(r.team_visible_coords(0).has(target), "visibility recovers after gas dissipates")

## team_sees_gas (one sweep per eye over a mask without gas, kept per eye) against the
## ray-per-pair reference: random walls, glass, gas and smoke, two sides, an enemy tank, and
## again after soldiers move, a wall falls and the smoke clears.
func _sees_gas_parity() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var li: UnitStats = load("res://src/data/units/light_infantry.tres")
	var walls := [MCF.FEATURE_WALL, MCF.FEATURE_WALL, MCF.FEATURE_GLASS, MCF.FEATURE_WOOD_WALL]
	var seen_some := 0
	for trial in 16:
		var w := rng.randi_range(10, 26)
		var h := rng.randi_range(8, 18)
		var tank := trial % 3 == 0
		var m := MapData.blank_arena(w, h)
		for i in rng.randi_range(w, w * h / 4):
			var c := Vector2i(rng.randi_range(0, w - 1), rng.randi_range(0, h - 1))
			if tank and c.x <= 4 and c.y <= 4: continue
			m.set_cell(c, MCF.FLOOR_NORMAL, MCF.WALL_HEIGHT, false, walls[rng.randi_range(0, walls.size() - 1)])
		var state := m.build_state(971 + trial)
		var r := GameActionResolver.new(state)
		r.fog_mode = MCF.Fog.STANDARD
		if tank: state.spawn_vehicle("tank", Vector2i(1, 1), 1)
		var free := func() -> Vector2i:
			while true:
				var c := Vector2i(rng.randi_range(0, w - 1), rng.randi_range(0, h - 1))
				var cell := state.grid.cell(c)
				if cell.feature_id == "" and cell.occupant == null and not (tank and c.x <= 4 and c.y <= 4):
					return c
			return Vector2i.ZERO
		var units: Array = []
		for i in rng.randi_range(2, 9): units.append(state.spawn_unit(li, free.call(), i % 2))
		for i in rng.randi_range(1, 3):
			var x := rng.randi_range(0, w - 3)
			var y := rng.randi_range(0, h - 3)
			if i % 2 == 0: r.random_events.add_cloud(x, y, rng.randi_range(1, 6), rng.randi_range(1, 5), 3)
			else: r.random_events.add_smoke(x, y, rng.randi_range(1, 6), rng.randi_range(1, 5), 3)
		if tank: r.random_events.add_smoke(0, 0, 5, 5, 3)   # the hull under smoke still blocks
		r._sync_gas()
		for step in 4:
			if step == 1:
				for u: UnitInstance in units.slice(0, 2): state.grid.move_occupant(u.coord, free.call())
			elif step == 2:
				for y in h:
					for x in w:
						var wc := state.grid.cell(Vector2i(x, y))
						if wc.feature_id == MCF.FEATURE_WALL and rng.randf() < 0.3:
							wc.feature_id = ""
							wc.cover_height = 0.0
							r.notify_cell_changed(wc.coord)
			elif step == 3:
				r.random_events.smoke.clear()
				r._sync_gas()
			for side in [0, 1]:
				var got := r.team_sees_gas(side)
				var want := r._team_sees_gas_reference(side)
				var same := got.size() == want.size()
				for c: Vector2i in want:
					same = same and got.has(c)
				seen_some += want.size()
				ck(same, "trial %d step %d side %d: seen gas %d cells, rays say %d" % [trial, step, side, got.size(), want.size()])
	ck(seen_some > 100, "the parity boards put gas in sight (%d cells)" % seen_some)

func _weapons() -> void:
	for profession in ["light_infantry", "marksman", "flamethrower", "anti_tank"]:
		var m := MapData.blank_arena(12, 12)
		m.set_spawn(Vector2i(2, 5), profession, 0)
		m.set_spawn(Vector2i(6, 5), "light_infantry", 1)
		var state := m.build_state(971)
		var r := GameActionResolver.new(state)
		r.fog_mode = MCF.Fog.OFF
		var shooter := state.grid.cell(Vector2i(2, 5)).occupant
		var target := state.grid.cell(Vector2i(6, 5)).occupant
		ck(r.can_shoot(shooter, target) == "", profession + " can initially aim")
		r.random_events.add_cloud(4, 5, 1, 1, 3)
		r._sync_gas()
		# Issues-fix-6: gas hides the target from a lone shooter, even with fog disabled…
		ck(r.can_shoot(shooter, target) == "Target not visible", profession + " cannot pick a target hidden by gas")
		# …but once a teammate spots it, fire goes through the cloud at a penalty.
		state.spawn_unit(load("res://src/data/units/light_infantry.tres"), Vector2i(6, 9), 0)
		r.team_visible_coords(0)
		ck(r.can_shoot(shooter, target) == "", profession + " fires through gas at a spotted target")
		if profession == "light_infantry":
			var mods: Array = []
			var need := r.hit_need_for(shooter, target, mods)
			ck(str(mods).contains("Gas") or str(mods).contains("Smoke"), "the gas penalty is named in the roll (%s)" % [mods])
			ck(need == r.hit_need(4, shooter.fire_range()) + GameActionResolver.SMOKE_HIT_PENALTY, "the shot through gas needs +2")
		if profession == "marksman":
			ck(r.can_laser_cell(shooter, target.coord) == "", "laser cell aim passes gas")
		if profession == "flamethrower":
			ck(r.can_flame_cell(shooter, target.coord) == "", "flame cell aim passes gas")

func _atlas() -> void:
	var tex := GasTiles.texture()
	ck(tex != null and tex.get_width() == 64 and tex.get_height() == 4096, "bounded 1 MiB gas atlas")
	ck(GasTiles.texture() == tex, "gas atlas is reused")
	if tex == null:
		return
	var img := tex.get_image()
	var a := GasTiles.source_rect(tex, Vector2i(3, 3), 15)
	var east := GasTiles.source_rect(tex, Vector2i(4, 3), 15)
	var south := GasTiles.source_rect(tex, Vector2i(3, 4), 15)
	for i in GasTiles.TILE:
		ck(img.get_pixel(a.position.x + GasTiles.TILE - 1, a.position.y + i) == img.get_pixel(east.position.x, east.position.y + i), "east/west pixels join")
		ck(img.get_pixel(a.position.x + i, a.position.y + GasTiles.TILE - 1) == img.get_pixel(south.position.x + i, south.position.y), "north/south pixels join")
	var grid := Grid.new(3, 3)
	grid.cell(Vector2i(1, 1)).gas = true
	grid.cell(Vector2i(2, 1)).gas = true
	ck(GasTiles.mask_at(grid, Vector2i(1, 1)) == Sprites.AUTOTILE_E, "cloud connects to neighbouring gas")
	grid.cell(Vector2i(2, 1)).cover_height = MCF.WALL_HEIGHT
	ck(GasTiles.mask_at(grid, Vector2i(1, 1)) == 0, "wall breaks the cloud edge even before resync")
