# Isotope 0.14.2.3

## Tank proportions and first-person fog

- Reduced tank height by a factor of 1.125 from 0.14.2.2, about 11% lower. Length, width, textures, and the 3×3 gameplay footprint are unchanged; 2D sprites remain 96×96.
- Moved the black status frame closer to the tank. It now follows the visible silhouette instead of the transparent sprite padding, including when the hull or turret turns.
- Closed gaps between first-person fog panels at corners and diagonal joins. The panels now overlap at their ends while preserving their offset from walls to avoid flickering.

## Validation and compatibility

- Regression checks cast rays through the fog geometry at every local boundary arrangement and across camera altitude bands, checking that unknown cells stay hidden and adjacent known cells remain visible.
- Windows x64, Intel Mac, and Apple Silicon checks cover gameplay, tank visuals, first-person fog, UI, replays, and bundled native startup.
- Network protocol **31** and replay schema **3** are unchanged from 0.14.2.2. Existing saves and replays remain supported.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14.2.2...v0.14.2.3
