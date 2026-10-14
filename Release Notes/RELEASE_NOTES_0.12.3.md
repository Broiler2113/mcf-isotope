# Isotope 0.12.3

## Interface

- Reverted the change that made every popup draggable and resizable. Menus use their original layout; the existing chat, combat log and sidebar controls remain.
- Multi-Select, Ruler, Heightmap and Camera are back in the right sidebar. Drawing alone opens from a button in the top-left corner.
- Time-of-day selection is unavailable for Bunker, Station and Asteroid maps in the lobby generator and map editor. It remains available for Town and Field maps.

## Combat and destruction

- Shield Push can target adjacent glass for 1 AP. Ordinary glass shatters; armored glass retains its 4+ hold roll. Broken panes produce glass shards.
- Firing flashes and bullets start only after attack and defense dice finish. Local games, multiplayer and replays use the same presentation order.
- Vehicles driving through walls now produce chunks matching the wall's material and appearance, thrown away from the impact.

## Multiplayer

- Protocol 14 adds glass targets to Shield Push and wall debris to vehicle ramming. All players must use 0.12.3; multiplayer is incompatible with 0.12.2 and earlier releases.

## Validation

- 15 regression suites covering the fixes, combat, lighting, editor and lobby controls, serialization, lockstep and the existing deterministic match trace.
- Rendered UI checks for restored sidebar tools, the Drawing panel, fixed Settings layout and glass targeting.
- Five direct multiplayer scenarios: asymmetric deployment, mirrored deployment, leaving, town maps and unreadying.
- Small and medium battle benchmarks verify host/client agreement, matching saves and replays, and zero resyncs. The medium benchmark retains its action count, dice trace and survivors; its expected state and effects hashes include the new wall chunks.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.12.2...v0.12.3
