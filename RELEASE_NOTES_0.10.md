# Isotope 0.10

## Dynamic lighting

- Added optional dynamic lighting with smooth glows and shadows. Enable it in **Options → Display**; it is off by default.
- Unlit areas stay dark but slightly visible on every map type. Lighting changes the appearance of the battlefield without changing fog of war or revealing hidden units.
- Walls, cover, and closed doors cast shadows. Glass and armored glass let light through, and destroying obstacles updates their shadows.
- Fire, muzzle flashes, explosions, and gas clouds now emit light. Sources have different strengths, ranges, and colors: warm fire, white lamps and gas, and subtle blue machinery.
- Lighting works during battles, replays, and purchasing/deployment. The map editor also has a lighting preview toggle.

## Lamps and map generation

- Added 12 light fixtures, including wall lamps, light strips, bulkhead lamps, beacons, flood lamps, streetlights, bollard lights, work lights, floor lamps, and desks with lamps.
- Newly generated maps place fixtures suited to their environment, including streetlights along town roads. The new textures follow the existing furniture style.
- Added separate wall-mounted and freestanding lighting options to the map editor. Fixtures can also be included in reusable presets.
- Wall-mounted and wall-top fixtures can be aimed at and shot separately from their supporting wall. Destruction removes their light, including damage from explosions or loss of their support.
- Generators, server racks, and machinery emit light too. Destroying a generator removes its own glow.
- Fixtures are preserved by maps, saved games, replays, and multiplayer synchronization.

## Controls and performance

- **Z** now toggles multiselect while keeping the existing selection behavior. Passenger menus retain **Z** for Change Seat, and the multiselect shortcut can be rebound in Settings.
- Engineers and engineer borgs now have a single **Build…** button that opens a menu of available structures.
- Improved group-move previews by spreading pathfinding work across frames and caching the movement overlay, reducing stalls when selecting and moving large groups.
- Fixed an AI movement fallback that could try to move an embarked vehicle crew member from an invalid board position.

## Map editor and deployment

- Floor brushes now preview the selected floor texture at 50% opacity beneath the cursor.
- Fixed an Escape-key error when leaving the map editor.
- Deployment chat now matches battle chat, with a translucent background, dragging, resizing, and collapsing.
- Decorative grass and soil are visible during purchasing/deployment, and the Infantry panel no longer shows “Pick a unit…”.

## Branding

- Updated remaining MCF Tactics branding to **MCF Isotope**. Importing data from the old application folder remains supported.
- The main menu now displays version **0.10**.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.9.9...v0.10
