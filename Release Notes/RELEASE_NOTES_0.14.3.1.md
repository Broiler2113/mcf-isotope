# Isotope 0.14.3.1

## Fixes

- Soldiers and tanks are visible again on Windows. A copy updated without Godot re-importing the new tank model stopped drawing the board at the first tank, hiding every soldier.
- First-person walls, floors and furniture no longer turn black in such a copy, and tanks and drones keep their models.
- Tanks, drones and first-person pictures now load straight from the game's own files, so a stale import can no longer hide them.

If something still looks wrong after updating, open the project once in the Godot editor (or delete its hidden `.godot` folder) so Godot re-imports everything.

## Compatibility

- Visual fixes only. Network protocol **31** and replay schema **3** are unchanged from 0.14.3; existing saves and replays remain supported.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14.3...v0.14.3.1
