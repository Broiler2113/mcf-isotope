# Isotope 0.14.2

## New tank model

- Tanks now use the supplied SVAROG model and texture in first-person view.
- The 2D battle view uses crisp 96×96 sprites rendered directly from above, with hull rotation and separate turret aiming.
- Main body paint follows the team's color while preserving texture detail and neutral tracks. Destroyed tanks use matching wreck sprites and geometry.

## Camera and keyboard fixes

- Fixed camera shaking when dragging with the right mouse button while zoomed far out in the 2D battle view. Manual panning and zooming now stop automatic recentering, and releasing over the HUD ends the drag correctly.
- Fixed F2 failing to open cheats when chat or a HUD control has keyboard focus. The shortcut now runs before focused controls consume it, including on Windows. Rebound function keys work too; typing, modal dialogs, and cheat permissions retain their existing behavior.

## Validation

- Added regression coverage for tank textures, team colors, 96×96 frames, turret rotation, camera dragging, and console shortcuts through the real input path.
- Windows x64, Intel Mac, and Apple Silicon CI include the camera, tank, console, and hotkey checks. The existing bundled C++ acceleration libraries are unchanged and their source and payload hashes remain verified.

**Compatibility:** network protocol **30** and replay schema **3**, unchanged from 0.14.1. Existing saves and replays remain supported. Multiplayer participants should use the same release.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14.1...v0.14.2
