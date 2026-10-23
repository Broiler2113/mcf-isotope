# Isotope 0.13.4

## Console and battlefield tools

- Trackpad scrolling and pinching over the console, manual, or communications panel no longer moves the battlefield camera.
- Console lists and status reports use bordered tables. Command suggestions show concise command text, and the manual has a clearer command reference.
- `inspect unit`, `inspect vehicle`, and `inspect cell` select targets by clicking the battlefield. Entity commands accept visible IDs directly instead of showing long lists of units.
- `coords on` displays tile coordinates; `coords off` hides them. Commands use `(x,y)` coordinate pairs.
- Area events use two inclusive opposite corners, such as `event place gas (1,2) (3,4) 3`. The event editor, click placement tools, smoke, gas, and fire clearing follow the same convention.
- For spawning, `self` creates one independent AI army hostile to every player. All units spawned this way belong to that same army. Use a player slot such as `#1` to spawn for a player.

## IDs and battlefield fixes

- Battlefield ID labels keep the same readable size at every zoom level.
- Corpses retain their original ID with a trailing dash, such as `U12-`. Labels follow bodies through carrying, dropping, dragging, and vehicle unloading; identities survive saves and undo.
- Corpse walls cannot burn, matching LDF walls and pillboxes.
- Space station maps generate slightly more windows.
- Changing the accent color during battle no longer calls a freed HUD control and breaks the interface.

## First-person controls

- Noclip supports unrestricted flight in every direction and at any height within the explored map. Gravity, drift, terrain, and space movement rules do not constrain it; fog of war still applies.
- Added **First-person controls** beside the map editor shortcuts in Settings. Movement, running, climbing, descent, noclip, and returning to the battlefield are listed and can be rebound.
- Removed the on-screen control hints. Standalone modifier bindings such as Shift for running display correctly in the keyboard diagram and can be reassigned.

## RLM training

- Frozen opponents and evaluation skip observation encoding and neural-network inference when only one legal action exists. Learner rollouts still calculate the value estimates required by PPO.

**Compatibility:** network protocol **28**; all players must use the same release. Existing saves remain supported, and historical replays retain their original corpse and fire rules.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.13.3...v0.13.4
