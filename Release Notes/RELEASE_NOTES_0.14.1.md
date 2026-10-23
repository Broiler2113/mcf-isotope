# Isotope 0.14.1

## C++ speedups enabled automatically

- Windows x64, Intel Mac, and Apple Silicon libraries are included in the same project download. No compiler, terminal setup, or installation switch is needed.
- First-person geometry, terrain preparation, AI planning, pathfinding, and visibility use C++ automatically when the game starts.
- **Settings → Interface → Performance** shows the actual acceleration status.
- The loader verifies the bundled files and their matching source before loading them. If acceleration is unavailable, the original GDScript implementations remain available.
- The libraries add about 1.2 MB before compression and require no separate C++ runtime installation. Intel Macs require macOS 11 or later; Apple Silicon requires macOS 13 or later.

## Validation

- Startup from the project download, all five native kernels, gameplay, saves, replays, and first-person regression checks passed on Windows, Intel Mac, and Apple Silicon.
- Mac startup was checked with downloaded-file quarantine attributes and the original Godot app signature.
- Builds and checks now target Windows and macOS only. Linux builds and checks are paused.

**Compatibility:** network protocol **30** and replay schema **3**, unchanged from 0.14. Existing saves and replays remain supported. Multiplayer participants should use the same release.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14...v0.14.1
