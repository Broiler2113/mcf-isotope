# Isotope 0.13.2

This is a **source-only release**. Download **Source code (zip)** or **Source code (tar.gz)**, import `project.godot` in Godot 4.7, and run with the GL Compatibility renderer.

## First person

- Fixed missing faces on wall fragments and gaps around drone station pads.
- Fixed a lighting flicker caused by changing light-map coordinates before the replacement texture was rendered.
- Other players walking in first person are visible, with smooth movement and normal visibility rules.
- Smoothed soldier and vehicle motion. First person remains available during enemy movement.
- Added visible bullets, rockets, shells, lasers and explosions.
- Running and distance-based footsteps give walking a more natural pace.
- Trenches use consistent earth textures on their floors and walls; LDF walls use their board texture, and pillboxes have no accent stripes.
- Added shuttle wheels, centered corpses on their cells, and corrected sliding door travel.
- Removed wall blood spatter.

## Cheats and sandbox battles

- Enable cheats in the lobby, then choose which human slots have permission. Cheats start disabled; multiplayer guests need the host's permission.
- Press **F2** for the console. It includes command hints, contextual completion, bounded history, paginated entity lists and optional unit/vehicle ID labels.
- Commands cover real units, vehicles and components, terrain and furniture, fire, gas, smoke, events, vision, initiative, AI settings and match objectives. Use `help` to browse the catalog.
- The host can use `cheats grant` and `cheats revoke` during play, including when their own gameplay permission is off.
- Commands follow the normal host action and shared-dice path. Effects survive saves, rejoining and replay; successful gameplay cheats clear undo history.

## Saved matches and rules

- Loading a battle restores its original lobby settings. Hosts can adjust ongoing rules such as fog, cheats, events and future waves before resuming.
- Existing cheat effects remain when the console is disabled for a resumed game.
- Removed the 60-unit cap from waves and raiders. Available landing space and normal composition budgets still apply.
- Older saves receive the updated wave and raider behavior without resetting match progress.
- Corpses can be dragged, dropped and unloaded onto space tiles.
- Drone operators can pack stations underneath them; unavailable actions explain the reason.
- Repeated fog updates reuse the resolver's visibility cache.

## Battle screen and maps

- Combat Log and Chat share one panel with two tabs.
- Undo and Redo are in Tools. On macOS, use **Command-Z** and **Command-Shift-Z**.
- **Escape** opens Settings when no active interaction needs canceling. The separate gameplay Settings button is removed.
- Host-only controls are hidden from guests. Manual and Report a Bug are compact buttons beside Drawing.
- Rulers can be hidden separately from other drawings.
- Winter maps show snow in map previews. Outdoor doors and airlocks have constructed floors instead of grass or snow.
- Asteroid maps no longer generate trees or other greenery.

**Compatibility:** network protocol **26**; all players must use the same release. Existing saves and replays remain supported, with absent cheat fields defaulting to disabled.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.13.1...v0.13.2
