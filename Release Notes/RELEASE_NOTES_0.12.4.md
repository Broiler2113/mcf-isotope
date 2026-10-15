# Isotope 0.12.4

## Interface and controls

- End Turn now defaults to **Shift+Enter** and can be reassigned in Settings. Clicking the button no longer lets a later Enter press accidentally end another turn. Enter remains available for dice rolls and wall confirmation.
- Camera buttons use an aligned grid of equal squares, including games with eight sides.
- The Actions list in Keybinds fills the available space down to the footer.
- The lobby event picker shows only events supported by the selected map and mode: Dust Storm on Field/Town, Old Minefield on Field/Town/Asteroid, and Bounty in Capture & Hold. Unsupported events also receive zero weight. Event descriptions remain in the manual.

## Units and manual

- Removed Assault from deployment, editor palettes, random armies and the manual. Existing maps and saves containing its old resource use Heavy Infantry instead.
- Renamed Sapper to **Minesweeper** throughout the interface, retaining the old internal ID for saved content.
- Replaced em dashes in the manual with ordinary hyphens and limited unit descriptions to the requested specialists.
- Added a dedicated Lasers section, clarified the Sniper's defense penalty, and explained the six-tile **LDF (Large Deployable Fortification)** in the Engineer card and item list.
- Vehicle cards use square badges and their texture overrides. Added Borg engineering rules and instructions for operating a drone station from shuttle seats.

## Combat and debris

- Removed the hit penalty for firing through burning cells, including DPMG fire and shots at glass.
- Anti-tank and tank shots preserve the complete terrain appearance while dice are shown and until impact. Walls retain their material and connections, airlocks retain their closed appearance, and terrain, fog, lighting and distant views change together at impact.
- Debris in vacuum keeps drifting beyond the invisible map boundary. Real walls still stop particles, and saves and replay checkpoints preserve their motion.

## Bug reports and replays

- Removed the example description from Report a Bug.
- Added file selectors for external screenshots, compressed or JSON replays, and text combat logs, available from the menu and during a battle.
- New replays include recent combat text, so selecting one can attach its combat log too. A different combat log can also be selected separately. Only checked attachments are sent.

## Multiplayer

- Uses **protocol 15**. All players must use 0.12.4; multiplayer is incompatible with 0.12.3 and earlier releases.

## Validation

- Script parsing and 19 relevant regression suites covering the PDF fixes, controls, combat, fire, events, lighting, fog, serialization, replay and decal behavior.
- Rendered checks for Settings, report attachments, the eight-side camera grid and shot presentation, including distant terrain.
- Five direct multiplayer scenarios, plus spectator, kick and relay tests.
- Small, medium and large simulated battles agree between host, guest, saves and replays, with zero resyncs. Deterministic baselines reflect the retired unit and removed fire modifier.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.12.3...v0.12.4
