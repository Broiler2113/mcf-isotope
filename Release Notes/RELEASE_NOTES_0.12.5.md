# Isotope 0.12.5

- Hosts can choose Easy, Normal or Hard independent armies. Easy favors light and heavy infantry; Hard favors anti-tank troops and specialists. Saved games, replays and guests retain the setting.
- Space stations generate more paired solar arrays around their exterior hull.
- Old Minefield can occur on every map, including station and bunker floors, and includes anti-vehicle mines. Eligible fields always contain mines.
- Player drawings keep their color under night tint and dynamic lighting.
- Explosions retain unaffected terrain textures, cache image readbacks and spread affected texture rebuilding across frames.
- F11 toggles fullscreen on every screen and can be reassigned in Settings.
- Vehicle ramming shows wall destruction, crushing, scattered items, debris and tracks as the hull reaches them.
- Undo and redo restore decals and scattered items along with the board, preserving earlier battle debris.
- Later network actions wait for earlier dice and impacts, preventing premature casualties. Guest movement waits for host acknowledgement and uses the exact clicked tile after camera pan/zoom.
- Fire appears above terrain, vehicles and living units; corpses appear above fire.
- Selection rectangles stay anchored to the map when the camera moves. Shift adds further rectangles to the selected group.
- Multiplayer uses protocol **16**; all participants need the same version.

## Validation

- All 239 scripts parse. 71 of 72 regression suites pass, including the new issue suite and 38,200 sampled legal actions.
- Direct and relay multiplayer, guest movement through the unit menu, spectators, kicking, and the report server tests pass.
- Rendered checks verify unchanged drawing colors under both lighting modes and fire/corpse layering.
- Small and medium battle signatures match their existing baselines, including host/guest, save/load and replay agreement.
- The explosion benchmark reduced cached texture work on the impact frame from approximately 56 ms to 15 ms on this machine; timing varies by hardware.
- The existing `run_outer_grass.gd` test still fails four Town border cases. The same failures were reproduced with the original code in an isolated baseline project.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.12.4...v0.12.5
