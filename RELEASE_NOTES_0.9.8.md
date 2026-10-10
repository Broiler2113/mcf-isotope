# Isotope 0.9.8

## Gameplay and presentation

- Armed neutrals prefer an available shot over moving or collecting bodies. When repositioning to fire, they keep enough AP for the shot.
- Service tunnels on station and bunker maps are one tile wide. Connections to main corridors are separated by airlocks or walls; furnished technical rooms keep their normal size.
- Fixed units snapping between positions during consecutive replay movement animations.
- Explosions, including artillery impacts, produce a slight screen shake.
- Fog of war stays crisp when zoomed out. Moving vehicles have translucent hulls and destination previews.
- Clicking a visible drone station shows its operating radius. Prev/Next follows the current turn, including neutral groups.
- Dirt piles use connected soil-wall artwork and retain their height labels. Walls cover ground decals and vehicle tracks built beneath them.
- Welded doors use steel braces without the orange blocks. Wide airlocks use a consistent sprite variant across the whole opening.
- Defense rolls that require more than 6 animate twice as fast, including grenade defenses.

## Map editor

- Switching environments updates the surrounding background. Field and town use grass; bunkers use soil. Decorative ground stays aligned during camera movement and zoom.
- Added door texture choices and colored station wall accents. Both survive saving, copying, rotating, undoing, and resizing.
- Added decorative corpses, blood pools, and blood drops, with free-position placement and a decal eraser. Decals are included in saved maps and reusable structures.
- Added a room and structure preset manager with textured previews, placement, deletion, and updates from edited selections. Use **Presets → Save Selection** to create or update a preset.
- New and resized maps support named sizes and exact tile dimensions. Expanding a map preserves its existing cells and decorations.
- Fixed the editor Escape error. Lobby map previews now use the actual game terrain and object artwork.

## Multiplayer, saves, and options

- The host’s cross button kicks a connected guest and reopens their seat. Loading a saved roster no longer restores stale player connections.
- Repeated End Turn clicks wait for the host’s reply instead of sending duplicate requests.
- Guests can join as spectators. Spectators can move their camera to any army, toggle fog, choose a vision POV, and draw. Spectator drawings are shared only with other spectators, and gameplay requests from spectators are rejected.
- Saved matches preserve the casualty ledger, round and in-game clock, elapsed real time, and the original battlefield for Before/After.
- Added a grid visibility toggle and a 0–100% opacity slider in Settings.
- The main menu shows the version from the game’s release setting.

Multiplayer participants must use the same version. Existing saves remain readable; saves made before this update cannot recover an original battlefield or elapsed time that was never stored.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.9.7.1...v0.9.8
