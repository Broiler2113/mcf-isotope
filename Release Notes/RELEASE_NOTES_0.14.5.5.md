# Isotope 0.14.5.5

## Smoother zoomed-out battles

- Soldiers, bodies, selection rings, group badges and markers are now drawn as one batch instead of one at a time. A giant battle fitted to the screen goes from about 640 draw calls a frame to about 220.
- Flying debris and particles only redraw their own layer, not the whole board, so debris drifting off into space no longer slows the game down.
- New blood and spent brass are painted onto the existing floor picture instead of rebuilding that part of the map.
- Seeing through gas and smoke is worked out once per soldier instead of once per gas cloud cell, which removes long stalls on big maps full of smoke.

## Dynamic lighting

- Lamps are drawn once and remembered. Flickering fire, explosion flashes and muzzle flashes are added on top, so they no longer redraw every lamp on the screen. A big battle with 30 fires runs about three times faster with dynamic lighting on.
- The lighting looks exactly the same as before.

## Compatibility

- Only drawing changed: soldiers, civilians and the AI make exactly the same moves as before.
- Network protocol **33** and replay schema **3** are unchanged: 0.14.5 through 0.14.5.5 play together, and saves and replays carry over.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14.5.4...v0.14.5.5
