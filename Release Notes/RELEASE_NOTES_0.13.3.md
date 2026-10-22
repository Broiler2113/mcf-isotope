# Isotope 0.13.3

## Console and manual

- The console has an almost-black background, separators between command outputs, and clickable suggestions that explain commands. Suggestions appear after you start typing.
- Both the console and manual can be moved and resized while the battlefield remains interactive.
- `inspect` starts a click tool that reports units, vehicles, their stats and the selected tile. `spawn unit <type> <player>` and `spawn vehicle <type> <player>` keep placing the selected entity until **Escape**.
- Unit and vehicle lists use permanent **U** and **V** IDs. `ids on` displays those IDs above battlefield entities, and commands accept the displayed IDs.
- `units <player> status` and `vehicles <player> status` show counts by type, including alive/dead totals for that player and the entire board.
- The manual includes every command and subcommand from the console's command catalog.
- Enabling cheats in the lobby also checks the host's gameplay permission. The host can still change individual permissions afterward.

## Events, AI and player controls

- `event list` shows active effects and pending warnings with stable references. `event spawn` opens an editor and placement tool; `event edit` edits a selected effect; `event remove` removes one by reference or battlefield click.
- Event editors expose the parameters that each effect actually supports, including area, location, duration and landing properties. Event fire and old minefields are managed as aggregate effects. Removing an effect does not reverse damage it has already dealt.
- `event trigger <type>` immediately triggers an eligible event using its normal random selection. Automatic event enablement, interval, guaranteed occurrence and individual event types can also be adjusted.
- Host commands `ai pause <player>`, `ai resume <player>` and `ai step <player>` control individual AI players. Step allows the active AI one decision or action and leaves it paused afterward. Pauses survive saves and rejoining; loading with cheats disabled releases them.
- `vehicle durability <ID>` restores a living vehicle's hull. An optional value sets a specific durability; component repair commands remain available.
- `kick <player>` disconnects a human guest. `ban <player>` also blocks that player's saved reconnect identity for the current hosted session. These commands cannot target AI players or the host.

## Holdout and first person

- Wave multipliers now use the **combined current surviving soldier count** of the defending team, excluding drones and corpses. Unit point costs no longer reduce the requested enemy count.
- With the default multiplier, wave 12 against 161 surviving defenders targets **290 enemies**: 161 × 1.8, rounded.
- The count is fixed when a wave is announced. The objective panel, combat log and `wave status` show the count, multiplier, target and actual landing. Landing searches expand beyond a narrow strip when needed, and insufficient space is reported.
- Older saved battles use the corrected sizing for future waves; historical replays retain their original wave rules.
- Restored the previous corpse sprite size in first person.

**Compatibility:** network protocol **27**; all players must use the same release. Existing saves and replays remain supported.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.13.2...v0.13.3
