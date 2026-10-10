extends SceneTree

## Rebuild the shipped autotile sheet after replacing textures/effects/gas/gas.png.
func _initialize() -> void:
	Sprites.reload_overrides()
	var atlas := GasTiles.bake(Sprites.texture_of("gas"))
	if atlas == null:
		quit(1)
		return
	var img := atlas.get_image()
	var err := img.save_png("res://textures/effects/gas/gas_autotile.png")
	if err == OK:
		err = img.save_png("res://textures/effects/gas/sample.png")
	print("gas atlas: ", img.get_size(), " error=", err)
	quit(0 if err == OK else 1)
