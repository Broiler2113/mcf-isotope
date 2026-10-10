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

The smoke source was created with the built-in image generation tool. The production
atlas is assembled deterministically by `GasTiles.bake`, which scales and masks that
source. Prompt:

> Use case: stylized-concept. Asset type: production seamless square game texture for a top-down pixel-art tactical game, poisonous gas cloud interior. Generate a square texture consisting entirely of softly swirling muted olive-green and pale yellow-green translucent smoky vapor, seen directly from above. Seamlessly tileable in both axes: all opposite edges must match, with evenly distributed density and no central subject. Broad gentle curling wisps and cloudy bands, subtle dithered pixel-art shading, small restrained 1990s strategy-game palette. Flat top-down, no 3D cloud horizon, no objects, no text, no symbols, no borders, no grid, no isolated circular puff, no holes shaped like branches, no black outlines. This fills connected gas regions; code will soften only the outer perimeter of the cloud. Keep medium-to-low contrast so soldiers remain legible beneath it. Transparent background with genuinely translucent smoke throughout the square, vapor extending through all four image edges. One texture only, no sprite sheet, no presentation mockup.
