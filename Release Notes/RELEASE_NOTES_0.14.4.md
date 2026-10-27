# Isotope 0.14.4

## Cheat console

- The console has a new look: a black window under the game's usual title bar, colored command lines, red refusals and a single input field that lights up while you type.
- Suggestions show the in-game name next to each word, such as `hedgehog - Anti-Tank Hedgehog`, and explain the highlighted command underneath.
- Players are named by their letter: `A` is Player A, `B` is Player B, including yourself. Quoted player names work in any letter case.
- `spawn unit engineer A` spawns for Player A. Use `independent` instead of a letter for an army hostile to everyone.
- Vehicles have short IDs: the first one is `V0`. The old long IDs still work.
- The LDF is now typed `ldf` and the stationary machine gun `dpmg`. In-game names such as `"Anti-Tank Hedgehog"` work too.
- `help` lists topics. `help unit`, `help event` and the others list their commands, and `help all` lists everything. Spawn and event help name every unit type and event option.
- `unit stat change U12 armor 6` works without parentheses. The help now lists every stat's limits.
- `event set warning:2 edge west` takes edge names, and `side` takes a player letter. `event types` shows how each event is aimed and which options it takes.
- `event cancel all` cancels every warning. Use `event remove` with a reference from `event list` to cancel one.
- `inspect` shows names and yes/no instead of internal numbers.
- AI pause, resume, step and speed no longer clear Undo and Redo or post to the shared log.
- Players without permission no longer see the host's permission, kick and ban commands in suggestions.
- In a local game, only the first human seat can grant or revoke cheats.
- F2 opens the console even when cheats are off. Commands then refuse, and `help` still lists them.
- Battlefield IDs and coordinates no longer switch themselves off when a hotseat turn passes to another player.
- Heavy Infantry no longer appears twice in spawn suggestions.

## Drones

- On the battle screen, drones sit exactly in the middle of their cell, directly over any soldier there.
- In first person, drones hover lower, at 1.75 m, so they stay clear of the ceiling, and never rise into a roof indoors.
- In first person, drones no longer spin. They face north like their battle-screen picture and bob gently up and down.

## Compatibility

- Network protocol **32**: all players must use 0.14.4. Replay schema **3** is unchanged, and existing saves and replays remain supported.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14.3.1...v0.14.4
