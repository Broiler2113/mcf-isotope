# Isotope 0.13.5.1

## Fixed-size battlefield labels

- Battlefield IDs and tile coordinates retain their screen size and shape throughout the 0.12x to 2.5x zoom range. Their anchors follow the map.
- Added an automatic rendered regression check for living-unit, corpse, vehicle, and coordinate labels, including fractional camera positions.
- Linux CI compares the actual glyph pixels through zoom input, so a change that scales either type of label fails the check.

**Compatibility:** network protocol **29** and replay schema **3**, unchanged from 0.13.5. Existing saves and replays remain supported.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.13.5...v0.13.5.1
