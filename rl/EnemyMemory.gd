extends RefCounted
## Память стороны о врагах, которых она ВИДЕЛА, но сейчас не видит (RL-тактика, партии с
## туманом). Политика без памяти забывает врага, как только тот шагнул за угол, и снова
## подставляется под него; с памятью «где его видели в последний раз и как давно» она может
## рассуждать о том, где он сейчас.
##
## Только то, что сторона честно видела: запись делается из видимых врагов в точках решения
## этой стороны. Увиденный мёртвым или снова видимый — из памяти уходит (его покажет само
## наблюдение). Один экземпляр на сторону: env_server держит по одному на каждую, боевой
## LearnedController — свой, и пишут они одинаково.

## id врага -> [клетка, раунд, когда видели]
var seen: Dictionary = {}

func reset() -> void:
	seen.clear()

## Запомнить видимых сейчас врагов и забыть погибших.
func observe(r: GameActionResolver, side: int) -> void:
	var state := r.state
	for id: Variant in seen.keys():
		var u := state.get_unit(int(id))
		if u == null or not u.is_alive():
			seen.erase(id)
	for u: UnitInstance in state.all_units():
		if not u.is_alive() or u.is_drone or MCF.is_neutral(u.owner) \
				or state.roster.are_allies(side, u.owner) or not state.grid.in_bounds(u.coord):
			continue
		if r.is_visible_to_team(side, u):
			seen[u.id] = [u.coord, state.turns.round_number]

## Слой для наблюдения: на клетке, где невидимого сейчас врага видели последним, —
## 100 / (1 + сколько раундов назад); видимые враги слоя не дают (они и так в наблюдении).
func layer(r: GameActionResolver, side: int) -> PackedInt32Array:
	var state := r.state
	var w := state.grid.width
	var out := PackedInt32Array()
	out.resize(w * state.grid.height)
	var now := state.turns.round_number
	for id: Variant in seen:
		var u := state.get_unit(int(id))
		if u != null and u.is_alive() and state.grid.in_bounds(u.coord) and r.is_visible_to_team(side, u):
			continue
		var c: Vector2i = seen[id][0]
		var i := c.y * w + c.x
		out[i] = maxi(out[i], int(100.0 / (1.0 + float(now - int(seen[id][1])))))
	return out
