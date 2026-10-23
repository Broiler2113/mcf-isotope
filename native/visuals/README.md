# Native visual kernels

This is the first stage of moving measured CPU bottlenecks to C++ while keeping
the Godot project and its gameplay behavior. The optional `MCFMeshBuilder`
GDExtension accelerates polygon triangulation, boxes, transformed vertices, UV
projection, contact shading, and dense mesh buffers. Existing model descriptions
and the GDScript implementation remain the reference.

Build with Python 3.12+, CMake 3.22+, git, and a C++17 compiler:

```sh
python native/visuals/build.py
godot --headless --editor --path . --import
godot --headless --path . --script res://tests/ui/run_native_visuals.gd -- --require-native
```

Then open `project.godot` and run normally. Rebuild after changing the C++ source;
ordinary GDScript edits use the usual Godot workflow. The build verifies the same
godot-cpp commit pinned by `native/policy/dependencies.json`, without downloading
ONNX Runtime or policy dependencies. `--godot-cpp`, `--cache`, `--build-dir`, and
`--jobs` support existing dependencies and build environments.

Compiled output stays in ignored `addons/mcf_visuals/bin/<platform>-<arch>/`.
Only a completed build generates a platform manifest. Source archives keep the
working GDScript implementation and open without a compiler or native library;
building enables the acceleration. `MCF_NATIVE_VISUALS=off` forces the reference
path for comparison. An incompatible API also falls back to GDScript. Build the
extension separately on each platform that will use it.

## Compatibility and verification

The native code owns geometry buffers only. Game state, random numbers, AI,
networking, save files, and replay decisions do not enter it. Compiler fast-math
and floating-point contraction are disabled. Tests compare raw bytes for every
vertex, normal, UV, material layer, and color across reflected/scaled/rotated
primitives and the furniture catalog; rendered tests compare complete scenes.
Invalid native inputs are rejected before any buffer mutation. The original
GDScript path remains selectable for differential testing and source users.

```sh
godot --headless --path . --script res://tests/bench/run_native_visuals.gd
godot --path . --rendering-method gl_compatibility --script res://tests/render_native_visuals.gd
python native/visuals/test_manifest.py
```

The benchmark alternates backend order, clears model caches, and measures both
dense geometry and complete town preparation. Results are CPU timings, not GPU
frame-rate predictions. Keep parity and benchmark evidence with each subsequent
native conversion; migrate another subsystem only after identifying its cost.

An initial Linux headless measurement on the development machine found 215.16 ms
versus 44.02 ms for dense geometry (4.89x), and 1466.82 ms versus 1056.73 ms for
complete 208-chunk town preparation (28% less CPU time). These measurements do not
predict steady-state FPS or results on a player's GPU.

The separate lobby change adds optional Holdout growth to rule snapshots. Default
snapshots retain their original shape and old saves use +0.1. Network protocol 30
prevents older clients from silently calculating different custom waves.
