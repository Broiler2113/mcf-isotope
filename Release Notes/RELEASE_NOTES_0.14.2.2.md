# Isotope 0.14.2.2

## Tank appearance and firing

- Moved the faction stripe across the rear deck behind the turret, perpendicular to the forward-facing gun. The turret, armor sides, tracks, and barrel retain their original texture.
- Tank name, durability, crew count, and yellow action-point dots now share a dark framed status card below the sprite, keeping both the labels and faction stripe readable.
- Tanks can fire their cannon forward or sideways, but never backward. Turn the hull to engage a rear target. Target highlighting, AI positioning, and multiplayer shot validation follow the same rule.
- Increased tank height by 25%, keeping its length, width, and 3×3 gameplay footprint unchanged. First-person models use corrected surface normals, and the top-down sprites remain 96×96.

## Compatibility and validation

- Network protocol is now **31**; multiplayer participants must use the same release. Replay schema remains **3**.
- Existing saves continue with the new firing rule. Older replays preserve their original cannon behavior, including when seeking or resuming into a new match recording.
- Regression coverage includes all four hull facings and every edge firing lane, rejected-shot state preservation, AI positioning, replay transitions, model height, rear stripe placement, texture preservation, and sprite padding.
- Release checks cover Windows x64, Intel Mac, and Apple Silicon, including gameplay, UI, and bundled native startup.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14.2.1...v0.14.2.2
