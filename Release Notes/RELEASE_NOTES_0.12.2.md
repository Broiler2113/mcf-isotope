# Isotope 0.12.2

## Destruction and combat

- Wall chunks are now sharp, jagged pieces in different shapes and sizes instead of round blobs.
- Blood, glass shards, wall chunks, casings and items look the same in flight as on the ground: pixel art all the way, no more smooth shapes that turn pixelated when they land.
- Destroying part of a table, counter, bed or other large piece of furniture breaks only that cell. The rest stays standing and keeps its original appearance.
- Fire consumes furniture. Flame jets now reveal fire tiles rapidly along their path, and bullets, shells, rockets, grenades and muzzle flashes use sprites.
- Flamethrower soldiers survive flame bursts from other flamethrowers.
- Debris in space keeps drifting with momentum instead of settling on empty space.
- Shield-bearers push loose items and debris as they move.
- Destroyed cabinets scatter contents in different directions. Dragging storage furniture has a chance to spill its contents.

## Furniture and small items

- Repaired furniture autotiling. Pianos and other two-cell pieces form consistent pairs, and individual objects no longer rotate just because furniture is placed beside them.
- Storage and shop shelves have empty, tool, medical, food and drink variants. Different contents join along the same shelf structure, with consistent rails and orientation.
- Open cabinets and refrigerators have clearer sprites. Spilled contents match the storage type: cabinets no longer spill plates, and refrigerators spill food.
- Added 42 loose-item types, including food, newspapers, medical and scientific supplies, musical instruments, clothing, tools, weapons, ammunition, handcuffs and a cash register.
- Tables have more varied arrangements, newspapers have multiple editions, and map and radio sprites are clearer.
- The toolbox is a small item. The desk-with-lamp object has been retired; existing maps migrate it to an ordinary desk.
- Added bush and houseplant variations, more vending machines, a shower unit, a bathtub and a machine workstation. New art extends the existing sprite generator.

## Towns and stations

- Town streets branch into offset blocks and T-junctions, with larger plots near the centre.
- Residential buildings reserve an enclosed restroom. Furnished maps include a toilet and lighting inside it.
- Town parks have dirt paths, trees, benches and vending machines. Shops have cash registers, and loose items occasionally appear on floors.
- Window tiles have interior floor underneath them.
- Stations of every size include an engineering department and solar arrays. Production areas retain machinery workstations, including when deployment uses the room.
- Exterior station entrances use distinct docking doors and paired airlocks with a one-tile chamber. The doors interlock to keep the chamber closed on one side during ordinary passage.
- Station generation avoids repeatedly scanning the whole map for annex attachment points, preserving the same generated layout while reducing generation time.

## Lighting and interface

- Morning, day, evening and night look visibly different. Streetlights and bollard lights switch off during the day.
- Before/After keeps lighting active and hides the battle's debris when showing the opening map.
- Army deployment uses the battle sidebar's dimensions, alignment and styling.
- Tools and Drawing have separate buttons in the top-left corner.
- Popup panels share draggable headers and resize controls; smaller panels scroll their contents.
- The engineer's construction menu has a separate back-arrow button at the top left.

## Map editor

- Placing small items preserves the table underneath. Extending a table preserves its existing items without duplicating them.
- Corpses are real map bodies rather than decals, including when saved, copied or rotated.
- Anti-tank hedgehogs can be placed on sandbags.
- Removed the obsolete “click anywhere” instruction from the decals section.

## Multiplayer

- Use this release on every peer. Its multiplayer protocol is incompatible with 0.12.1 and earlier 0.12.2 development builds.

## Validation

- 69 headless regression suites, with targeted reruns after fixes, and 132 generated-map scenarios.
- Direct multiplayer, spectators, kicking and relay checks.
- Small, medium and large battle benchmarks: host/client agreement, zero resyncs, matching saves and replays.
- Rendered checks of panel movement and resizing, deployment layout, editor placement, Before/After lighting and daytime streetlights.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.12.1...v0.12.2
