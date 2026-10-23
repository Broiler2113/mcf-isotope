# Isotope 0.13.5.1

## Battlefield labels

- Tile coordinates appear on every cell, including when the whole map is visible. Zooming out no longer skips rows or columns of labels.
- Unit, corpse, and vehicle IDs stay within their own cells. All labels shrink with their tiles when zooming out and remain capped at their normal text size when zooming in.
- Long IDs fit within the cell, and IDs sharing a tile stack separately from its coordinate label.
- Coordinate drawing is retained between camera changes to avoid rebuilding thousands of labels each frame.
- Automatic rendered checks cover the full zoom range, a 160×120 map, stacked corpses, vehicle IDs, panning, and cheat permissions.

**Compatibility:** network protocol **29** and replay schema **3**, unchanged from 0.13.5. Existing saves and replays remain supported.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.13.5...v0.13.5.1
