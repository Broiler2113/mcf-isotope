# Isotope 0.13.5.2

## Battlefield labels

- Tile coordinates appear on every cell, including when the whole map is visible. Zooming out no longer skips rows or columns of labels.
- Unit, corpse, and vehicle IDs stay within their own cells. All labels shrink with their tiles when zooming out and remain capped at their normal text size when zooming in.
- Long IDs fit within the cell, and IDs sharing a tile stack separately from its coordinate label.
- Coordinate drawing is retained between camera changes to avoid rebuilding thousands of labels each frame.
- Automatic rendered checks cover the full zoom range, a 160×120 map, stacked corpses, vehicle IDs, panning, and cheat permissions.

## First-person view

- The default render distance is now 160 m, including when restoring defaults. Existing saved preferences are preserved.
- Unexplored areas are covered by dense, opaque, textured fog. Terrain and units cannot be seen through it, including while flying. The texture stays steady during visibility updates.
- Terrain meshes and floor textures prepare incrementally across frames, reducing long pauses at maximum render distance. Completed terrain stays visible until its replacement is ready.
- Fire, gas, smoke, and editor features use cached indexes instead of repeated full-map scans. Unchanged effect geometry is reused.
- The covered 2D battlefield and its light map stop rendering while first person is open, and return when leaving it.
- Floor textures retain their detail and now include mipmaps for steadier distant surfaces. Ground tracks bake faster with identical pixels.

## Outdoor time command

- Added `time morning`, `time day`, `time evening`, and `time night` for outdoor maps, with command hints and manual documentation. Changes update the sky and lighting in both views, synchronize in multiplayer, and persist in saves. The existing `world time` command remains supported.

## Validation

- Rendered tests verify opaque fog at walking height and above/below the map, stable visibility updates, and labels staying inside their cells throughout the zoom range.
- Regression tests cover interrupted terrain construction, live changes during preparation, exact floor pixels, effects, and entering/leaving first person.

**Compatibility:** network protocol **29** and replay schema **3**, unchanged from 0.13.5. Existing saves and replays remain supported.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.13.5.1...v0.13.5.2
