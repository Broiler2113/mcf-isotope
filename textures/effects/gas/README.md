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
Final source: `textures/effects/gas/gas.png`. Edit prompt:

> Edit this gas texture for a top-down pixel-art tactics game. Preserve its seamless cloudy density pattern and transparent wisps, but change the entire palette to white and neutral light gray only, with no green/yellow. Render much chunkier visible square pixels, roughly a 64-by-64 logical pixel grid enlarged cleanly, a restrained four-tone white/gray palette with varied transparency. Flat top-down smoke texture filling the square, no lighting perspective, no objects, no text, no border. This is a repeating terrain overlay, not a cloud icon. Keep alpha transparency in the gaps. Crisp nearest-neighbor pixel edges, no blur or photographic grain.
