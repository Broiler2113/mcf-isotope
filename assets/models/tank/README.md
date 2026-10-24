# SVAROG tank

The game uses the supplied [SVAROG OBJ](https://drive.google.com/file/d/1cFGlsMM39dlDdNs1Q_w2slcJLxMw2KGZ/view)
and [512×512 colour texture](https://drive.google.com/file/d/12cAEL0pB8Qma4FRMmwRVlrOuqhYRjehU/view).
`source/SVAROG.obj` is unchanged. `source/albedo.jpg` is the supplied JPEG, renamed
locally. The linked MTL was inaccessible, so `source/SVAROG.mtl` binds the supplied
texture to the original material name. No texture was invented or generated.

`tools/art/build_tank_meshes.py` preserves the OBJ's UV coordinates, normals and
proportions, turns its +Z nose to the game's +X axis, puts the track base on the
floor, and fits it within the tank's existing 3×3 metre footprint. It separates the
original turret, mantlet and barrel at their original pivot. `TeamPaint` marks
armour; the track surfaces retain their original colours. The geometry is shared
across teams, with cached materials for their roster colours. Wrecks use a dark
neutral material.

Rebuild after replacing the source model or colour texture:

```sh
python3 tools/art/build_tank_meshes.py
godot --headless --editor --path . --import
xvfb-run -a godot --path . --rendering-method gl_compatibility --script res://tools/art/build_tank_sprites.gd
godot --headless --editor --path . --import
```

The sprite baker needs a graphics display; omit `xvfb-run -a` on a desktop.
`TankModel` assembles the same imported hull and turret for the baker and first
person. Each baked image is exactly **96×96**, orthographic from directly above,
with a transparent background and the nose pointing up. Eight relative turret
angles have separate tank, wreck and paint-mask frames. The runtime caches team
paint per colour and frame and draws it with nearest filtering. Existing
`user://textures/tank.png` and `tank_wreck.png` replacements still take priority.

Verification:

```sh
godot --headless --path . --script res://tests/ui/run_tank_visuals.gd
xvfb-run -a godot --path . --rendering-method gl_compatibility --script res://tests/render_tank_model.gd
```

The rendered check writes `/tmp/isotope-tank-2d.png` and
`/tmp/isotope-tank-first-person.png` for inspection. The headless check also
covers RMB panning at minimum zoom while camera recentering is active, and a
button release consumed by the HUD.
