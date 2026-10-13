# Isotope 0.9.8.1

## Gas and random events

- Gas uses white, pixelated artwork and blocks line of sight even with fog of war turned off. Enemies inside gas stay hidden; your own units remain visible.
- Units roll for survival on the first gas tile they enter, including when passing through a cloud or leaving a vehicle. Units caught by a newly arriving cloud roll immediately.
- Random-event warnings last one player turn: the event happens after the next player ends their turn, rather than waiting for a full round.
- Multiple pending artillery barrages no longer overlap.
- Fixed missing event dice animations and casualty results during neutral turn processing.

## Maps and editor

- Town roads continue through the ten-tile outer border, with grass beside them.
- Renamed **Stamps** to **Presets** and combined built-in structures and saved presets in the same list.
- Blood and other ground decals place freely between tiles, with a continuously moving preview. Corpses snap to tile centers and render smoothly.
- Press **R** to rotate a decal before placing it.
- Wall accents appear only for wall brushes. Door texture controls appear only for door brushes and show the selected texture.
- Fixed decal painting continuing after releasing the mouse over the editor interface.

Multiplayer participants must all update to 0.9.8.1 because gas checks and event timing change the shared simulation. Existing saves remain readable; pending event warnings use the new one-turn timing.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.9.8...v0.9.8.1
