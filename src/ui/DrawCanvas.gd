class_name DrawCanvas
extends RefCounted

## Растровый слой рисунков на поле (batch «team session», item 15): рисование и ластик как
## в Paint — кисть ставит пиксели, ластик их стирает, и стёртое исчезает ровно там, где
## прошёл ластик, а не целым штрихом.
##
## Раньше рисунок хранился ломаными по точкам и КАЖДЫЙ кадр собирался заново: на каждую
## точку каждого штриха — шаг цикла и кусок геометрии толстой линии. За партию трое
## игроков накидывали тысячи точек, и это было заметной долей кадра. Здесь холст —
## разреженные куски-картинки TILE×TILE: куски заводятся только там, где рисовали, и
## выводятся готовыми текстурами, сколько бы ни нарисовали.
##
## Координаты — «пространство отрисовки поля» Main (_draw_world_pos), холст хранит их с
## масштабом SCALE (пиксель в пиксель: кромка кисти ровная; куски заводятся только там,
## где рисовали, так что память тратится лишь на нарисованное).

const TILE := 256
const SCALE := 1.0

var _tiles: Dictionary = {}   # Vector2i -> {"img": Image, "tex": ImageTexture, "dirty": bool}

func is_empty() -> bool:
	return _tiles.is_empty()

func clear() -> void:
	_tiles.clear()

## Провести кистью от a до b радиусом radius (пиксели поля). color.a == 0 — ластик.
func stroke(a: Vector2, b: Vector2, radius: float, color: Color) -> void:
	var r := maxf(1.0, radius * SCALE)
	var pa := a * SCALE
	var pb := b * SCALE
	var dist := pa.distance_to(pb)
	var steps := maxi(1, int(ceil(dist / maxf(1.0, r * 0.5))))
	for i in steps + 1:
		_stamp(pa.lerp(pb, float(i) / steps), r, color)

## Круг кисти: построчно — по отрезку fill_rect на строку, отрезок режется по кускам.
func _stamp(c: Vector2, r: float, color: Color) -> void:
	var erase := color.a <= 0.0
	var ri := int(ceil(r))
	for dy in range(-ri, ri + 1):
		var half := sqrt(maxf(0.0, r * r - float(dy * dy)))
		if half <= 0.0 and dy != 0:
			continue
		var y := int(floor(c.y)) + dy
		var x0 := int(floor(c.x - half))
		var x1 := int(floor(c.x + half))
		var ty := floori(float(y) / TILE)
		var tx := floori(float(x0) / TILE)
		while tx * TILE <= x1:
			var key := Vector2i(tx, ty)
			var t: Dictionary = _tiles.get(key, {})
			if t.is_empty():
				if erase:
					tx += 1
					continue
				t = {"img": Image.create(TILE, TILE, false, Image.FORMAT_RGBA8), "tex": null, "dirty": true}
				_tiles[key] = t
			var lx0 := maxi(x0, tx * TILE) - tx * TILE
			var lx1 := mini(x1, tx * TILE + TILE - 1) - tx * TILE
			(t["img"] as Image).fill_rect(Rect2i(lx0, y - ty * TILE, lx1 - lx0 + 1, 1), color)
			t["dirty"] = true
			tx += 1

## Вывести холст. view — видимая область в пространстве поля (лишнее не рисуем).
func draw(ci: CanvasItem, view: Rect2) -> void:
	for key: Vector2i in _tiles:
		var rect := Rect2(Vector2(key) * TILE / SCALE, Vector2(TILE, TILE) / SCALE)
		if not rect.intersects(view):
			continue
		var t: Dictionary = _tiles[key]
		if t["tex"] == null:
			t["tex"] = ImageTexture.create_from_image(t["img"])
		elif t["dirty"]:
			(t["tex"] as ImageTexture).update(t["img"])
		t["dirty"] = false
		ci.draw_texture_rect(t["tex"], rect, false)
