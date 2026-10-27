@abstract
extends "res://scenes/main/MainState.gd"

## Camera and board geometry: cells to screen and back, panning and centering, what the
## viewer sees right now (before an impact lands), ground and sky behind the board.

## One board draw per frame. A redraw asked for after _process (AI timers, tweens) drew
## the whole board at the start of the next frame and again after its _process, and only
## the second draw was ever shown. Requests now wait for the end of _process (Main.gd).
var _redraw_wanted := false
func _redraw() -> void:
	if video_export or not is_processing(): queue_redraw()
	else: _redraw_wanted = true

## The cells _visible_before_impact(viewer) leaves out, when known as a short list
## (GameActionResolver.visible_complement); null otherwise.
func _hidden_before_impact(viewer: int) -> Variant:
	var view := _view_resolver()
	if view.visibility_limited():
		var held: Dictionary = _hold_visual.get("visible", {})
		if held.has(viewer): return (_hold_visual.get("hidden", {}) as Dictionary).get(viewer)
	return view.visible_complement(viewer)

func _visible_before_impact(viewer: int) -> Dictionary:
	if _view_resolver().visibility_limited():
		var held: Dictionary = _hold_visual.get("visible", {})
		if held.has(viewer): return held[viewer]
	return _view_resolver().team_visible_coords(viewer)


# Standalone feature overlays must use the same pre-impact IDs as terrain tiles.
func _display_feature_cells(fid: String) -> Array[Vector2i]:
	var live := resolver._feature_cells(fid)
	var held: Dictionary = _hold_visual.get("cells", {})
	if held.is_empty(): return live
	var coords := {}
	for c: Vector2i in live: coords[c] = true
	for c: Vector2i in held:
		coords.erase(c)
		if held[c].get("feature_id", "") == fid: coords[c] = true
	var out: Array[Vector2i] = []
	out.assign(coords.keys())
	return out

# A shallow board view shares untouched cells and copies only the held area. Terrain
# tiles (including neighbouring autotiles), LOD and lighting all see the same state.
func _terrain_before_impact(base: Grid, visible: Dictionary, fog_on: bool) -> Grid:
	var cells: Dictionary = _hold_visual.get("cells", {})
	if cells.is_empty():
		_held_grid = null
		_held_grid_key = []
		_held_visible_source = {}
		return base
	var key := [base.get_instance_id(), cells.hash(), fog_on]
	if _held_grid != null and key == _held_grid_key and (not fog_on or is_same(visible, _held_visible_source)):
		return _held_grid
	var logs := GridCell.logs_snapshot()
	GridCell.journaling = false
	var view := Grid.new(0, 0)
	view.width = base.width
	view.height = base.height
	view._cells = base.cells_flat().duplicate()
	view.furniture_turn = base.furniture_turn
	view.floor_look = base.floor_look
	view.wall_accent = base.wall_accent
	view.map_decals = base.map_decals
	view.map_items = base.map_items.duplicate()
	for item: Array in _hold_visual.get("map_items", []):
		if cells.has(SmallItems.cell_of(item)) and not view.map_items.has(item):
			view.map_items.append(item)
	view.light_tint = base.light_tint
	view.door_look = base.door_look
	for c: Vector2i in cells:
		if not base.in_bounds(c) or (fog_on and not visible.has(c)): continue
		var snapshot: Dictionary = cells[c]
		var cell := GridCell.new(c)
		cell.apply_image(snapshot.get("image", base.cell(c).image()))
		view._cells[c.y * view.width + c.x] = cell
	GridCell.logs_restore(logs)
	_held_grid = view
	_held_grid_key = key
	_held_visible_source = visible
	return view
func _cell_on_screen(x: int, y: int) -> bool:
	return x >= _cull_x0 and x <= _cull_x1 and y >= _cull_y0 and y <= _cull_y1
func _sync_time_tint(tint: Color) -> void:
	if tint == Color.WHITE:
		if is_instance_valid(_time_mod):
			_time_mod.queue_free()
		_time_mod = null
		return
	if not is_instance_valid(_time_mod):
		_time_mod = CanvasModulate.new()
		add_child(_time_mod)
	_time_mod.color = tint

func _sync_lighting() -> void:
	if _tiles != null and _tiles.set_time_of_day(state.time_of_day if state != null else ""): _redraw()
	if _tiles != null and state != null and _tiles.set_winter(state.winter): _redraw()
	if _before_tiles != null and state != null and _before_tiles.set_winter(state.winter):
		if _before_layer != null: _before_layer.queue_redraw()
	if _before_tiles != null and _before_tiles.set_time_of_day(state.time_of_day if state != null else ""):
		if _before_layer != null: _before_layer.queue_redraw()
	if state != null:
		_sync_time_tint(Color.WHITE if Ui.dynamic_lighting else LightManager.flat_tint(state.env, state.time_of_day))
	# First person owns its light maps; the covered 2D map must not render another.
	if _fp != null:
		if is_instance_valid(_lighting):
			_lighting.hide()
			_lighting._vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	if not (Ui.dynamic_lighting):
		if is_instance_valid(_lighting):
			_lighting.free()
			_lighting = null
		return
	if state == null or state.grid == null: return
	if not is_instance_valid(_lighting):
		_lighting = LightManager.new()
		# Свет — поверх всех дочерних слоёв (0.12.2, item 6): слой «было» добавляется позже
		# и без этого закрывал собой темноту, из-за чего в режиме «было» ночь пропадала.
		_lighting.z_index = 2
		add_child(_lighting)
	if _before_on and _before_grid != null:
		_lighting.update_view(_before_grid, pan, zoom, ORIGIN, CELL, state.env, {}, false, null, _lod,
				-1.0, state.time_of_day)
	else:
		var view := _view_resolver()
		var limited := view.visibility_limited()
		# Под туманом тени — от доски, какой её помнит зритель (issues-12 #4): стена,
		# выросшая в темноте, не должна выдавать себя новой тенью.
		var base: Grid = _fog_mem.get(_viewing_side(), state.grid) if limited else state.grid
		var lit_grid := _terrain_before_impact(base, _visible_before_impact(_viewing_side()), limited)
		_lighting.extra_lights = drone_lights(_viewing_side(), _visible_before_impact(_viewing_side()), limited)
		_lighting.update_view(lit_grid, pan, zoom, ORIGIN, CELL, state.env,
			_visible_before_impact(_viewing_side()) if limited else {}, limited, _fx, _lod,
			-1.0, state.time_of_day)

## Drones in the air glow a little (fix-8 #12), scouts more: [cell centre, radius, energy,
## colour] for every drone this viewer can see. First person lights its board the same way.
func drone_lights(viewer: int, visible: Dictionary, limited: bool) -> Array:
	var out: Array = []
	for u: UnitInstance in state.all_units():
		if not u.is_drone or not u.is_alive() or not state.grid.in_bounds(u.coord):
			continue
		if limited and u.owner != viewer and not state.roster.are_allies(viewer, u.owner) and not visible.has(u.coord):
			continue
		var scout := MCF.is_scout(u)
		out.append([Vector2(u.coord) + Vector2(0.5, 0.5), 4.5 if scout else 2.5, 0.75 if scout else 0.4,
				Color(0.8, 0.92, 1.0)])
	return out

func _update_screen_shake() -> void:
	var age := 1.0
	for flash: Dictionary in _fx.flashes:
		age = minf(age, float(flash["t"]))
	var strength := 2.5 * maxf(0.0, 1.0 - age / 0.22)
	position = Vector2(sin(age * 143.0), cos(age * 179.0)) * strength

# --- Геометрия ---
## ЛОКАЛЬНЫЕ координаты клетки (до pan/zoom). В _draw применяется
## draw_set_transform(pan, 0, zoom), который и добавляет панораму с масштабом.
func _cell_origin(coord: Vector2i) -> Vector2:
	return ORIGIN + Vector2(coord.x * CELL, coord.y * CELL)

## ЭКРАННЫЕ координаты угла клетки (с учётом pan/zoom) — для UI-попапов на
## CanvasLayer, который не участвует в трансформе рисования.
func _cell_screen(coord: Vector2i) -> Vector2:
	return pan + zoom * _cell_origin(coord)

## Of the wall lamps on coord this unit can shoot, the one on the face nearest the mouse
## (two can face a unit standing diagonally off a corner). -1: none.
func _lamp_side_under_mouse(shooter: UnitInstance, coord: Vector2i) -> int:
	var sides := resolver.shootable_lamp_sides(shooter, coord)
	if sides.is_empty(): return -1
	var f := ((get_viewport().get_mouse_position() - pan) / zoom - ORIGIN) / CELL - Vector2(coord)
	var best := sides[0]
	for side: int in sides:
		var face := Vector2(0.5, 0.5) + Vector2(Furniture.N4[side]) * 0.5
		var best_face := Vector2(0.5, 0.5) + Vector2(Furniture.N4[best]) * 0.5
		if f.distance_to(face) < f.distance_to(best_face): best = side
	return best

func _pos_to_cell(pos: Vector2) -> Vector2i:
	var local := (pos - pan) / zoom - ORIGIN
	return Vector2i(floori(local.x / CELL), floori(local.y / CELL))

func _kill_pan_tween() -> void:
	if _pan_tween != null and _pan_tween.is_valid():
		_pan_tween.kill()
	_pan_tween = null

func _set_pan(v: Vector2) -> void:
	pan = v
	_redraw()

func _ensure_visible(coord: Vector2i) -> void:
	if _mouse_panning: return
	var view := get_viewport_rect().size
	var centre := _cell_origin(coord) + Vector2(CELL, CELL) * 0.5
	var p := pan + zoom * centre
	var margin: float = minf(CELL * zoom * 2.0, minf(view.x, view.y) * 0.25)
	if p.x >= margin and p.y >= margin and p.x <= view.x - margin and p.y <= view.y - margin:
		return
	# item 52: раньше камера прыгала (pan = ...). Теперь доводим панораму плавно тем же
	# твином, гася предыдущий, чтобы серия шагов ИИ/нейтралов не дёргала кадр рывками.
	var target := view * 0.5 - zoom * centre
	_kill_pan_tween()
	_pan_tween = create_tween()
	_pan_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_pan_tween.tween_method(_set_pan, pan, target, ENSURE_VISIBLE_TWEEN)

## Камера к войскам стороны (item 10): плавно ставит в центр экрана середину её бойцов и
## машин, зум не трогает. В командной игре на панели есть кнопка на себя и на каждого
## союзника — найти своих на большой карте одним щелчком.
func _center_on_side(side: int, instant: bool = false) -> void:
	_center_on_cell(_home_focus(side), instant)

func _center_on_cell(cell: Vector2i, instant: bool = false) -> void:
	var view := get_viewport_rect().size
	var centre := _cell_origin(cell) + Vector2(CELL, CELL) * 0.5
	_kill_pan_tween()
	if instant:
		# Начало боя: прыжком, доводить нечего — камеру ещё никто не двигал.
		_set_pan(view * 0.5 - zoom * centre)
		return
	_pan_tween = create_tween()
	_pan_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_pan_tween.tween_method(_set_pan, pan, view * 0.5 - zoom * centre, ENSURE_VISIBLE_TWEEN)

## Клетка, на которую смотрит камера «по умолчанию»: середина войск стороны на поле
## (своей, если сторона не задана), а если их не осталось — середина карты.
func _home_focus(side: int = -1) -> Vector2i:
	if side < 0:
		side = my_owner if networked else state.active_player()
	var sum := Vector2i.ZERO
	var n := 0
	if MCF.is_neutral(side):
		var targets: Array = _neutral_camera_targets().get(side, [])
		for c: Vector2i in targets: sum += c
		return Vector2i(sum.x / targets.size(), sum.y / targets.size()) if not targets.is_empty() else Vector2i(state.grid.width / 2, state.grid.height / 2)
	for u in state.all_units():
		if u.owner == side and u.is_on_field() and _on_board(u):
			sum += u.coord
			n += 1
	for veh: Vehicle in state.all_vehicles():
		if veh.owner == side and veh.alive():
			sum += veh.center()
			n += 1
	if n == 0:
		return Vector2i(state.grid.width / 2, state.grid.height / 2)
	return Vector2i(sum.x / n, sum.y / n)

## Масштабирование вокруг точки экрана (клетка под курсором остаётся на месте).
func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	_kill_pan_tween()
	var new_zoom: float = clampf(zoom * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(new_zoom, zoom):
		return
	var local := (screen_pos - pan) / zoom
	zoom = new_zoom
	pan = screen_pos - local * zoom
	_redraw()

func _viewing_side() -> int:
	if _spectator: return _spectator_side
	if state == null:
		return MCF.Owner.PLAYER_1
	if networked:
		return my_owner
	var active := state.active_player()
	var c: PlayerController = controllers.get(active)
	if c != null and c.is_local_human():
		_last_viewer = active
		return active
	if _last_viewer != -1:
		return _last_viewer
	for side: int in state.roster.player_ids():
		var h: PlayerController = controllers.get(side)
		if h != null and h.is_local_human():
			return side
	return active

func _build_ground() -> void:
	if state == null:
		return
	if state.env not in ["field", "town", "bunker"] \
			and state.grid.cells_flat().any(func(c: GridCell) -> bool: return c.is_space):
		return
	var tex := _ground_wallpaper()
	if tex == null:
		return
	_ground = GroundBackdrop.new()
	_ground.texture = tex
	_ground.z_index = -20
	add_child(_ground)
	_fit_ground()

## Клочок местности GROUND_TILES×GROUND_TILES: вариант плитки на клетку берётся хешем
## координаты — тем же приёмом, что и на самой доске, поэтому рисунок не выстраивается в
## сетку. Дополнительная плитка нужна только окружениям, где допустимы проплешины.
func _ground_wallpaper() -> ImageTexture:
	return GroundBackdrop.wallpaper(state.env, state.winter)

func _ground_floor_name() -> String:
	return GroundBackdrop._ground_floor_name(state.env)

func _ground_patch_name() -> String:
	return GroundBackdrop._ground_patch_name(state.env)

## Обои держатся за ДОСКУ, а не за экран: клочок стоит там же, где стояла бы клетка карты,
## поэтому при панораме и зуме земля едет вместе с полем, без скольжения.
func _fit_ground() -> void:
	if _ground == null:
		return
	var tile_pixels := float(_ground.texture.get_height()) / GROUND_TILES
	_ground.fit_view(pan + ORIGIN * zoom, zoom * float(CELL) / tile_pixels,
			Vector2(state.grid.width, state.grid.height) * tile_pixels,
			get_viewport_rect().size)

func _build_sky() -> void:
	if state == null or not state.grid.cells_flat().any(func(c: GridCell) -> bool: return c.is_space):
		return
	var layer := CanvasLayer.new()
	layer.layer = -10
	add_child(layer)
	_sky = Starfield.new()
	_sky.drift = false   # за доской фон ведёт камера, а не время: бой — не заставка
	layer.add_child(_sky)

func _center_on_cells(cells: Array) -> void:
	var sum := Vector2i.ZERO
	for c: Vector2i in cells: sum += c
	_center_on_cell(Vector2i(sum.x / cells.size(), sum.y / cells.size()))

func _cell_seen_now(c: Vector2i, seen: Dictionary) -> bool:
	return not _view_resolver().visibility_limited() or seen.has(c)


func _ground_image(name: String) -> Image:
	return GroundBackdrop._ground_image(name)

func _view_resolver() -> GameActionResolver:
	if not _walk_cells.is_empty():
		if _walking_view == null or _walking_view.state != state:
			_walking_view = GameActionResolver.new(state)
			_walking_view.track_undo_history = false
		_walking_view.explored = resolver.explored
		_walking_view.fog_mode = (MCF.Fog.STANDARD if _spectator_fog else MCF.Fog.OFF) if _spectator else resolver.fog_mode
		_walking_view.set_sight_positions(_walk_cells)
		return _walking_view
	if _walking_view != null and not _walking_view.sight_positions.is_empty():
		# Keep the incremental counters and sight caches between actions. Recreating
		# this resolver made the first frame of every walk merge the whole army's view.
		_walking_view.set_sight_positions({})
		# The memory renderer must compare the final simulation view with the last
		# walking frame, not with its own pre-animation incremental journal.
		resolver._vis_log.clear()
	if not _spectator and not _reveal_board: return resolver
	if _spectator_view == null or _spectator_view.state != state:
		_spectator_view = GameActionResolver.new(state)
	_spectator_view.fog_mode = MCF.Fog.STANDARD if _spectator_fog and not _reveal_board else MCF.Fog.OFF
	return _spectator_view

func _sync_camera_layers() -> void:
	for layer in [_lod, _before_layer, _audio]:
		if layer != null:
			layer.position = pan
			layer.scale = Vector2(zoom, zoom)
	_redraw()
