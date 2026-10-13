# Isotope 0.9.9

## Controls

- Added keyboard shortcuts to unit, group, passenger, drone, and vehicle action menus. Each button shows its shortcut, and keys follow the same availability rules as clicking the buttons.
- Actions with multiple choices, such as Build, Repair, Board, and Launch Drone, open a numbered picker. Use 1–9 or the numeric keypad to choose; longer lists have pages.
- **Ctrl+Z** now undoes a game action outside drawing mode, and **Ctrl+Shift+Z** redoes it. In drawing mode, Ctrl+Z continues to undo your last stroke.
- **Tab** opens the initiative overlay, replacing 1 and numeric keypad 1.
- Newly launched drones are automatically selected for the player who launched them.
- Fixed stale group selections carrying over after selecting a single unit or vehicle.

## Replay controls

- **Space** plays or pauses a replay.
- **Left Arrow** steps back, and **Right Arrow** steps forward.

## Keybind settings and map editor

- Added a **Keybinds** settings tab with separate **In-game shortcuts** and **Map editor shortcuts** sections, using the existing game UI style.
- Rebind action keys, camera movement, replay controls, and existing editor shortcuts. Changes are saved between sessions, and shortcut labels update to match.
- Conflicting bindings show a warning and preserve the previous binding. Keys can still be reused in separate contexts, such as gameplay and the map editor.
- Added a reset to default bindings. The editor’s **F1** shortcut and keyboard-shortcut menu entry open its keybind settings directly.
- Gameplay shortcuts respect text fields, dialogs, and menus so typing or changing settings does not trigger an action behind them.

## RLM training

- Added time budgets for evaluations that could hold up training for hours: five minutes for routine evaluations and fifteen minutes for promotion tests by default. Training resumes when the budget is reached; an incomplete promotion test cannot replace the champion.
- Stop and Pause requests now interrupt evaluations.
- The dashboard shows evaluation time remaining and more accurately reports completed games, including promotion games, without combining results from separate attempts.
- Promotion and routine evaluations no longer run back-to-back at the same training update.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.9.8.2...v0.9.9
