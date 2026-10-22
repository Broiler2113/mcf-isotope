# Isotope 0.12.10

## Sound
- Every sound effect is now a real recording: firearms, military explosions, cannons, engines, impacts and footsteps, all mixed to one consistent style.
- Each weapon sounds like itself: rifle, burst, sniper, shotgun, machine gun, the heavy machine gun on DPMGs and borgs, the marksman's laser and the flamethrower.
- Repeated sounds vary slightly each time, so a burst or a walk never sounds copy-pasted.
- Bullets sound different depending on what they hit: bodies, a Shield Bearer's shield, vehicle armor, glass, wood, masonry, steel or dirt.
- Footsteps follow the floor, airlocks hiss open and slam shut as soldiers pass, drones buzz, and visible fires crackle.
- Random events have their own sounds: incoming artillery whistles, gas hiss, EMP crackle, dust storm and collapse.
- Each environment (station, bunker, asteroid, town, field) has its own ambience and echo; sounds in vacuum are muffled.
- The announcer now speaks over a field radio, with a click before each line and a beep at the end.

## Shield Bearers and combat
- A Shield Bearer now dies only from a direct hit by a tank cannon or an Anti-Tank round, or a drone exploding right above it.
- Frag grenades, mines, artillery shells and exploding wrecks never kill a Shield Bearer, even on its own cell.
- A soldier who kills with part of a burst keeps the rest of the burst for another target — borgs can finish their four shots.
- Flamethrowers now have 4+ armor.

## Holdout and AI
- New lobby option "Wave frequency": a wave every 1 to 5 rounds (default 2).
- Waves and raiders treat tanks and shuttles as a threat: they keep off the hull and spread out within reach of a tank's gun instead of clustering.
- Anti-Tank soldiers stop at firing distance and shoot, instead of walking up to the hull where their own blast would hit them.
- AI Marksmen now fire at vehicles, and stay in position when they reach a good firing line without enough AP left to shoot.
- AI Marksmen check whether their laser still has enough power after walls, glass and bodies, and don't take shots that wouldn't reach.

## Fixes
- Undo works again after an engineer builds an LDF wall.
- Raiders no longer stay "grabbed" with nobody next to them: a captive is freed as soon as its captor is grabbed, stopped short or gone.
- Drone operators can always pack up their station, even with a second drone hovering beside it.
- When pulling a body out of a vehicle you choose where it goes, or click the soldier to have them carry it.
- Fire no longer erases blood, casings, shards and debris: battle decals stay for the whole match.
- The drawing panel moves out of the way of the unit action menu, starts on white instead of your faction color, and opens and closes with its own button (no close cross).

**Compatibility:** network protocol 21; all players must use the same release.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.12.9...v0.12.10
