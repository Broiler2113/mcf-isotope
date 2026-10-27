# Isotope 0.14.4.1

## Fixes

- On Mac, a copy downloaded in a browser no longer shows "mcf_visuals.dylib Not Opened" at launch. The game clears the download flag from its own verified C++ library, so acceleration starts without administrator rights.

## Cheat console

- New `undo` and `redo` commands. `undo` takes back the last console command, as long as nothing else happened after it; `redo` puts it back. Like `game step back`, they are for the host and pause AI until Resume.

## Performance check

- New FPS benchmark: `godot --path . --script res://tests/bench/run_fps_battle.gd` plays the same 400-soldier AI battle with C++ acceleration on and off, with a live FPS readout and a side-by-side table of average FPS, 1% lows, worst frames, hitches and battle time. `--scene large` picks a smaller battle.

## Compatibility

- Network protocol **32** and replay schema **3** are unchanged from 0.14.4; existing saves and replays remain supported.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.14.4...v0.14.4.1
