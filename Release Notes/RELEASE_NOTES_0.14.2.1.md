# Isotope 0.14.2.1

## Larger tanks with faction stripes

- Tanks are about 25% larger than in 0.14.2, with their original proportions preserved. Their visual footprint is approximately 3.6×2.6 cells, slightly overhanging the unchanged 3×3 gameplay footprint.
- A narrow faction-colored stripe on the upper hull and turret replaces whole-body recoloring. The rest of the armor, tracks, and barrel retain the supplied texture in both 2D and first-person views.
- Purchase and deployment now display tank sprites with the correct facing, including live multiplayer placement.
- Removed tank bounding rectangles from 2D battle, the before view, and movement previews.
- Sprites remain 96×96, with transparent padding that prevents the barrel from being clipped at any turret angle.

## Validation

- Updated regression checks cover model proportions, the unchanged gameplay footprint, stripe coverage, original texture preservation, and sprite padding for all eight turret angles.
- Windows x64, Intel Mac, and Apple Silicon checks cover tank visuals, camera dragging, console shortcuts, hotkeys, gameplay, and bundled native startup. The 2D and 3D artwork was also visually reviewed.

**Compatibility:** network protocol **30** and replay schema **3**, unchanged from 0.14.2. Existing saves and replays remain supported. Multiplayer participants should use the same release.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14.2...v0.14.2.1
