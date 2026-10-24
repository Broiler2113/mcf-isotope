# SVAROG tank

The game uses the supplied [SVAROG OBJ](https://drive.google.com/file/d/1cFGlsMM39dlDdNs1Q_w2slcJLxMw2KGZ/view)
and [512×512 colour texture](https://drive.google.com/file/d/12cAEL0pB8Qma4FRMmwRVlrOuqhYRjehU/view).
`source/SVAROG.obj` is unchanged. `source/albedo.jpg` is the supplied JPEG, renamed
locally. The linked MTL was inaccessible, so `source/SVAROG.mtl` binds the supplied
texture to the original material name. No texture was invented or generated.

`tools/art/build_tank_meshes.py` preserves the OBJ's UV coordinates, normals and
proportions, turns its +Z nose to the game's +X axis, puts the track base on the
floor, and scales it uniformly to 3.6 metres long and about 2.59 metres wide, about
25% larger than the 0.14.2 model. It slightly overhangs the unchanged 3×3 gameplay
footprint. It separates the original turret, mantlet and barrel at their original
pivot. `TeamStripe` marks the upper hull and turret; the shader limits faction
color to a narrow stripe on their upward-facing surfaces. All other armor,
tracks and barrel surfaces retain the supplied texture. The geometry is shared
across teams, with cached stripe materials. Wrecks use a dark neutral material.

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
angles have separate tank, wreck and stripe-mask frames. The 3.84 metre view includes
transparent padding for the barrel when it points backward. The sprite is drawn
at that same scale, preserving the hull's slight visual overhang. The runtime caches
stripes per colour and frame and draws them with nearest filtering in both battle
and purchase/placement, without a faction-colored bounding rectangle. Existing
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
