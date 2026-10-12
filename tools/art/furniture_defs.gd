extends SceneTree
## Prints the furniture table as JSON for tools/art/build_furniture.py.
func _initialize() -> void:
	var out := []
	for id: String in Furniture.ids():
		var t: Color = Furniture.tint_of(id)
		out.append({"id": id, "base": Furniture.base_of(id), "tint": t.to_html(false) if t.a > 0 else "",
				"join": str(Furniture.DEFS[id].get("join", "")), "sizes": Furniture.sizes_of(id)})
	print("@@" + JSON.stringify(out))
	quit()
