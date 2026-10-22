# Isotope 0.13.1

## First person, rebuilt
- The 3D view is lit by the battle screen's own lighting: the same lamps, the same colors, the same shadows the board shows. No more lights popping on and off or flickering as you walk.
- Furniture has models built to its shape — chairs with frames, tables whose legs meet the top, beds with headboards and pillows, lockers, shelves of books and goods, machines with their panels.
- Everything is drawn at one size: 32 pixels to the meter, floors, walls, furniture and small items alike.
- Walls and floors have real texture: brick courses, cinder blocks, riveted hull panels, plank joints, skirting boards inside and plinths outside.
- Grass and field earth are one continuous ground that runs to the horizon — no grid of tiles under your feet, and the land goes on past the edge of the map.
- Sandbags are rows of filled bags, hedgehogs are three crossed steel beams, trenches are duckboarded pits, solar panels sit beside the station, and the invisible map edge stays invisible.
- Doors sit inside the wall and no longer flicker against it. Welded airlocks wear their weld beads; boarded-up wooden doors wear their planks.
- Tanks, shuttles and borgs are modeled, the tank's turret turns, and the vehicle's name is printed on its hull in the game's own font.
- Blood on the walls is a spatter with streaks and runs, both in 3D and on the board.
- Shooting shows: tracers from the muzzle, rockets with their exhaust, shells, grenades arcing over, fireballs where a blast goes off, and debris thrown about.
- **Walk the map in the editor:** View → Walk in First Person, then click a cell.
- Destroyed beds and other large furniture retain their surviving sections at their original size and orientation, including after loading a saved battle.
- Material and ground textures are baked into the source tree, removing their generation pause when first entering 3D.

## Winter
- **Winter** maps: snow on the ground, the plants and the roofs, snowdrifts and snowmen. Town and field only, and it changes nothing but the look.
- Turn it on with the Winter box beside Obstacles for a random map, or Map → Winter (snow) in the editor.
- Snow falls over the battlefield and in first person. Switch it off in Settings → Display.
- Snowmen and drifts are cosmetic decorations with no collision, cover or gameplay cost. Winter preserves a seed's terrain, objects and deployment zones, and stays snowy at distant zoom.

## Maps
- **Botany bays** on stations: planter beds, racks of hydroponics under grow lights and a potting table.
- More green outdoors: tall grass, hedges, flower beds, pines and more trees and bushes on open ground.
- Raiders land again. An army only keeps the next one away while it is still a force, and a landing on a stretch of bare vacuum slides along the edge to the nearest ground instead of turning back.

## Rules
- A side with no soldiers left is skipped in the initiative — a drone in the air does not hold its turn open.
- An engineer can **cut a welded airlock open** again, for the same AP it took to weld it; an engineer borg does three per action.
- A **borg tears down** walls, glass and airlocks three per AP, just as it builds them.
- A drone detonation that killed nobody can be **undone** — the drone, the walls and the wounds all come back.
- Smashed furniture breaks into chunks of itself instead of leaving rubble on the floor.

## Battle screen
- The **ruler** is a drawing tool now: rulers stay on the board, are shared and undone like your strokes, and sit with Draw and Erase. Multi-select and the heightmap are hotkeys (Z and Shift+H).
- Turning on **Share with team** or **Share with everyone** now shares what you drew before it, too.
- Sharing preserves drawing undo, including erased strokes and older rulers.
- Bodies inside a borg are drawn on top of it.
- The square beside *Enemies left* in Holdout is the waves' own color.
- Drones give off a little light in the air; scout drones more.
- Changing the accent color repaints the side panel's stripe at once.
- The purchase screen zooms out far enough to see the whole map.

**Compatibility:** network protocol 25 — all players must use the same release. Saves and replays from 0.13 still load.

**PDF review and validation:** [Fix-8 review](https://github.com/Broiler2113/mcf-isotope/blob/v0.13.1/tests/FIX8_REVIEW.md).

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.13...v0.13.1
