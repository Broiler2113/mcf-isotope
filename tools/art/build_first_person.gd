extends SceneTree

## Bake the exact procedural material/ground images so entering 3D does no pixel loops.
## godot --headless --script res://tools/art/build_first_person.gd
## -- --verify checks the shipped pixels against the generators without changing files.
func _initialize() -> void:
	var verify := OS.get_cmdline_user_args().has("--verify")
	var folder := "res://textures/first_person"
	if not verify: DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var errors := 0
	var groups := {"material": FirstPersonArt.material_images(), "ground": FirstPersonArt.ground_images()}
	for prefix: String in groups:
		var images: Array = groups[prefix]
		for i in images.size():
			var expected: Image = images[i]
			expected.clear_mipmaps()
			var path := "%s/%s_%02d.png" % [folder, prefix, i]
			if verify:
				var actual := Image.load_from_file(ProjectSettings.globalize_path(path))
				if actual == null or actual.get_data() != expected.get_data():
					printerr("Baked texture differs: " + path)
					errors += 1
			elif expected.save_png(path) != OK:
				printerr("Cannot write " + path)
				errors += 1
	print("First-person texture %s: %d images, %d errors" % ["verification" if verify else "bake", FirstPersonArt.M_COUNT + FirstPersonArt.G_COUNT, errors])
	quit(1 if errors else 0)
