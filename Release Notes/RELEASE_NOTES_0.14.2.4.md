# Isotope 0.14.2.4

## Updated tank and wreck models

- Replaced the live tank with the updated supplied SVAROG model.
- Destroyed tanks now use the supplied damaged hull and turret, including the damaged barrel, displaced hatch and broken armour.
- Destruction preserves the tank's position, hull facing, turret direction and movement offset. The wreck model's export offset is corrected so the surviving chassis stays in place.
- Rebuilt the live and destroyed tank sprites directly from their respective 3D models, with eight turret directions, transparent backgrounds and 96×96 resolution. Live tanks retain their team stripe.

## Validation and compatibility

- Tank visual, rendered destruction and modular vehicle checks pass. Destruction checks cover four hull facings, eight turret directions, the never-fired turret fallback, detonation, movement offsets and save/load.
- Windows x64, Intel Mac and Apple Silicon checks cover gameplay, tank visuals and bundled native startup.
- Tank size and the 3×3 gameplay footprint are unchanged. Network protocol **31** and replay schema **3** are unchanged from 0.14.2.3; existing saves and replays remain supported.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14.2.3...v0.14.2.4
