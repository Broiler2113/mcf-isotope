# Isotope 0.13

## First person
- **First Person** in the tools: click any free cell you can see and walk the battlefield in 3D. WASD and the mouse, Space to jump or climb out of a trench, X to walk through everything, Esc to leave.
- One cell is one meter. Walls and glass fill their whole cell up to the 2.3 m ceiling, buildings have ceilings inside and roofs outside, and trenches are 2 m soil pits you can climb into.
- Furniture is built to real shapes, and walls and doors have their own 3D materials with level service stripes. Soldiers, trees and bushes are 2.5D cut-outs that turn to face you.
- Fog of war still applies: never-seen cells are black and remembered ones are dimmed. Blood, decals and items show as they do on the board.
- Lighting covers sky, stars, sun, lamps, fire and explosions, and night maps are dark. In space you float and drift, with the station deck as your floor.
- First person never changes the battle. Field of view and mouse sensitivity are in Settings.

## Soldiers & equipment
- **Scout drones:** a drone station can launch a kamikaze drone or a scout drone. A scout flies 60 cells per action, up to 45 cells from its station, and never explodes. The old drones are now called kamikaze drones.
- **Give Units:** hand any of your soldiers to another player at any time.
- Engineers build **colored floodlights**, 2 per AP (5 in a borg). An engineer borg welds 3 airlocks per action.
- An engineer can mount a **DPMG in a shuttle seat**; a soldier in the next seat fires it, and it rides along.
- A shield bearer now shelters only the soldiers **behind** him from a blast, not everyone beside him.
- A soldier held by the enemy keeps seeing for his team under fog.

## Holdout
- Type the number of waves; 0 means endless. You win when every wave soldier is dead.
- Waves are sized from the defenders' average army: 0.7× for the first wave, then +0.1× per wave. The first size is editable in the lobby.

## AI
- Hard AI, raiders and Holdout waves storm enemy tanks, shuttles and empty borgs before shooting.

## Battle screen & lobby
- Mines flash like an explosion when they go off. Explosion flashes no longer show over open space.
- Blood spatters walls beside soldiers who die there, drawn with the same sprites as floor blood.
- Bodies inside a shuttle are drawn on top of its hull.
- Optional FPS counter (Settings → Display), shown beside the side panel.
- Teammates see each other's deployment live under fog. Tab opens the initiative overlay on the purchase screen too.
- Lobby chat sits beside Random Events and Saved Game. The camera button reads **Me**.

## Performance
- No more freezes when a tank breaks through walls or a big group moves under fog of war (a 1 s stall on 2 cores is now 11–15 ms).

**Compatibility:** network protocol 24; all players must use the same release.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.12.12...v0.13
