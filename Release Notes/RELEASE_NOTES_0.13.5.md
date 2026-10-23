# Isotope 0.13.5

## Scenario recovery

- `checkpoint` saves a quick test checkpoint. Use `checkpoint baseline` to name one, `checkpoint restore baseline` to recover it, and `checkpoint list` to see this match's checkpoints.
- Checkpoints restore the complete scenario and random stream, separately from manual saves. Successful gameplay cheats still clear ordinary Undo and Redo.
- The host can use `game step back`, `game step forward` and `game history` across recorded actions, turns and cheats. A new action replaces the forward branch. Restoring pauses AI until Resume.
- Multiplayer restores retain current seats and cheat permissions, reject stale actions and support reconnecting. Manual saves retain match history and checkpoint identity.

## Console and battlefield

- Added `unit stat change U12 armor (6)`. Armor is the minimum defense roll; supported stat values use parentheses.
- Events work through commands. For example, `event spawn army {edge:east,units:{machinegunner:15,civilian:10}}` creates the exact force. Reinforcements accept a player, entry edge or coordinates, and unit composition too.
- Self armies and raiders receive distinct unused faction colors. Vehicles can spawn over corpses without deleting them.
- Coordinate labels retain their screen size at every zoom, with spacing to keep distant labels readable.

## Battle controls and first person

- Escape opens Return to Menu, Settings, Save Game and Save Replay, in that order. Those actions no longer occupy the side panel. Saving a replay keeps recording.
- Added a first-person render-distance setting and scrolling settings content for smaller screens.
- Stabilized first-person fog sampling and visibility texture updates.

## Replays and video

- Timelapse skips animation delays, with playback speeds from 0.25x through 64x.
- Export the whole 2D replay as an H.264 MP4 at a selected speed, resolution (720p through 4K) and frame rate (24, 30 or 60 fps).
- Video export requires FFmpeg with H.264 encoding. The game detects it or lets you select its executable. Encoding keeps the interface responsive; cancellation preserves existing files.

**Compatibility:** network protocol **29** and replay schema **3**. Players must use the same build. Existing saves and historical replays remain supported.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.13.4...v0.13.5
