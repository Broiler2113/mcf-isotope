# Isotope 0.12

## New game modes

- **Capture & Hold**: fight over 1, 3 or 5 zones. At the end of every round each zone scores a point for the team with more soldiers in it. First to the target (12 by default) wins, and wiping out the enemy still wins outright.
- Zones are placed fairly: both sides have the same walk to every zone. Cramped maps may get fewer zones rather than unfair ones.
- Zones show on the deployment screen and in battle, colored by whoever held them at the last round end. The side panel shows the score.
- **Holdout**: all players defend together against waves. A wave lands every 2 rounds, or right after the previous one is wiped out, and each is bigger than the last.
- Pick 5, 10 or 15 waves, or Endless. The waves are led by an AI personality of your choice or the trained model.
- The landing edge of the next wave is announced a round ahead.

## Smarter AI

- AI difficulty levels are replaced by personalities, all playing at full strength: **Tactician** (balanced), **Aggressor** (pushes hard) and **Fortifier** (digs in, builds, mines the approaches).
- Every AI now values its soldiers' lives: it avoids open firing lines, uses cover and smoke, runs from fire, and no longer hits its own men with flames, lasers, drones or tank shells.
- AI sappers sweep for mines when the enemy has a sapper.
- In Capture & Hold the AI sends the right soldiers to the zones it needs. In Holdout the defenders hold their positions.

## Smoke grenades

- Heavy Infantry now carry a smoke grenade. It makes a 3×3 cloud that lasts until the end of the next round, blocks sight and aimed fire, and harms no one.

## New random events

- **Fire Outbreak**: a fire starts in an announced zone and keeps spreading.
- **EMP Burst**: hits a vehicle and damages its gun; drones in the area drop, and drone stations and LDF walls burn out.
- **Dust Storm** (town and field maps): for two rounds every shot beyond 3 cells needs one more.
- **Structural Collapse**: walls in an announced zone come down, and anyone inside may be crushed.
- **Reinforcements**: the side that is losing gets fresh troops at its nearest edge.
- **Bounty** (Capture & Hold): the leader's most valuable soldier is marked, and killing it within 3 rounds scores 2 points.
- **Old Minefield** (asteroid, town outdoors and field maps): forgotten mines appear somewhere at the start of a round. Nobody is told where, and each one goes off only some of the time.
- The event list in the lobby now explains what each event does and where it can happen.

## Manual

- A new **Manual** covers every rule: turns, shooting, cover, fog, fire, mines, drones, vehicles, events, game modes and the AI personalities.
- It has a card for every unit and vehicle, with its stats and what it is good at.
- Open it at any time with **F1** (F2 in the map editor), or from the main menu, the battle panel or the editor's View menu.

## Settings

- The Keybinds page shows a keyboard: used keys are highlighted, keys used with Ctrl / Shift / Alt have their own color, and hovering a key lists everything it does. There are separate views for the game and the map editor.

## Report a Bug

- **Report a Bug** in the main menu, the battle panel and the editor sends a report straight to us: your description, an optional contact, and (if you leave them ticked) a screenshot, the game's technical log, and the current match's combat log and replay.

## Files

- Saves, replays, maps and presets now go in their own folders right in the game folder: **Saves**, **Replays**, **Maps** and **Presets**. Files from the old "Isotope Data" folder move there automatically.
- Release notes live in the **Release Notes** folder.

## Fixes

- The game no longer falls back to the old system font until a restart after an update.
- All game text now uses American English spelling.

## Multiplayer

- 0.12 can only play with 0.12, because of the new modes, events and AI.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.11.3...v0.12
