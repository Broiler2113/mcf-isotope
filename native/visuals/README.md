# Native game kernels

Open `project.godot` in Godot 4.7 and run the game normally. The project archive
already includes C++ acceleration for Windows x64, Intel Mac, and Apple Silicon.
Mac requires macOS 11+ on Intel or macOS 13+ on Apple Silicon. It starts automatically, without a compiler, terminal command, or
plugin setup. **Settings → Interface → Performance** shows the current status.

All three desktop libraries travel with the same source project. The game chooses
the library for the running Godot architecture. An unsupported system or unavailable
library uses the original GDScript algorithms, so the project remains playable.

The GDExtension provides:

| Kernel | Native work |
| --- | --- |
| `MCFMeshBuilder` | Polygon triangulation, boxes, transformed vertices, UV projection, contact shading and packed mesh buffers |
| `MCFTerrain` | Interior/roof flood fill, floor tile classification and image composition, ground-line rasterization |
| `MCFPathfinding` | Ordered Dijkstra searches, movement costs, predecessor/path ties, obstacles, fire and hedgehog jumps |
| `MCFAI` | Distance fields, firing-line indexes, nearest-enemy searches and army destination assignment |
| `MCFVisibility` | Exact integer octant sweeps, shadow complements, mask transposition and incremental team visibility merging |
| `MCFPlanScorer` | One AI turn plan: the threat map, every soldier's candidate-cell scores and the marksman's laser trace, over a flat board mirror and units layer |

Game rules, action execution, random draws, persistence, model descriptions and
scene ownership stay in GDScript. Native kernels return the same ordered results;
they do not introduce a new AI strategy or change sight and movement rules.

Linux builds, release libraries, and CI jobs are paused. Do not re-enable them
unless the project owner explicitly requests Linux support.

CI reuses the checked-in libraries when their source and payload hashes match,
then tests automatic startup on Windows and both Mac architectures. It rebuilds
packages when the bundle is missing or outdated, or when the workflow's `rebuild`
input is explicitly enabled. This avoids recompiling unchanged C++ for UI and
documentation changes.

## Optional developer builds

Build only when changing the C++ source or developing for another supported target.
Close the Godot editor and running game first. Use Python 3.12+, CMake 3.22+, git,
and a C++17 compiler matching the Godot architecture. Windows developers should use
an x64 toolchain; Apple Silicon developers should keep their build tools and Godot
native to ARM64 instead of mixing them with Rosetta.

```sh
python native/visuals/build.py
godot --headless --editor --path . --import
godot --headless --path . --script res://tests/ui/run_native_visuals.gd -- --require-native
godot --headless --path . --script res://tests/ui/run_native_terrain.gd -- --require-native
godot --headless --path . --script res://tests/perf/run_native_pathfinding.gd -- --require-native
godot --headless --path . --script res://tests/ai/run_native_ai.gd -- --require-native
godot --headless --path . --script res://tests/fog/run_native_visibility.gd -- --require-native
```

Use `python3` if your system names Python that way. Then reopen `project.godot`
and run normally. Rebuild after changing the C++ source;
ordinary GDScript edits use the usual Godot workflow. The build verifies the same
godot-cpp commit pinned by `native/policy/dependencies.json`, without downloading
ONNX Runtime or policy dependencies. `--godot-cpp`, `--cache`, `--build-dir`, and
`--jobs` support existing dependencies and build environments.

Bundled libraries are in `addons/mcf_visuals/prebuilt/`, with their manifest and
licenses. Developer builds stay in ignored
`addons/mcf_visuals/bin/<platform>-<arch>/` and take precedence over the bundled
library. Only a completed developer build generates its local platform manifest.
One build provides all six kernels. `MCF_NATIVE_VISUALS=off` selects the original
mesh builder; `MCF_NATIVE_KERNELS=off` selects the original terrain, AI, pathfinding
and visibility algorithms. Set both for a complete reference run. An incompatible
API also falls back to GDScript. These developer overrides are not needed for normal
play. Restart Godot after changing a library or an override; native hot reload is
disabled.

## Compatibility and verification

Compiler fast-math and floating-point contraction are disabled. Geometry and
terrain tests compare raw mesh/image bytes. Pathfinding tests compare costs,
predecessors and dictionary order; AI tests compare tied candidate choices,
every plan cell score and threat-map value bit for bit, laser traces record by record,
complete action traces, board snapshots and random state. Plan scores are summed in
GDScript's order, and `pow()` results arrive as an engine-computed table, so the
platform's math library never decides an AI move. Visibility tests compare
both visible cells and cache-invalidation sensitivity, including exact shadow
order and exploration logs. The worker-thread sweep has no mutable native state.

Movement snapshots follow the existing walking revision and prepare only the
search window. Visibility retains the existing gas, tank, alliance and journal
invalidation rules. Floor work stays in bounded batches within the streaming
scheduler. Native and reference clients can share a session: mixed-peer tests
exercise both combinations through lobby, placement and combat.

```sh
godot --headless --path . --script res://tests/bench/run_native_visuals.gd
godot --path . --rendering-method gl_compatibility --script res://tests/render_native_visuals.gd
godot --headless --path . --script res://tests/bench/run_native_terrain.gd
godot --headless --path . --script res://tests/bench/run_native_pathfinding.gd
godot --headless --path . --script res://tests/bench/run_native_ai.gd
godot --headless --path . --script res://tests/bench/run_native_visibility.gd
bash tests/run_net_native_kernels.sh
python native/visuals/test_manifest.py
```

The benchmark alternates backend order, clears model caches, and measures both
dense geometry and complete town preparation. Results are CPU timings, not GPU
frame-rate predictions. Keep parity and benchmark evidence with each subsequent
native conversion; migrate another subsystem only after identifying its cost.

Historical headless measurements from the initial migration (recorded before
Linux checks were paused; not a current Linux support claim):

| Workload | GDScript ms | C++ ms | Speedup |
| --- | ---: | ---: | ---: |
| Roof/interior classification | 58.45 | 8.12 | 7.20x |
| Complete floor atlas preparation | 143.31 | 61.28 | 2.34x |
| Dense ground lines | 67.21 | 15.91 | 4.22x |
| AI 250x250 distance field | 31.59 | 0.59 | 53.58x |
| AI 24,000-candidate assignment | 49.81 | 4.30 | 11.58x |
| AI 240-enemy firing-line index | 98.19 | 25.96 | 3.78x |
| 300 path searches, shared revision | 1655.89 | 88.03 | 18.81x |
| 300 path searches, changed board each time | 1616.49 | 222.88 | 7.25x |
| 20 full-board visibility sweeps, open map | 114.74 | 45.94 | 2.50x |
| 20 full-board visibility sweeps, 8% blockers | 96.53 | 4.38 | 22.03x |
| Complete 208-chunk town preparation | 1654.29 | 980.55 | 1.69x |

Reports use the middle sample (upper middle for even sample counts). Native path
searches include snapshot preparation; floor preparation includes image uploads.
The AI distance-field measurement uses a prepared walk mask. These isolated
workloads do not predict steady-state FPS or an equal speedup for a complete AI
turn. The existing 100-soldier visibility benchmark measured 354 ms versus 141 ms
for a cold team view; cached views remained around 1 ms in both implementations.

The separate lobby change adds optional Holdout growth to rule snapshots. Default
snapshots retain their original shape and old saves use +0.1. Network protocol 30
prevents older clients from silently calculating different custom waves.
