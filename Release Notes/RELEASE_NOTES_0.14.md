# Isotope 0.14

## C++ performance improvements

- Added optional native kernels for first-person mesh assembly, terrain preparation, AI planning, pathfinding and visibility.
- Terrain preparation accelerates roof and interior detection, floor textures and ground tracks while preserving staged loading.
- AI accelerates distance fields, firing-line indexes, nearest-enemy searches and destination assignment. Movement searches preserve their original costs, paths and tie order.
- Visibility accelerates sight sweeps, shadow processing and team visibility updates, retaining existing fog, gas, obstacle and alliance rules.
- Game rules, random draws, saves, replays and Godot scene behavior retain their existing implementation. Native and GDScript players can play together on the same release.
- Complete test-town preparation used 37–47% less CPU time across Windows, Linux, Intel Mac and Apple Silicon CI. These measurements describe preparation work, not a guaranteed increase in frame rate.

To enable the C++ speedups, build the optional library once with `python native/visuals/build.py`, then launch the project normally. The [native build guide](https://github.com/Broiler2113/mcf-isotope/blob/v0.14/native/visuals/README.md) lists prerequisites and verification commands. Without the library, all systems continue working through their original GDScript implementations.

## Lobby and menus

- Holdout's **Wave multiplier** and per-wave **Multiplier increase** are editable in the lobby, including when loading a saved game. Wave sizes use the defending team's current surviving soldiers. Already-announced waves keep their announced size.
- Escape menu buttons now appear as **Resume**, **Settings**, **Save Game**, **Save Replay**, and **Return to Menu**.
- Removed the bug-report button from the main menu.

## Validation

- Desktop CI compares native results against the original algorithms, including exact mesh buffers and terrain pixels, ordered paths, AI decisions and random state, visibility, and complete match traces.
- Regression checks cover saves, replays, undo/redo, first-person rendering and multiplayer. Real multiplayer peers pass with either the native or GDScript host.
- All five native kernels passed differential tests with AddressSanitizer and UndefinedBehaviorSanitizer on Linux.

**Compatibility:** network protocol **30** and replay schema **3**. Multiplayer participants must use the same release. Existing saves and historical replays remain supported; older Holdout saves retain the default +0.1 increase per wave.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.13.5.2...v0.14
