# Isotope 0.9.7.1

- Field and town maps have cosmetic grass beyond the board, including maps containing space tiles. The grass follows camera movement, zoom and window resizing. It adds no playable cells: infantry and vehicles cannot enter it. Intentional space inside the board keeps its stars.
- Gas uses a new connected smoke texture with soft outer edges. Walls, windows, armored glass, soil and vacuum stay clear, and overlapping clouds no longer darken the same tile twice.
- Gas blocks line of sight into, out of and through a cloud. Both cached fog visibility and direct LOS checks agree, and aimed fire cannot bypass gas through special weapons or by disabling fog. Visibility recovers as gas dissipates.
- Building or destroying terrain inside a cloud updates its gas coverage immediately; save/load reconstructs the same footprint.

The grass backdrop uses one repeating texture and at most four visible rectangles, with no per-tile background loop. The gas atlas is prebuilt, uses 1 MiB of RGBA texture data, and is drawn only for visible gas cells. Existing movement and simulation grid sizes are unchanged.

Texture source, generation prompt and replacement instructions: [gas texture notes](textures/effects/gas/README.md).
