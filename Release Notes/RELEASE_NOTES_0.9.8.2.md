# Isotope 0.9.8.2

## Replays

- Added a scrollable **Bookmarks** panel for round starts, each player’s turn, and random-event warnings and landings. Click an entry or use the previous/next bookmark buttons to jump there.
- Greatly reduced replay seek times on large maps. A giant-map test with 400 soldiers improved from 26–51 seconds to 0.2–0.7 seconds per jump; actual times depend on your machine and the match.
- Dragging the timeline now seeks once when released. Selecting a destination during playback finishes the current animation promptly and jumps to the latest selection.
- Blood, vehicle tracks, and floor damage remain visible after jumping through a replay.
- Fixed offline undo and redo actions missing from recorded replays.
- Older replays gain bookmarks and faster seeking automatically on first open. This one-time upgrade can take longer than a normal jump; subsequent opens reuse the saved result. If the upgrade cannot be saved, it remains available for the current session without replacing the original file.
- Updated RLM replay imports to accept the new replay format.

## Gas and random events

- Random-event warnings now appear at the beginning of a round, including the first round, so players see them before taking actions. The event still happens after the next player ends their turn.
- Random-event intervals count full rounds. Reopening a saved match no longer repeats a warning already checked for that round.
- Gas uses a more uniform white, pixelated texture.

Multiplayer participants must all update to 0.9.8.2 because round-start event scheduling changes the shared simulation. Existing saves remain readable. Old replays whose actions or dice no longer match the current rules are left unchanged rather than migrated.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.9.8.1...v0.9.8.2
