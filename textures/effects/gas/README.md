# Gas texture

`gas.png` is the smoke source. `gas_autotile.png` is the shipped, prebuilt sheet:
16 connectivity masks in each 4×4 block, with 64 spatial variants stacked vertically.
Each tile is 16×16 pixels; the full sheet is 64×4096 (1 MiB RGBA). `sample.png`
shows the same layout. It is excluded from the texture loader.

Masks use N=1, E=2, S=4, W=8. Connected edges remain full; exposed edges fade.
The source spans four cells per axis and is mirrored across the next four, so cloud
interiors join without a separate outlined puff in every cell. Only actual gas
cells connect: walls, windows, soil and vacuum interrupt the cloud.

Rebuild after changing the source with:

```sh
godot --headless --script res://tools/gen_gas_atlas.gd
```

Keep `process/fix_alpha_border=false` on the atlas import: propagating hidden RGB
between atlas tiles can alter matching edges. Source import is limited to 128×128.
No pixel processing is performed for the shipped atlas during play. A player's
`user://textures/gas_autotile.png` takes priority. A custom `gas.png` without a custom
atlas uses a cached automatic bake; legacy horizontal strips use the first tile.

## Source generation

The white smoke source was edited with the built-in image-generation tool, using
this game's previous gas texture as its reference and preserving transparency.
`GasTiles.bake` uses nearest-neighbor sampling for the pixelated atlas; the battle
renderer uses a nearest-filtered CanvasTexture without changing unit rendering.
Final source: `textures/effects/gas/gas.png`. The uniform-density revision uses this prompt:

> Edit this existing game gas texture. Make the density MUCH MORE UNIFORM across the entire square: fill the large transparent holes with the same semi-transparent white fog and reduce bright-white versus gray contrast. A continuous even sheet of white/light gray mist, with subtle small pixel clusters only. Keep crisp chunky square pixels at roughly 64x64 logical resolution, top-down flat 2D strategy game art. Restrained two or three close white/light-gray tones, low-contrast mottling, evenly semi-transparent alpha throughout. No separate cloud puffs, no dark gray regions, no swirls, no outlines, no shadows, no large empty holes. Fill all four edges evenly for a repeating tile. Preserve transparency as a light translucent overlay; no opaque background. No text, frame, icon, or objects.
