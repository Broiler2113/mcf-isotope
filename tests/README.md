# Regression harness

## Layout

Suites live in a folder per system; `bash tests/run_all.sh` runs every `run_*.gd` in each
folder, so a new suite only has to be put in the right place:

| Folder | What it holds |
| --- | --- |
| `combat/` | shooting, blasts, the flamethrower and fire, bodies and captives, shields, smoke and gas, furniture, digging, movement |
| `vehicles/` | tanks, shuttles, borgs, drones and drone stations |
| `ai/` | how the scripted AI behaves |
| `events/` | random events and match modes (Capture & Hold, Holdout, waves) |
| `fog/` | sight, fog of war and what each side's screen shows |
| `cheats/` | command grammar, permissions, click tools, event editing, save/replay and network authority |
| `mapgen/` | the random-map generator and the lobby's maps |
| `editor/` | the map editor and its tools |
| `ui/` | the battle screen, dice, menus, board art, lighting, effects |
| `files/` | saves, replays, bookmarks and the game folders |
| `net/` | lockstep, the wire codec, rejoining, network rules |
| `audio/` | sounds |
| `perf/` | the reference AI match and incremental-state checks |

The split suites stand on `SuiteBase.gd` (`ck()`, `run()`, exit code). The learned-AI and
native-policy tests stay at the top level because `rl/` and CI call them by path, as do the
two-process network scripts (`net_*.gd`, `run_net_*.sh`) and `check_scripts.gd`.

`audio/run_audio.gd` checks sound lifecycle timing, visibility, fixed voice pools, SAM
assets, dice, Audio settings and replay cue order. `bench/run_audio_bench.gd`
stress-tests real Giant-board AI combat. Offline catalog/build-gate tests are
`python3 tools/audio/test_catalog.py`; asset-generation details are in
[audio/README.md](../audio/README.md).

Headless runs, no engine window (the lobby check builds its scene without
rendering it), no assets required.

The 0.13.3 console checks are `cheats/run_console_followup.gd`,
`cheats/run_event_management.gd`, `ui/run_console_windows.gd` and
`events/run_live_wave_counts.gd`. They cover stable IDs, counts and statistics,
event editing and replay, single-decision AI stepping, host permissions, and
the combined surviving-soldier wave formula. `bash tests/run_net_cheats.sh`
checks real host/guest event edits and AI authority. `bash tests/run_net_ban.sh`
checks session bans, blocked reconnect identities and an unrelated player
joining from the same address.

`xvfb-run -a godot --path . --rendering-method gl_compatibility --script
res://tests/render_console_followup.gd` exercises actual window dragging,
resizing and battlefield ID pixels, and writes console/manual/event-editor
screenshots to `/tmp/isotope-0133-*.png`.

`cheats/run_fix11.gd` and `ui/run_fix11.gd` cover named checkpoints, whole-match
history, exact event forces, independent colors, corpse-safe vehicle placement,
the battle menu, replay timelapse and network restore authority.
`files/run_video_encoder.gd` verifies real H.264 output and safe cancellation when
FFmpeg is installed. `tests/render_fix11.gd` needs a display (or Xvfb) and FFmpeg;
it checks first-person fog stability and produces 1x/4x MP4 exports under `/tmp`.

`xvfb-run -a godot --path . --rendering-method gl_compatibility --script
res://tests/render_label_zoom.gd` compares actual ID and coordinate glyph pixels
through pinch zoom from 0.12x to 2.5x, including fractional camera positions,
unit and corpse IDs, and vehicle IDs. The text must retain its screen size and
shape while its anchor follows the map.

```
bash tests/run_all.sh            # verify
bash tests/run_all.sh --update   # re-baseline after a deliberate rule change
```

**`check_scripts.gd`** loads every `.gd` in the project and fails on any that will
not parse. It exists because `godot --check-only --script X.gd` cannot see the
`Ui` autoload, so every scene script "fails" under it for no reason; here the
project is actually running, so autoloads and global classes are present.

**`perf/run_headless.gd`** plays a fixed-seed AI-vs-AI match on the fixed map in
`TestSupport.gd` and writes a full trace — every intent, every log line, every
dice event, every death, plus a final board digest — then diffs it against
`tests/baseline/headless_trace.txt`.

The trace is **not** expected to stay byte-identical across deliberate rule
changes; most milestones move it on purpose. Its job is to catch the changes
nobody intended. When it moves, re-baseline with `--update` and say in the commit
message *which* rule moved it and why. A trace that moves for a change that
should not have touched behaviour is the signal this harness exists for —
`GAME_SPEC.md` §27.2 explains why (the AI is order-sensitive, so a refactor can
produce the same legal moves in a different order and deploy the army
differently).

**`net/run_lockstep.gd`** builds two independent matches from the same map and seed,
drives one as the host and replays its intents — **through `IntentCodec`, so a
field dropped on the wire is caught** — plus its recorded dice into the other.
After every single action it asserts three things:

1. the two board digests are identical;
2. the client consumed exactly as many dice as the host supplied;
3. the client never fell back to its own RNG.

(2) and (3) are the checks `AUDIT.md` §2.3 found missing: `DiceService` used to
empty its scripted queue and silently start rolling locally, so a divergence
became permanent and invisible. `DiceService.scripted_remaining()` and
`fallback_rolls` exist for this and are diagnostics only — they change no
behaviour.

**`net/run_codec.gd`** builds one of every `Intent` subclass with distinctive values,
round-trips it through `IntentCodec`, and compares *every* script property. It
also fails if a subclass on disk has no sample, so a new intent cannot be added
without noticing the codec. This exact class of bug has now shipped twice —
`MoveIntent.carry_drop` (#100) and `DigIntent.dirt_a/dirt_b` (`AUDIT.md` §2.2) —
and neither compiles wrong nor shows up in an AI match, because the AI never
chooses the field by hand.

**`combat/run_player_actions.gd`** lockstep-checks the things a *player* does and an AI
never does: digging with hand-picked dirt cells, a group move order, undo/redo,
and refusing an end-turn or undo from a side that is not acting. Same
host/client protocol as `net/run_lockstep.gd`, with per-action board comparison.

**`mapgen/run_lobby_maps.gd`** builds the real lobby scene and asserts that every map on
disk — shipped in `res://src/data/maps` and saved by the editor in `user://maps` — is a row
in its dropdown, that each row points at a file that still reads back as a map, and
that rescanning the folders neither loses maps nor doubles them. It also drives the *Random
map* row: one zone per slot, "Players" adding and removing slots, "Units per side"
growing the zones, no file path on start, and *Save as Map* landing in `user://maps`. It exists because
"my saved maps are not in the list" has now been reported twice: the first cause
(the app rename moved `user://`) was fixed in code nothing checked.

**`mapgen/run_mapgen.gd`** holds the random-map generator (`MapGen`, the lobby's *Random map*)
to what the lobby promises, over every style and size, 2–6 sides, big armies and each
mechanic switched off: the same seed builds the same map byte for byte; one zone per
side, all the same size, big enough for the squad (`MapGen.zone_need`) and apart from
each other — or else the map must have grown; every zone reachable on foot on the real
board; toggles honoured. Civilians must start the match **asleep**: every zone cell is
filled with a soldier, one action is resolved, and not a single civilian may have woken.
It then plays a few AI-vs-AI rounds on each style.

**`combat/run_combat_safety.gd`** covers three rules that only show up in play:
a line of fire that starts or ends *off the board* (a soldier riding inside a
vehicle sits at −9999, and every walker along a ray used to march off the grid
from there — "Out of bounds get index '-509898'"); the AI anti-tank refusing a
charge whose blast — on any of the six die rolls, shortfall included — would
catch himself or a squadmate; and the shot cosmetics: one casing per round fired,
a second burst from the same cell landing in its *own* spots, and one
"who shot whom" lane per attack.

**`ui/run_ui_assets.gd`** asserts every texture the interface skin is built from
comes back as an *imported* resource rather than a raw disk read. The skin used
to be loaded with `Image.load`, which the engine warns "will not work on
export" — it survived only because `file_exists()` answers "no" inside a `.pck`
and the code fell through to a backup branch. The run also pins the promise in
`HOW_TO_REPLACE_INTERFACE_TEXTURES.txt` §4: a PNG dropped in on top of an
imported one is still read straight off disk, so reskinning from source needs no
re-import.

**`ai/run_ai_conduct.gd`** watches how the AI *behaves*, not what it computes. It asserts
the AI never spends an action point on a shot it cannot land (cover can push the
required roll to 7, which a d6 never shows — range alone used to be the only thing
checked); never drives a tank over its own infantry; never walks a unit back to
where it stood a turn ago; and that an idle vehicle is picked up by the forced pass
and given a real order, even when the infantry has already met its activity quota.

`ai/run_ai_conduct.gd` also covers the planner keeping soldiers out of a friendly tank's
driving lane, and the anti-tank opening on armour rather than on a closer, softer
infantry target. `combat/run_combat_safety.gd` also covers a tank's tracks reporting the
tiles they flatten, boarding not refunding a vehicle's spent AP, and a civilian's
fire producing the same who-shot-whom lane as anyone else's.

**`editor/run_mirror_stamp.gd`** builds the real placement scene, stages one of every kind
in the host's zone and stamps the mirrored formation, asserting that infantry *and
every vehicle* cross over and land fully inside the guest's deployment zone. It
exists because the mirror mapped a footprint's top-left corner to where its
bottom-right belongs: harmless for 1×1 infantry, fatal for a 3×3 tank, and a coin
toss for a 2×2 shuttle — which is exactly the "tanks don't transfer, and shuttles
too sometimes" the report described.

**`vehicles/run_modular_tank.gd`** covers the modular armour milestone end to end: the four
independent pools and their starting values, each zero taking away exactly one
capability, the aimed roll's +1 (an aimed Hull shot cannot miss), the cascade skipping
destroyed components and never returning "nothing hit", overkill carrying into the Hull,
the fixed-target sources (mines, miner, personnel mines no longer touching vehicles),
crew being risked only by Hull hits, Engineer repair with its cap and ownership rules,
capture preserving component state, and finally a live anti-tank gunner wearing a tank
down through the real resolver.

`vehicles/run_modular_tank.gd` also covers the left/right track split (driving needs both,
turning needs either), the flank rule deciding which track a shooter can reach and the
gun being hidden from behind where it points, and the two armoured materials — a wall
that shrugs off eight blasts beside it but dies to one on top, and glass that holds on
4+.

**`combat/run_mines_and_corpses.gd`** covers batch 12's rules that only show in play: a captor's
death frees the captive; bodies under a vehicle's tracks stay (and cannot be picked up
while the hull sits on them); a personnel mine laid under a standing unit kills it at
once while an anti-vehicle one stays armed; known mines shape the move flood for the
player, the resolver and the AI alike (a 1-wide corridor with an own mine is cut off,
an unknown enemy mine is not, a revealed one is); the AI sapper actually lays a field and
never walks a unit onto its own mine; and cosmetics bounce off the board edge.

**`fog/run_sight_lines.gd`** and **`editor/run_eraser_and_resize.gd`** cover batch 13's rules that only show in play: sight is unlimited in
range and direction and stops only at walls and closed airlocks (units, corpses and hulls
never block it), a crewed vehicle sees from every hull cell and an empty one is blind, a
body in an airlock holds the doors open, the purchase eraser refunds and never touches
mirrors, and the map editor resizes without wiping and flood-fills inside walls.

**`vehicles/run_shuttle.gd`** covers the seated shuttle end to end — seat choice, the driver paying
1 AP per 15 cells with a banked remainder, passengers riding along, shooting from and into
seats (+1 hull cover, no grabbing), a heavy hit killing the passenger on the landing cell
while the others roll, a body holding its seat until pulled out, a station mounted in a seat
that rides along — and the AI boarding, flying and firing from seats.

**`vehicles/run_borg.gd`** covers the borg: boarding and exiting, the operator's numbers (3 AP,
9 move, 12/4 gun, −2 armour, abilities kept), the engineer keeping its gun and building in
batches that expire with the round, fire immunity, trenches refused, AV mines hurting the
hull, destruction (operator dies; explode or wreck), a dead operator being pushed out by the
next boarder, and the AI climbing into an empty borg.

Batch 17's rules that only show in play are checked across the system suites (see the table at the end): boarding a shuttle or a
borg is free and works at 0 AP; a diagonal flame jet that meets a straight wall still burns all
six cells (the side of the splash the wall cuts short hands its cells to the other side); a
neutral civilian shoots a player's bought civilian instead of retreating from its lane; every
vehicle kind leaves a wreck and an explosion scorches the floor; and a group order whose mover
was cut off by a squadmate lands on the nearest reachable cell instead of standing still.

**`combat/run_group_move.gd`** covers the group order planner (`GroupMovePlanner`): every selected
unit moves (the middle of a blob and the tail of a corridor column used to be dropped),
each lands exactly on the cell its preview showed, a blob sent far away keeps its shape
instead of sliding to the map edge, and a *Tactical Move* lines the squad up behind
sandbags facing a visible enemy — or facing every side when fog hides the enemy.

The "team session" batch's checks (table at the end) cover an anti-tank blast at a cell
holding a unit gets the same firing-line, wall and range checks as any other cell (the
old shortcut let the AI fire through passengers at any angle and roll hopeless 7+
checks); the civilians slider thins a prepared map evenly; deploy bands follow the zone
picked in the lobby; generated maps remember their environment and pick its tiles; the
eraser clears pixels exactly where it went; glass shards stop at walls; the new lobby
settings (civilians, AI speed) reach guests; chat text cannot inject markup.

**`run_net_match.sh`** is the only run that proves multiplayer works: it starts **two
Godot processes** on localhost — `net_host_*.gd` and `net_guest_*.gd`, both built on
`NetSmokeBase.gd` — and drives the real scenes through ENet: lobby (seating, colour and
slot requests, rule sync), placement (budgets from the lobby, live placement, the host
deploying its AI slot, the mirrored auto-stamp), and battle (the host's shot at the guest
with **both** screens waiting for the other's Roll, the host driving the AI side, and the
board digests agreeing at the end of the round). It runs twice, asymmetric and mirrored,
and needs `NetworkSession.DEFAULT_PORT` free.

## Scope

The [Fix-8 PDF review](FIX8_REVIEW.md) maps the owner's 33 requests to the current
implementation and its checks. The added suites cover cosmetic winter, editor
walkthroughs, drawing sharing/undo, borg demolition/unwelding, drone-detonation undo,
raider landings and damaged furniture after loading a save.

`render_first_person.gd` is a manual Compatibility-renderer check, outside the
headless suite. Run `godot --path . --script res://tests/render_first_person.gd`
(or prefix it with `xvfb-run -a` on a server). It renders furniture, a damaged bed,
outdoor fortifications, winter and vehicles, saves `/tmp/isotope-first-person-*.png`,
and checks that camera movement leaves the simulation unchanged. Add, for example,
`-- furniture vehicles` to render only those scenes.

`bench/run_first_person_bench.gd` profiles entry and selected CPU update phases on a
furnished 124×104 winter town with 200 soldiers. Run it with `godot --headless --script
res://tests/bench/run_first_person_bench.gd`; add `-- --procedural` to measure the
material-generation path instead of loading the baked textures. These are CPU
measurements, not GPU frame rates. Verify the baked images against their sources with
`godot --headless --script res://tools/art/build_first_person.gd -- --verify`.

**`files/run_replay_seek.gd`** compares frame selection with the original forward scan at
every boundary, including old recordings without frames and recordings edited in
place. It also seeks a recorded match forwards and backwards and compares its full
board and rules with replaying from the beginning. It covers dense checkpoints on a
149×119 board, undo/redo recordings, settled effects, and the maximum action gap.
`-- --bench` measures frame lookup
in a 60,000-action recording; timings are informational, never a pass/fail threshold.

**`files/run_decal_sync.gd`** compares the far-map image byte for byte with the original
decal traversal. It covers mixed gore/props additions, idle updates, off-board
particles, unsupported kinds, eviction and replay resets, and checks that neither
simulation state nor particle data changes. `-- --bench` measures adding one particle
after 68,000 have settled. Particle amounts, limits and blend order remain the same.

**`files/run_match_lifetime.gd`** observes destruction through weak references after repeated
recorded matches and learned-AI fallback sessions close. It catches callback/reference
cycles that retain the match's board, while also checking that recorded data still
replays and fallback intents are forwarded exactly once.

None of these runs is evidence that the game *plays* correctly. They are evidence
that it does not crash, does not deadlock the AI, and does not desync. Play the
real game as well.

`run_rl_learning.gd` verifies round-clock discounting across a pool response, live public hazards without omniscience, and network-recorded replay determinism. `rl/test_learning_environment.py` covers spatial batches, demonstration imports/updates, checkpoint migration, paired model selection, and real head-to-head protocol routing.

`run_rl_giant_defense.gd` checks that a visible tank's drive lane reaches the policy, anti-tank soldiers survive actor sampling, large armies must spend AP before ending, and hidden or disabled tanks create no drive-lane signal.

### 0.9.8

- 0.9.8's own checks (table at the end): neutral shooting priority, tunnel width/sealing, persistent editor door/accent/decal data, room presets, map expansion, original-board and clock save/load, replay walk endpoints, defense speeds, spectator authority, dirt autotiling, and track layering.
- `ui/run_ground_backdrop.gd`: camera setter synchronization; run under a renderer for pixel coverage checks.
- `run_net_spectators.sh`: host plus two spectators through lobby, deployment, and live battle, including private spectator drawings.
- `run_net_kick.sh`: host kicks a seated guest, reopens the seat, and guest returns to the menu.

Its follow-up's checks (table at the end) cover off-grid decal strokes/undo/rotation, corpse snapping, contextual material controls, town border roads, gas contact and fog-off visibility, one-player-turn event warnings and nonoverlapping barrages.

`events/run_random_events.gd` also checks round-opening warnings (including the first round),
multiplayer notifications, neutral slots around the round boundary, interval counting,
and replay seeking across openings that consume no dice.

**`files/run_replay_bookmarks.gd`** checks opening/round/player-turn/event indices, excluded
combat logs, shared event-prefix matching, lazy migration and second-load reuse,
failed writes, navigation boundaries, and identical UI jumps from bookmarks/slider.

For an end-to-end large-match seek benchmark, run
`godot --headless --script res://tests/bench/run_replay_seek_bench.gd`.
It reports actual seek times and catch-up counts on a 149×119 map with 400 soldiers;
wall-clock timing is informational rather than a hardware-dependent test assertion.

`rl/test_evaluation_scheduling.py` checks whole-suite time limits, Stop/Pause during socket waits, champion preservation, partial-game log retention, promotion retry tallies, and real Godot collection/PPO after an evaluation timeout.

### Action hotkeys and keybinding settings

`godot --headless --script res://tests/run_hotkeys.gd` exercises the shared menu
buttons and context bindings, disabled/absent actions, collision fallback, numbered
choices (including pages and keypad digits), real build/repair/boarding/station
pickers, drone selection for local/network owners, undo/redo and drawing isolation,
replay transport, Tab with GUI focus, editor rebinding, persistence and conflicts.
The Keybinds tab uses separate In-game shortcuts and Map editor shortcuts pages.

### Dynamic lighting and group previews

The remaining-bugs checks (table at the end) cover direct flame immunity, vacuum momentum and save/load,
shield debris sweeping, decal-memory updates, pressure-door interlocks, paired furniture,
shelf contents and real map corpses. The remaining-generation checks (now in `mapgen/run_generation.gd`) cover residential
restrooms and lighting, window floors, furnished parks, station engineering/solar arrays,
production workstations and paired exterior doors across seeds and sizes.
`ui/run_screens_walkthrough.gd` checks Tools/Drawing, popup movement and resizing, deployment sidebar
geometry, Before/After lighting and editor item preservation. Run it with `xvfb-run -a`
instead of `--headless` to exercise the actual renderer and save screenshots in `/tmp`.

The headless reference trace was updated for direct flame immunity: the first divergence
is the enemy flamethrower surviving a jet. Its subsequent turns change the battle trace.
The three benchmark references also change intentionally: their generated towns now use
the new street layout, parks and restrooms, so the initial boards and subsequent battles
differ. Host/guest agreement, zero resyncs, save/load and replay agreement remain required.

`ui/run_lighting.gd` covers incremental light/occluder updates, glass transmission,
hidden-source filtering, local-only rendering, flash timing, the off-by-default
setting, editor preview/exit, and cooperative group previews with identical orders.
`ui/run_light_fixtures.gd` covers mounted/freestanding lights, shooting, support loss,
explosions, save/map/replay round trips, presets, editor layering and generation.

`xvfb-run -a godot --script tests/render_lighting.gd` requires an actual Compatibility
renderer. It compares rendered shadows before/after demolition, ambient restoration,
and 16 versus 80 overlapping light sources. Headless simulation tests cannot verify
GPU pixels. Images are written to `/tmp/isotope-lighting-*.png` for inspection.

`tests/bench/run_group_preview_bench.gd` reports cooperative preview costs for 20, 100, and 200 selected soldiers on a giant map. `tests/bench/run_lighting_coverage.gd` reports generated lighting coverage and generation time on small and giant maps. Timing is hardware-dependent; these are informational benchmarks. Colossal generation now allows 5 seconds (the prior 4-second budget plus 1 second for the fixture coverage pass).

The 0.12.2 follow-up's checks (table at the end) cover shield strikes against ordinary and armored glass,
invalid targets and AP costs, their codec/lockstep behavior, and wall chunks from vehicle
ramming (including the original wall texture). It also checks environment-specific time
choices and drives local, replay and network shot presentation through manual attack and
defense rolls, asserting that flashes and bullets start afterward. `ui/run_screens_walkthrough.gd`
checks the restored sidebar tools, Drawing button, fixed Settings popup, retained log
controls, editor time choices and clicking a glass target with Shield Push.

### Reported issues (0.12.5)

The 0.12.5 reported-issue checks (table at the end) cover raider composition settings and serialization,
old minefields across all environments, additional station solar arrays, cosmetic
undo/redo, terrain rebuild budgets, camera-anchored and additive selection,
vehicle impact timing, queued network actions and the rebindable fullscreen shortcut.
The guest Town network scenario also issues a real menu/click move order after
camera pan/zoom and checks the exact destination and acknowledgement behavior.

`xvfb-run -a godot --script res://tests/render_reported_issues.gd` checks drawing
colors under night tint and dynamic lighting, plus fire/corpse draw order. Images
are written to `/tmp/isotope-drawings-night.png` and `/tmp/isotope-fire-layering.png`.

`godot --headless --script res://tests/bench/run_explosion_bench.gd` reports
impact-frame texture rebuilding time. An optional argument after `--` may point to
an earlier `TerrainTiles.gd` source for comparison. Timings are informational.

### Reclaiming a disconnected guest seat

`net/run_reclaim.gd` checks identity matching, occupied/unknown/ended seats, declining,
round-boundary queues, and the message permissions of waiting connections.
`bash tests/run_net_reclaim.sh` runs a host and two guests through real ENet:
one guest leaves, declines an offer, rejoins with a different peer ID, accepts,
and receives the current board at the next round. Both guests compare their
complete state and mode/event rules with the host. The returning guest also
checks the restored RNG position, host settings changed during its absence,
and the dice-animation cursor. A real shot then requires the returned player
to roll defense, followed by a legal turn-ending intent from its new peer ID. `MCF_RECLAIM_SOLO=1` covers the last guest
leaving; `MCF_TEST_RELAY=127.0.0.1:PORT` runs the same flow through a local relay.
The harness uses temporary user-data directories, so it cannot overwrite a
player's remembered match. Seat reclaim was introduced in network protocol 18; this release uses protocol 19
for the updated combat and spawn rules. All peers must use the same release.

### Current-scale performance audit

The original `small`, `medium`, and `large` configurations and behavioral
references remain unchanged. Their `units` field is **per side**, so `large`
already has 150 soldiers per side. `giant`, `giant_capture`, and `giant_holdout`
start with 200 per side, tanks, furniture, Tactician AI, fog memory, lighting CPU
updates, and the complete selected random-event pool. Map and mode eligibility
still apply (for example, Bounty only occurs in Capture & Hold). Holdout adds a
separate wave side to two allied defending armies.

```sh
godot --headless --script res://tests/bench/run_bench.gd -- modern --reps 2 --timings /tmp/current.json
python3 tests/bench/compare_timings.py tests/bench/baseline-current.json /tmp/current.json
godot --headless --script res://tests/bench/run_bench.gd -- event_matrix
```

The event matrix isolates each of the ten entries on the furnished giant Capture
map. Its Reinforcements fixture uses a cheaper second army so the event is
eligible. These short runs exercise announce/land handling, guest agreement,
save/load, and replay; the three main scenes measure complete AI turns.

`--update` writes hashes only if repeated runs agree and guest, save, replay, and
cosmetic invariants pass. It preserves unselected scene references. Timing
reports contain each repetition and the machine/engine identity. The comparison
uses medians, flags increases above 1.5x and 20 ms, and remains informational.
Different machines, configs, or behavioral signatures are rejected as incomparable.
Use an otherwise idle machine for a useful release-to-release comparison.

Lighting measurements call the shipped `LightManager.update_view()` and include
occluder indexing, emitter selection and texture/multimesh preparation. They are
CPU measurements with a headless renderer, not GPU frame-rate measurements.
Fog-memory timing calls the same board/decal memory updates used by `Main`.
`total` covers the host action loop; guest simulation, save/load, and replay are
reported separately. Startup/map generation and opening initiative precede that
loop. The old timing columns retain their meanings; memory and lighting are
additional columns in the JSON report and console output.

To exercise the warning path with a real measured slowdown, collect `small`
reports with and without `--inject-fog-delay-ms 3`, then compare them. The injected
wait changes no intents, rolls or hashes. `python3 tests/bench/test_compare_timings.py`
checks warning thresholds and machine/workload compatibility.

The player-report regressions in `run_player_reports.gd` cover local smoke with fog
off, capture/release targeting (including Heavy Infantry through the combat UI),
shuttle drone stations, vehicle fire protection and exits, universal borg weapons,
corpse blocking/extraction, spawn exclusions, wave cohorts, saved chat/combat log,
and intermediate movement visibility. `render_reported_issues.gd` checks actual
Compatibility-renderer layering and excludes explosion fire flashes from space.
Run that script with a display (or `xvfb-run -a godot --path . --script
res://tests/render_reported_issues.gd`). `native/policy/test_manifest.py` checks
registration for all four supported desktop targets and rejects missing libraries.

## Where the release-named suites went

Until 2026-10 many suites were named after the release or playtest that added them. Their
checks now live with the system they test:

| Old suite | Now in |
| --- | --- |
| `run_audit0128.gd` | `combat/run_bodies.gd`, `events/run_match_modes.gd`, `vehicles/run_drone_stations.gd`, `net/run_net_rules.gd`, `events/run_event_rules.gd` |
| `run_batch011.gd` | `combat/run_shooting.gd`, `ui/run_battle_screen.gd`, `ui/run_dice.gd`, `files/run_game_files.gd`, `editor/run_editor_tools.gd`, `ui/run_board_art.gd` |
| `run_batch0111.gd` | `ui/run_board_art.gd`, `ai/run_ai_rules.gd`, `combat/run_blasts.gd` |
| `run_batch0112.gd` | `fog/run_fog_screens.gd`, `vehicles/run_drone_stations.gd`, `events/run_event_rules.gd`, `ui/run_board_art.gd`, `ui/run_dice.gd` |
| `run_batch0113.gd` | `fog/run_fog_screens.gd`, `ui/run_menus.gd` |
| `run_batch012.gd` | `events/run_match_modes.gd`, `events/run_event_rules.gd`, `ui/run_menus.gd`, `files/run_game_files.gd` |
| `run_batch0121.gd` | `mapgen/run_generation.gd`, `ui/run_board_art.gd`, `files/run_game_files.gd`, `combat/run_blasts.gd`, `ui/run_effects.gd`, `combat/run_flamethrower.gd`, `events/run_match_modes.gd`, `editor/run_editor_tools.gd`, `combat/run_furniture_rules.gd`, `combat/run_shooting.gd`, `ui/run_battle_screen.gd`, `combat/run_digging.gd` |
| `run_batch0122.gd` | `combat/run_blasts.gd`, `combat/run_furniture_rules.gd` |
| `run_batch092.gd` | `combat/run_shooting.gd`, `mapgen/run_generation.gd` |
| `run_batch093.gd` | `mapgen/run_generation.gd`, `ui/run_board_art.gd`, `combat/run_bodies.gd` |
| `run_batch094.gd` | `combat/run_bodies.gd`, `events/run_event_rules.gd`, `mapgen/run_generation.gd`, `ui/run_board_art.gd` |
| `run_batch098.gd` | `editor/run_editor_tools.gd`, `mapgen/run_generation.gd`, `ai/run_ai_rules.gd`, `ui/run_battle_screen.gd`, `ui/run_board_art.gd` |
| `run_batch13.gd` | `fog/run_sight_lines.gd`, `editor/run_eraser_and_resize.gd` |
| `run_batch17.gd` | `vehicles/run_vehicle_rules.gd`, `combat/run_flamethrower.gd`, `combat/run_shooting.gd`, `ai/run_ai_rules.gd`, `combat/run_movement.gd` |
| `run_batch_zones.gd` | `combat/run_shooting.gd`, `vehicles/run_vehicle_rules.gd`, `vehicles/run_drone_stations.gd`, `ui/run_battle_screen.gd`, `files/run_game_files.gd` |
| `run_corpse_drop.gd` | `combat/run_corpse_drop.gd` |
| `run_followup0122.gd` | `combat/run_shield_rules.gd`, `vehicles/run_vehicle_rules.gd`, `files/run_game_files.gd`, `ui/run_battle_screen.gd` |
| `run_followup098.gd` | `combat/run_smoke_and_gas.gd`, `fog/run_fog_screens.gd`, `events/run_event_rules.gd`, `mapgen/run_generation.gd`, `editor/run_editor_tools.gd` |
| `run_holdout_solo.gd` | `events/run_holdout_solo.gd` |
| `run_issues6.gd` | `ui/run_menus.gd`, `combat/run_shooting.gd`, `ui/run_effects.gd`, `ui/run_battle_screen.gd` |
| `run_issues_fix6.gd` | `combat/run_shooting.gd`, `audio/run_battle_sounds.gd`, `combat/run_smoke_and_gas.gd`, `combat/run_blasts.gd`, `combat/run_shield_rules.gd`, `combat/run_digging.gd`, `ui/run_effects.gd`, `ui/run_battle_screen.gd` |
| `run_ldf_accent.gd` | `ui/run_ldf_accent.gd` |
| `run_player_reports.gd` | `combat/run_smoke_and_gas.gd`, `combat/run_bodies.gd`, `vehicles/run_drone_stations.gd`, `combat/run_flamethrower.gd`, `vehicles/run_vehicle_rules.gd`, `events/run_match_modes.gd`, `files/run_game_files.gd`, `ui/run_battle_screen.gd`, `ui/run_menus.gd` |
| `run_playtest20.gd` | `vehicles/run_vehicle_rules.gd`, `combat/run_bodies.gd`, `ai/run_ai_rules.gd`, `ui/run_battle_screen.gd`, `ui/run_board_art.gd` |
| `run_playtest20_screen.gd` | `ui/run_battle_clicks.gd` |
| `run_playtest21.gd` | `combat/run_movement.gd`, `vehicles/run_vehicle_rules.gd`, `combat/run_shield_rules.gd`, `combat/run_bodies.gd`, `vehicles/run_drone_stations.gd`, `events/run_match_modes.gd`, `combat/run_flamethrower.gd`, `ui/run_battle_screen.gd`, `ai/run_ai_rules.gd` |
| `run_remaining_bugs.gd` | `combat/run_flamethrower.gd`, `ui/run_effects.gd`, `combat/run_shield_rules.gd`, `combat/run_movement.gd`, `combat/run_furniture_rules.gd`, `combat/run_bodies.gd` |
| `run_remaining_generation.gd` | `mapgen/run_generation.gd` |
| `run_remaining_ui.gd` | `ui/run_screens_walkthrough.gd` |
| `run_reported_issues.gd` | `events/run_event_rules.gd`, `mapgen/run_generation.gd`, `vehicles/run_vehicle_rules.gd`, `ui/run_board_art.gd`, `ui/run_battle_screen.gd`, `net/run_net_rules.gd`, `ui/run_menus.gd` |
| `run_shield_blasts.gd` | `combat/run_shield_blasts.gd` |
| `run_team_session.gd` | `combat/run_blasts.gd`, `mapgen/run_generation.gd`, `ui/run_battle_screen.gd`, `net/run_net_rules.gd`, `ui/run_menus.gd` |
| `run_wave_initiative.gd` | `events/run_wave_initiative.gd` |
