@abstract
extends "res://scenes/main/MainBoardView.gd"

## The board as each viewer remembers it under fog, and the far-view textures.

func _board_memory(viewer: int, visible: Dictionary, vis_changed: Variant) -> Grid:
	var grid := state.grid
	var fresh := not _fog_mem.has(viewer) or _fog_mem_grid != grid   # cloned below: already the live board
	if _fog_mem_grid != grid:
		_fog_mem = {}
		_fog_mem_grid = grid
		_fog_mem_viewer = -999
		_fog_mem_dmg = {}
		_fog_mem_fx = {}
		_fog_mem_corpses = {}
		for side: int in state.roster.player_ids():
			var pc: PlayerController = controllers.get(side)
			if side == viewer or (pc != null and pc.is_local_human()):
				_fog_mem[side] = _clone_board(grid)
				_fog_mem_dmg[side] = _fx.floor_damage.duplicate()
				_fog_mem_fx[side] = DecalMemory.new(_fx)
				_fog_mem_corpses[side] = _corpse_map()
	var mem: Grid = _fog_mem.get(viewer)
	if mem == null:
		mem = _clone_board(grid)
		_fog_mem[viewer] = mem
		_fog_mem_dmg[viewer] = _fx.floor_damage.duplicate()
		_fog_mem_fx[viewer] = DecalMemory.new(_fx)
		_fog_mem_corpses[viewer] = _corpse_map()
	var dmg: Dictionary = _fog_mem_dmg[viewer]
	var dmg_all := viewer != _fog_mem_viewer or vis_changed == null \
			or _fog_mem_dmg_seen != _fx.damage_version
	var dmg_cells: Variant = [] if fresh else (visible if dmg_all else vis_changed)
	for k: Variant in dmg_cells:
		var dc: Vector2i = k if k is Vector2i else Vector2i(int(k) % grid.width, int(k) / grid.width)
		if not visible.has(dc):
			continue
		var live: Variant = _fx.floor_damage.get(dc)
		if live == null:
			if dmg.erase(dc):
				_fog_mem_dmg_ver += 1
		elif dmg.get(dc) != live:
			dmg[dc] = live
			_fog_mem_dmg_ver += 1
	if viewer != _fog_mem_viewer:
		_fog_mem_dmg_ver += 1
	_fog_mem_dmg_seen = _fx.damage_version
	var journaling := GridCell.journaling
	GridCell.journaling = false
	# Журнал вида копия пишет (по нему плитки перерисуют её клетки), а журналы обзора,
	# проходимости и объектов — нет (fix-7 #4): сеттеры клеток копии отмечали их на тех же
	# координатах, и настоящая доска выбрасывала кеш обзора всей армии. Танк, проломивший
	# стену на виду у ста пятидесяти бойцов, пересчитывал их обзор дважды.
	var keep := [GridCell.vision_version, GridCell.vision_changes.duplicate(), GridCell.vision_log_base,
			GridCell.walk_version, GridCell.feature_version]
	if fresh:
		pass
	elif viewer != _fog_mem_viewer or vis_changed == null or _fog_mem_look < GridCell.look_log_base:
		for c: Vector2i in visible:
			_copy_look(mem.cell_fast(c.x, c.y), grid.cell_fast(c.x, c.y))
	else:
		var ch := GridCell.look_changes
		var i: int = (_fog_mem_look - GridCell.look_log_base) * 2
		while i < ch.size():
			var c := Vector2i(ch[i], ch[i + 1])
			if visible.has(c):
				_copy_look(mem.cell_fast(c.x, c.y), grid.cell_fast(c.x, c.y))
			i += 2
		for k: int in vis_changed:
			var c := Vector2i(k % grid.width, k / grid.width)
			if visible.has(c):
				_copy_look(mem.cell_fast(c.x, c.y), grid.cell_fast(c.x, c.y))
	GridCell.journaling = journaling
	GridCell.vision_version = keep[0]
	GridCell.vision_changes = keep[1]
	GridCell.vision_log_base = keep[2]
	GridCell.walk_version = keep[3]
	GridCell.feature_version = keep[4]
	_fog_mem_viewer = viewer
	# Свои же записи в копию журнал тоже отметил — их пропускаем, а плитки по ним
	# перерисуют клетки копии.
	_fog_mem_look = GridCell.look_version
	return mem

## Копия доски для памяти зрителя. Grid.new объявляет журналы оборванными — их состояние
## возвращается, иначе кэши настоящей доски пересобирались бы целиком.
## ponytail: полная копия, ~0.6 с на 274×274 один раз на местного игрока; если станет
## мешать — память только из клеток, сменившихся вне обзора.
static func _clone_board(src: Grid) -> Grid:
	var logs := GridCell.logs_snapshot()
	GridCell.journaling = false
	var g := Grid.new(src.width, src.height)
	for c: GridCell in src.cells_flat():
		_copy_look(g.cell_fast(c.coord.x, c.coord.y), c)
	g.furniture_turn = src.furniture_turn
	g.floor_look = src.floor_look
	g.wall_accent = src.wall_accent
	g.map_decals = src.map_decals
	g.map_items = src.map_items
	g.light_tint = src.light_tint
	g.door_look = src.door_look
	GridCell.logs_restore(logs)
	return g

## Только то, из чего собирается вид клетки. Высота — раньше объекта (сеттер объекта
## смотрит на неё), лампы — последними (высота и объект их сбрасывают).
static func _copy_look(dst: GridCell, src: GridCell) -> void:
	dst.floor_type = src.floor_type
	dst.is_space = src.is_space
	dst.cover_height = src.cover_height
	dst.feature_id = src.feature_id
	dst.feature_owner = src.feature_owner
	dst.feature_durability = src.feature_durability
	dst.dirt_level = src.dirt_level
	dst.airlock_welded = src.airlock_welded
	dst.on_fire = src.on_fire
	dst.lamps = src.lamps
	dst.items_off = src.items_off   # мелкие предметы (0.12.1): в тумане — какими их видели

## Cells (y * width + x) whose visibility differs from what the fog memories last saw.
## A logged step only touches its own cells; a jump to another view is diffed against the
## kept copy. null (re-check the whole view) only without a copy for this viewer and board.
func _track_mem_visible(viewer: int, visible: Dictionary, hidden: Variant, logged: Variant,
		jumped: bool) -> Variant:
	var gw := state.grid.width
	var key := [viewer, state.grid.get_instance_id()]
	if key != _mem_visible_key:
		_mem_visible_key = key
		_mem_visible = visible.duplicate()
		_mem_hidden = hidden
		return null
	if not jumped:
		for k: int in logged:
			var c := Vector2i(k % gw, k / gw)
			if visible.has(c): _mem_visible[c] = true
			else: _mem_visible.erase(c)
		_mem_hidden = hidden
		return logged
	var diff: Array = []
	# Both views are the whole board but for a few cells: compare those few, not the board.
	var old: Dictionary = _mem_hidden if hidden != null and _mem_hidden != null else _mem_visible
	var now: Dictionary = hidden if hidden != null and _mem_hidden != null else visible
	for c: Vector2i in old:
		if not now.has(c): diff.append(c.y * gw + c.x)
	for c: Vector2i in now:
		if not old.has(c): diff.append(c.y * gw + c.x)
	_mem_visible = visible.duplicate()
	_mem_hidden = hidden
	return diff

## Держит слой дальнего плана в согласии с доской. far — рисует ли им этот кадр. Слой
## заводится при первом отъезде и дальше правится и вблизи: правка стоит столько, сколько
## клеток сменилось, а новый отъезд обходится без сборки заново. Выгрузка текстур на
## видеокарту — только когда слой на экране.
func _lod_sync(far: bool, viewer: int, visible: Dictionary, fog_on: bool) -> void:
	if _lod == null:
		_lod = LodLayer.new()
		_lod.show_behind_parent = true
		_lod.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(_lod)
	var grid := state.grid
	var gw := grid.width
	var gh := grid.height
	_lod.position = pan
	_lod.scale = Vector2(zoom, zoom)
	var rect := Rect2(ORIGIN, Vector2(gw * CELL, gh * CELL))
	if _lod.rect != rect or _lod.fog_on != fog_on or _lod.far != far:
		_lod.rect = rect
		_lod.fog_on = fog_on
		_lod.far = far
		_lod.queue_redraw()
	# Под туманом рельеф и объекты рисуются с доски, какой её помнит зритель (issues-12 #4).
	var vis_changed: Variant = []
	var shown := grid
	var decals: FxDecals = _fx
	var dmem: DecalMemory = null
	if fog_on:
		var view := _view_resolver()
		vis_changed = view.take_vis_changes(viewer)
		var jumped := vis_changed == null or view != _mem_view
		_mem_view = view
		var held_seen: Dictionary = _hold_visual.get("visible", {})
		if (not held_seen.is_empty() and not is_same(held_seen, _held_fog_source)) \
				or (held_seen.is_empty() and not _held_fog_source.is_empty()):
			jumped = true
			_held_fog_source = held_seen
		vis_changed = _track_mem_visible(viewer, visible, _hidden_before_impact(viewer), vis_changed, jumped)
		var switched := viewer != _fog_mem_viewer
		shown = _board_memory(viewer, visible, vis_changed)
		# Косметика — по той же памяти (0.11.3): новый зритель сверяется целиком.
		dmem = _fog_mem_fx[viewer]
		dmem.update(_fx, visible, null if switched else vis_changed, gw)
		_fx.decal_dirty.clear()   # живой слой под туманом плиткам не отдаётся
		decals = dmem.view
	var terrain_base := shown
	shown = _terrain_before_impact(shown, visible, fog_on)
	_shown_grid = shown
	# Щебень и воронки дальнего плана — тоже из памяти зрителя: раньше отъезд показывал
	# взрывы, случившиеся в темноте (0.11.3).
	_lod_damage_src = _fog_mem_dmg.get(viewer, {}) if fog_on else _fx.floor_damage
	var dmg_ver: int = _fog_mem_dmg_ver if fog_on else _fx.damage_version
	var tiles_key: Array = [terrain_base.get_instance_id(), fog_on]
	if _tiles == null or _tiles_grid != tiles_key:
		_tiles = TerrainTiles.new(shown, state.env)
		_tiles.bake_fire = true
		_tiles.set_time_of_day(state.time_of_day)
		_tiles.furniture_look = _furniture_look
		_tiles_grid = tiles_key
		_lod.tiles = _tiles
	elif _tiles._grid != shown:
		# A presentation view changes only held cells. Preserve all unaffected cached
		# textures instead of rebuilding the visible board on each impact/vehicle step.
		_tiles._grid = shown
		var changed := _tile_hold_cells.duplicate()
		changed.merge(_hold_visual.get("cells", {}))
		for c: Vector2i in changed: _tiles._touch(c)
	_tile_hold_cells = _hold_visual.get("cells", {}).duplicate()
	if not far:
		# Ближний план: плитки рельефа кусками (TerrainTiles). Набор кусков зависит от
		# того, что на экране, поэтому слой перерисовывается вместе с кадром — это лишь
		# несколько текстур, клетки внутри них не трогаются.
		if fog_on:
			_tiles.sync(_fog_mem_dmg.get(viewer, {}), _fog_mem_dmg_ver)
		else:
			_tiles.sync(_fx.floor_damage, _fx.damage_version)
		_tiles.sync_decals(decals)
		_lod.near_cells = Rect2i(_cull_x0, _cull_y0, _cull_x1 - _cull_x0, _cull_y1 - _cull_y0) \
				.intersection(Rect2i(0, 0, gw - 1, gh - 1))
		_lod.queue_redraw()
	# Картинки дальнего плана заводятся при первом отъезде: вблизи рельеф — плитками,
	# и строить пиксельную карту большой доски заранее незачем.
	if far or _lod_terrain != null:
		# Рельеф: целиком — на новой доске или оборванном журнале; иначе только клетки, что
		# с прошлого раза записал журнал вида, и те, где сменилась копоть взрывов.
		var tkey := [shown.get_instance_id()]
		if tkey != _lod_terrain_key or _lod_terrain == null or _lod_look_ver < GridCell.look_log_base:
			_lod_terrain_key = tkey
			_lod_build_terrain()
			_lod_damage_ver = dmg_ver
			_lod_damaged = _lod_damage_src.duplicate()
			_lod.terrain = null
			_lod.features = null
		else:
			if _lod_look_ver != GridCell.look_version:
				var ch := GridCell.look_changes
				var i: int = (_lod_look_ver - GridCell.look_log_base) * 2
				while i < ch.size():
					var x := ch[i]
					var y := ch[i + 1]
					if x < gw and y < gh:
						var lc := shown.cell_fast(x, y)
						_lod_terrain.set_pixel(x, y, _lod_color(lc))
						_lod_features.set_pixel(x, y, _lod_feature_color(lc))
					i += 2
				_lod_terrain_stale = true
			if _lod_damage_ver != dmg_ver:
				# Копоть живёт в косметике, а не в клетках: перекрашиваем и прежние побитые
				# клетки (перемотка повтора её стирает), и нынешние.
				for c: Vector2i in _lod_damaged:
					if grid.in_bounds(c):
						_lod_terrain.set_pixel(c.x, c.y, _lod_color(shown.cell(c)))
				for c: Vector2i in _lod_damage_src:
					if grid.in_bounds(c):
						_lod_terrain.set_pixel(c.x, c.y, _lod_color(shown.cell(c)))
				_lod_damage_ver = dmg_ver
				_lod_damaged = _lod_damage_src.duplicate()
				_lod_terrain_stale = true
		_lod_look_ver = GridCell.look_version
		_lod_sync_decals(grid, dmem, shown)
	# Туман: целиком — при смене доски, зрителя или режима; иначе только клетки, чья
	# видимость сменилась (take_vis_changes; null — «сменилось всё»).
	if fog_on:
		var view := _view_resolver()
		var fkey := [grid.get_instance_id(), viewer, view.fog_mode]
		var changed: Variant = vis_changed
		var hidden_col := FOG_COL if view.fog_mode == MCF.Fog.STANDARD else UNKNOWN_COL
		if fkey != _lod_fog_key or _lod_fog == null or changed == null:
			_lod_fog_key = fkey
			_lod_fog = Image.create(gw, gh, false, Image.FORMAT_RGBA8)
			_lod_fog.fill(hidden_col)
			for c: Vector2i in visible:
				_lod_fog.set_pixel(c.x, c.y, Color(0, 0, 0, 0))
			_lod.fog = null
		elif not (changed as Array).is_empty():
			for i: int in changed:
				var c := Vector2i(i % gw, i / gw)
				_lod_fog.set_pixel(c.x, c.y, Color(0, 0, 0, 0) if visible.has(c) else hidden_col)
			_lod_fog_stale = true
	if far:
		if _lod.terrain == null:
			_lod.terrain = ImageTexture.create_from_image(_lod_terrain)
			_lod.features = ImageTexture.create_from_image(_lod_features)
			_lod.queue_redraw()
		elif _lod_terrain_stale:
			_lod.terrain.update(_lod_terrain)
			_lod.features.update(_lod_features)
		_lod_terrain_stale = false
	if fog_on and _lod_fog != null:
		if _lod.fog == null:
			_lod.fog = ImageTexture.create_from_image(_lod_fog)
			_lod.queue_redraw()
		elif _lod_fog_stale:
			_lod.fog.update(_lod_fog)
		_lod_fog_stale = false

## Рельеф и объекты целиком: байты RGBA по клеткам и по картинке из них. Голый пол и
## голая стена (почти вся карта) берут готовый цвет, не заходя в _lod_color().
func _lod_build_terrain() -> void:
	_lod_tex_avg = _lod_texture_averages()
	var grid := _shown_grid if _shown_grid != null else state.grid
	var bytes := PackedByteArray()
	bytes.resize(grid.width * grid.height * 4)
	var fbytes := PackedByteArray()
	fbytes.resize(grid.width * grid.height * 4)   # нули — прозрачно: объекта нет
	var plain := _lod_tex_avg.is_empty() and _lod_damage_src.is_empty()
	var floor_u := _rgba32(LOD_FLOOR)
	var wall_u := _rgba32(LOD_WALL)
	var space_u := _rgba32(LOD_SPACE)
	var grass_u := _rgba32(LOD_FLOOR.blend(GRASS_TINT))
	var k := 0
	for c: GridCell in grid.cells_flat():
		var u: int
		var h := c.cover_height
		var grass := c.floor_type == MCF.FLOOR_GRASS or (not grid.floor_look.is_empty()
				and grid.look_at(c.coord.x, c.coord.y) == MCF.Look.GRASS)
		if plain and not c.on_fire and (h == 0.0 or h >= MCF.WALL_HEIGHT):
			if h >= MCF.WALL_HEIGHT and c.feature_id != MCF.FEATURE_BOUNDARY:
				u = wall_u
			elif c.is_space:
				u = space_u
			elif grass:
				u = grass_u
			elif h >= MCF.WALL_HEIGHT:
				u = wall_u
			else:
				u = floor_u
		else:
			u = _rgba32(_lod_color(c))
		bytes.encode_u32(k, u)
		if c.feature_id != "":
			fbytes.encode_u32(k, _rgba32(_lod_feature_color(c)))
		k += 4
	_lod_terrain = Image.create_from_data(grid.width, grid.height, false, Image.FORMAT_RGBA8, bytes)
	_lod_features = Image.create_from_data(grid.width, grid.height, false, Image.FORMAT_RGBA8,
			fbytes)

## Цвет как 4 байта RGBA одним словом (little-endian: r — младший байт).
static func _rgba32(c: Color) -> int:
	return c.r8 | (c.g8 << 8) | (c.b8 << 16) | (c.a8 << 24)

## Цвет клетки на дальнем плане — то же, что рисует поклеточный проход, сведённое к одному
## пикселю: пол (или средний цвет его картинки-замены), трава, копоть, укрытие, огонь.
## Объект клетки — отдельным слоем поверх тумана (_lod_feature_color).
func _lod_color(cell: GridCell) -> Color:
	var is_wall := cell.cover_height >= MCF.WALL_HEIGHT \
			and (cell.feature_id != MCF.FEATURE_BOUNDARY or state.env == "bunker")
	var damage: int = 0
	if not _lod_damage_src.is_empty():
		damage = int(_lod_damage_src.get(cell.coord, 0))
	var look := state.grid.look_at(cell.coord.x, cell.coord.y) if not state.grid.floor_look.is_empty() else 0
	# Почти вся карта — голый пол или голая стена без картинок-замен: цвет готов.
	if damage == 0 and not cell.on_fire and _lod_tex_avg.is_empty():
		if is_wall:
			return LOD_WALL
		if cell.cover_height == 0.0 and not cell.is_space \
				and cell.floor_type != MCF.FLOOR_GRASS and look != MCF.Look.GRASS:
			return LOD_FLOOR
	var floor_name := "floor"
	if cell.is_space:
		# Космоса как плитки больше нет (0.9.3): остаются только панели, всё прочее —
		# пустое место, сквозь которое видно параллакс.
		floor_name = "floor_solar" if look == MCF.Look.SOLAR else ""
	elif is_wall:
		floor_name = "floor_wall"
	elif damage == FxDecals.DAMAGE_EPICENTER:
		floor_name = "floor_epicenter"
	elif damage == FxDecals.DAMAGE_RUBBLE:
		floor_name = "floor_destroyed"
	elif cell.floor_type == MCF.FLOOR_GRASS:
		floor_name = "floor_grass"
	elif look > 0 and look < MCF.FLOOR_LOOKS.size() and not MCF.FLOOR_OVERLAY_LOOKS.has(look):
		floor_name = MCF.FLOOR_LOOKS[look]
	var col: Color
	if _lod_tex_avg.has(floor_name):
		col = _lod_tex_avg[floor_name]
	else:
		col = LOD_FLOOR
		if cell.is_space:
			col = LOD_SPACE
		if is_wall:
			col = LOD_WALL
		if not is_wall and not cell.is_space \
				and (cell.floor_type == MCF.FLOOR_GRASS or look == MCF.Look.GRASS):
			col = col.blend(GRASS_TINT)
		if damage != 0 and not cell.is_space:
			col = col.blend(SCORCH_EPICENTER if damage == FxDecals.DAMAGE_EPICENTER
					else SCORCH_RUBBLE)
	var h := cell.cover_height
	if h > 0.0 and not is_wall and cell.feature_id != MCF.FEATURE_BOUNDARY:
		col = col.blend(_lod_tex_avg.get("floor_cover", Color(0.5, 0.45, 0.2, 0.12 + 0.12 * h)))
	if cell.on_fire:
		col = col.blend(_lod_tex_avg.get("fire", Color(1.0, 0.4, 0.05, 0.4)))
	return col

## Объект клетки на дальнем плане: пиксель слоя объектов (прозрачный — объекта нет). Мины
## сюда не входят: их видимость своя у каждой стороны, их рисует _draw.
func _lod_feature_color(cell: GridCell) -> Color:
	var fid := cell.feature_id
	# Станция дронов, как и мина, в общий слой объектов не идёт: её видно только тому, кто
	# её видит сейчас, и рисуется она поклеточно.
	if fid == "" or fid == MCF.FEATURE_MINE or fid == MCF.FEATURE_AV_MINE \
			or fid == MCF.FEATURE_DRONE_STATION:
		return Color(0, 0, 0, 0)
	# Граница мира (0.9.3): в бункере — плитка грунта, в прочих окружениях плитки нет, и
	# на дальнем плане её тоже не видно — там виден пол клетки.
	if fid == MCF.FEATURE_BOUNDARY:
		return _lod_tex_avg.get("boundary", Color(0, 0, 0, 0))
	# Станция и астероид (0.12.1): куча — лом, окоп — прорезь в палубе, и вдали тоже.
	if MCF.rubble_env(state.env):
		var art := TerrainTiles.pile_art(state.env) if fid == MCF.FEATURE_DIRT_PILE \
				else (TerrainTiles.env_name("trench", state.env) if fid == MCF.FEATURE_TRENCH else "")
		if art != "" and _lod_tex_avg.has(art):
			return _lod_tex_avg[art]
	if _lod_tex_avg.has(fid):
		return _lod_tex_avg[fid]
	if fid == MCF.FEATURE_LDF:
		return LDF_COLOR
	if MCF.is_glass(fid):
		return Color(0.55, 0.75, 0.9, 0.6)
	if fid == MCF.FEATURE_AIRLOCK:
		return Color(0.45, 0.6, 0.75, 0.55)
	return Color(0.6, 0.6, 0.7, 0.45)

func _lod_sync_decals(grid: Grid, dmem: DecalMemory = null, shown: Grid = null) -> void:
	if _lod_terrain == null:
		return
	var fresh := _lod_decal_img != _lod_terrain.get_instance_id()
	_lod_decal_img = _lod_terrain.get_instance_id()
	if dmem != null:
		# Под туманом — запомненная косметика зрителя (0.11.3). Она может и УБЫТЬ (зритель
		# увидел, что лужа сгорела), поэтому правка — кусками: клетки куска заново по
		# рельефу, и сверху то, что в куске помнится.
		var chunks: Variant = dmem.view.by_chunk if fresh else dmem.lod_dirty
		for cc: Vector2i in chunks:
			_lod_recolor_chunk(cc, grid, shown, dmem.view)
		dmem.lod_dirty.clear()
		_lod_decal_reset = -1   # к живому слою — потом с нуля
		_lod_terrain_stale = true
		return
	if fresh:
		_lod_decal_done = 0
	if _lod_decal_reset != _fx.decal_reset:
		_lod_decal_reset = _fx.decal_reset
		_lod_decal_done = 0
		_lod_build_terrain()
		_lod.terrain = null
	var total: int = _fx.gore.size() + _fx.props.size()
	if _lod_decal_done >= total:
		return
	# Jump directly to the unconsumed suffix of the same flattened gore/props
	# sequence. Visiting every older particle just to skip it made each new decal
	# increasingly expensive over a long match. Keep list and blend order exact.
	var skip := _lod_decal_done
	for list: Array in [_fx.gore, _fx.props]:
		var first := mini(skip, list.size())
		skip -= first
		var i := first
		while i < list.size():
			var p: Dictionary = list[i]
			i += 1
			var pos: Vector2 = p["pos"]
			var c := Vector2i(floori(pos.x), floori(pos.y))
			if not grid.in_bounds(c):
				continue
			var look: Array = FxDecals.look_of(str(p["kind"]))
			if look.is_empty():
				continue
			var col: Color = look[1]
			# Доля клетки, которую частица закрывает, — она же и вес подмешивания.
			var cover: float = clampf(float(look[0]) * float(p["scale"]), 0.08, 1.0) * col.a
			_lod_terrain.set_pixel(c.x, c.y, _lod_terrain.get_pixel(c.x, c.y).lerp(col, cover))
	_lod_decal_done = total
	_lod_terrain_stale = true

## Кусок дальнего плана заново: рельеф клеток куска и подмешанная поверх косметика.
func _lod_recolor_chunk(cc: Vector2i, grid: Grid, shown: Grid, fx: FxDecals) -> void:
	var c0 := cc * FxDecals.DECAL_CHUNK
	for y in range(maxi(0, c0.y), mini(grid.height, c0.y + FxDecals.DECAL_CHUNK)):
		for x in range(maxi(0, c0.x), mini(grid.width, c0.x + FxDecals.DECAL_CHUNK)):
			_lod_terrain.set_pixel(x, y, _lod_color(shown.cell_fast(x, y)))
	for p: Dictionary in fx.by_chunk.get(cc, []):
		var pos: Vector2 = p["pos"]
		var c := Vector2i(floori(pos.x), floori(pos.y))
		if not grid.in_bounds(c):
			continue
		var look: Array = FxDecals.look_of(str(p["kind"]))
		if look.is_empty():
			continue
		var col: Color = look[1]
		var cover: float = clampf(float(look[0]) * float(p["scale"]), 0.08, 1.0) * col.a
		_lod_terrain.set_pixel(c.x, c.y, _lod_terrain.get_pixel(c.x, c.y).lerp(col, cover))

## Средние цвета картинок-замен пола и объектов (#55): на дальнем плане картинка — это
## её цвет. Считается раз на сборку рельефа.
func _lod_texture_averages() -> Dictionary:
	var out := {}
	var names: Array = ["floor", "floor_space", "floor_wall", "floor_cover", "fire",
			"floor_grass", "floor_destroyed", "floor_epicenter", "boundary"]
	names.append_array(MCF.FLOOR_LOOKS.slice(1))   # полы комнат (0.9.2) — как на холсте
	names.append_array(FEATURE_TAGS.keys())
	names.append_array(Furniture.ids())   # мебель на дальнем плане — цветом своей плитки
	names.append_array(["rubble", "trench_station", "trench_asteroid"])   # 0.12.1
	for n: String in names:
		# Шлюз с 0.9.2 рисуется дверью в раме, и файл у неё — "door".
		var base: String = "door" if n == MCF.FEATURE_AIRLOCK else n
		# Окружение карты (item 24): дальний план того же цвета, что и плитки вблизи.
		var tex := Sprites.texture_of(TerrainTiles.env_name(base, state.env))
		if tex == null:
			continue
		var img := tex.get_image()
		if img == null or img.is_empty():
			continue
		if img.is_compressed():
			img.decompress()
		img.resize(1, 1, Image.INTERPOLATE_BILINEAR)
		out[n] = img.get_pixel(0, 0)
	return out

## Тела на поле сейчас: клетка -> [павший на месте или null, сколько тел]. Смерти, ещё не
## доигранные броском (#46), сюда не входят — они пока рисуются живыми. Куча (#98) и
## павший на её клетке — один стек с общим числом, без картинки павшего.
func _corpse_map() -> Dictionary:
	var out := {}
	for unit: UnitInstance in state.all_units():
		if unit.status != MCF.Status.CORPSE or _pending_death_ids.has(unit.id):
			continue
		# Раздавленный гусеницами труп вычищается из клетки (occupant = null), но сам
		# UnitInstance остаётся в списке — без этой проверки он всплывал бы призраком.
		var cell := state.grid.cell(unit.coord)
		if cell == null or cell.occupant != unit:
			continue
		out[unit.coord] = [unit, 1]
	for pc: Vector2i in _pile_cells():
		var pile := state.grid.cell(pc)
		if pile == null or pile.corpse_count <= 0:
			continue
		out[pc] = [null, pile.corpse_count + (1 if out.has(pc) else 0)]
	return out

func _pile_cells() -> Array[Vector2i]:
	var key := [state.grid.get_instance_id(), GridCell.corpse_version]
	if key != _piles_key:
		_piles_key = key
		_piles = []
		for c: GridCell in state.grid.cells_flat():
			if c.corpse_count > 0:
				_piles.append(c.coord)
	return _piles
