extends "res://tests/SuiteBase.gd"
## Digging: rubble through a station deck, spoil never on a body, smoke marks.

func run() -> void:
	GameConfig.civilians_enabled = false
	GameConfig.random_events_enabled = false
	_rubble()

	digging_and_smoke_mark()

## On station and asteroid maps digging goes through the deck: the pile is drawn as rubble
## and called "Rubble Pile", the trench has its metal look, the log says rubble; other maps
## keep dirt.
func _rubble() -> void:
	var tt: GDScript = load("res://src/ui/TerrainTiles.gd")
	ck(tt.pile_art("station") == "rubble" and tt.pile_art("asteroid") == "rubble" and tt.pile_art("town") == "soil"
			and tt.pile_art("bunker") == "soil", "station and asteroid piles use the rubble art, other maps dirt")
	ck(tt.env_name("trench", "station") == "trench_station" and tt.env_name("trench", "asteroid") == "trench_asteroid"
			and tt.env_name("trench", "field") == "trench", "station and asteroid trenches are cut into metal")
	for env in ["station", "town"]:
		var m := MapData.blank_arena(12, 8)
		m.env = env
		m.set_spawn(Vector2i(3, 3), "engineer", 0)
		m.set_spawn(Vector2i(11, 7), "light_infantry", 1)
		var st := m.build_state(2)
		st.turns.round_order = [0, 1]
		st.turns.active_index = 0
		var r := GameActionResolver.new(st)
		var name := MCF.feature_name(MCF.FEATURE_DIRT_PILE)
		var eng: UnitInstance = st.grid.cell(Vector2i(3, 3)).occupant
		var res := r.resolve(DigIntent.new(eng.id, Vector2i(4, 3)))
		var log := " ".join(res.log_lines)
		if env == "station":
			ck(name == "Rubble Pile" and res.ok and log.contains("rubble at"), "on a station the pile is a Rubble Pile (%s)" % log)
		else:
			ck(name == "Dirt Pile" and res.ok and log.contains("dirt at"), "elsewhere it stays a Dirt Pile (%s)" % log)

func arena(w := 24, h := 16) -> MapData:
	GameConfig.civilians_enabled = false
	GameConfig.game_mode = MatchMode.Kind.ANNIHILATION
	return MapData.blank_arena(w, h)

func resolver_for(map: MapData, seed := 7) -> GameActionResolver:
	var r := GameActionResolver.new(map.build_state(seed))
	r.fog_enabled = false
	return r

func digging_and_smoke_mark() -> void:
	var map := arena()
	map.set_spawn(Vector2i(4, 4), "heavy_infantry", 0)
	map.set_spawn(Vector2i(20, 12), "light_infantry", 1)
	var r := resolver_for(map)
	var cell := r.state.grid.cell(Vector2i(6, 6))
	ck(cell.accepts_dirt(), "open floor takes spoil")
	cell.corpse_count = 1
	ck(not cell.accepts_dirt(), "no dirt pile on a body")
	cell.corpse_count = 0
	var hi: UnitInstance = r.state.grid.cell(Vector2i(4, 4)).occupant
	ck(not r.unit_missing_equipment(hi), "heavy infantry holding its smoke shows no mark")
	hi.held_item_id = ""
	ck(r.unit_missing_equipment(hi), "heavy infantry that threw its smoke gets the '!' mark")
