# MCF Tactics — Project Content Audit

Audit date: 2026-09-05. Commit `f76900e`, branch `main`, working tree clean.

This document records the state of the project's content as of that commit: how far
`GAME_SPEC.md` can be trusted against the source, what condition the code is in, whether
the assets and data hold together, and where the network and determinism contracts leak.
Every claim below cites `file:line`. Nothing in the repository was modified to produce it.

---

## 1. Verdict

**The project is in good condition, and `GAME_SPEC.md` is unusually trustworthy.** Its
central promise — that every number in it was read out of the source rather than an older
draft — survives a constant-by-constant check: roughly sixty constants across `MCF.gd`,
`GameActionResolver.gd` and `Main.gd`, the full `LASER_COST` table, `CLIMB_COST`,
`COVER_MOD`, the vehicle `DESTRUCTION` table and all three enums matched the source with
**no value mismatches at all**. All fifteen unit `.tres` files match §4.2 field by field.
`maps/town.json` is schema-exact against its loader. There is no `TODO`, no `FIXME`, no
stray `print()`, and no `assert()` anywhere in 14,706 lines.

**The real defects cluster in one place: the lockstep networking layer.** Four separate
holes there compound each other — a player's dig choice never reaches the wire, the battle
screen mutates burst state behind the resolver's back, an authoritative turn transition
has no authority check, and when a divergence does occur nothing detects it because the
client silently falls back to its own dice.

**Separately, the golden-trace harness that §27 names as the project's entire regression
safety net is not in the repository.** Three optimization passes (#101, #102, #106) rest
on it, and none of their invariants can be re-verified without it.

### Scope

| Audited | Not audited |
|---|---|
| Spec-vs-source conformance across all 27 sections | Gameplay behaviour — the game was **not executed** |
| All 66 `.gd` files (14,706 lines) | §27's performance figures (0.31 s at 100v100, 3.90 s at 360 units) — unverifiable without the missing harness |
| All 15 unit `.tres`, `VehicleDB`, `maps/town.json` | Balance and design quality — out of scope |
| `project.godot`, all 5 `.tscn`, 22 UI textures | Rendering output and visual correctness |
| Networking, determinism, and undo contracts | |

---

## 2. Correctness and determinism

These are ranked first because they are the only findings that can silently produce a
wrong game state.

### 2.1 The battle screen mutates simulation state behind the resolver — CRITICAL

`scenes/Main.gd:963`

```gdscript
if _pending_shoot(u) and not _valid_pending_shoot(u):
    u.action_state = null
```

`UnitInstance.action_state` is not view state. It is serialized in
`GameState.snapshot()` / `restore()` (`src/sim/GameState.gd:94-96,108,162-169`), and the
resolver reads it at `src/resolver/GameActionResolver.gd:281` to choose between two very
different outcomes for the same `ShootIntent`:

- **non-null** → continue the burst: retarget for free, reuse `remaining_shots`, **charge
  no AP** (lines 282-286);
- **null** → start a new burst: **charge 1 AP**, reset `remaining_shots` to
  `rate_of_fire` (lines 287-291).

`_enter_shoot()` runs only in the acting player's own `Main.gd`, and networking syncs
state purely by replaying identical intents plus recorded dice
(`src/net/NetGame.gd:101-113`). This assignment is never transmitted. So when a player's
stale burst target becomes invalid and they retarget, the acting peer resolves a *new*
burst while the remote peer — whose replica still holds a non-null `action_state` —
resolves a *continued* one. Same intent, same dice, different AP and different shot
count on the two machines.

This is the single violation of §1.1's "every state change flows through
`GameActionResolver.resolve(intent)`" that has a demonstrable divergence path.

### 2.2 `DigIntent.dirt_a` / `dirt_b` never reach the wire — HIGH

The player's 3-click dig flow sends both chosen dirt cells:

- `scenes/Main.gd:617` — `DigIntent.new(selected_id, dig_trench, dig_dirt_a, coord)`
- `src/net/IntentCodec.gd:75-76` — encodes only `{t, a, x, y}`; both dirt fields are dropped
- `src/net/IntentCodec.gd:124` — decodes `DigIntent.new(a, coord)`, leaving both at the
  `(-999, -999)` sentinel
- `src/resolver/GameActionResolver.gd:1608` — `_chosen_dirt_spots()` sees the sentinel and
  auto-picks from `_dirt_spots()` order

The host places dirt where the player clicked; the client places it wherever the automatic
pass lands. Dirt piles are 0.5 m cover that change movement cost and line of sight, so the
boards diverge and stay diverged.

This is the exact bug class §22.1 documents having fixed for `MoveIntent.carry_drop` —
the same oversight, one intent over. §23.11 confirms the 3-click flow is deliberate and
"load-bearing elsewhere", so the fields are not vestigial.

### 2.3 A divergence, once it starts, is silently absorbed — HIGH

`src/sim/DiceService.gd:22-30`

```gdscript
func roll_d6() -> int:
    var v: int
    if not _scripted.is_empty():
        v = _scripted.pop_front()
    else:
        v = _rng.randi_range(1, 6)
```

The client pops host-supplied rolls *only while the queue is non-empty*, then falls
through to its own local RNG. Nothing compares rolls consumed against rolls supplied. So
if the two sides ever diverge — through §2.1, §2.2, or any future route — the client
quietly begins rolling its own dice and the match continues in two different realities
with no error, no warning, and nothing in the log.

This is what makes the other findings dangerous rather than merely wrong. Comparing
consumed-vs-supplied counts after each `_client_apply` would convert a silent, permanent
divergence into an immediate, diagnosable failure.

### 2.4 `EndTurnIntent` bypasses every authority check — MEDIUM

`_resolve_end_turn()` (`src/resolver/GameActionResolver.gd:3261`) takes no actor.
`EndTurnIntent` carries `actor_id = -1` (`src/intents/EndTurnIntent.gd:7`), so
`_validate_actor`'s ownership gate — `unit.owner != state.active_player()` — never runs
for it. `NetGame.receive` (`src/net/NetGame.gd:51-55`) resolves any `K_INTENT` a client
sends. A client can therefore end the host's turn at any moment, which also plays the
civilian slot and advances fire.

Every other intent is protected by that gate, so this is not exploitable from an
unmodified client's UI — but it is the one authoritative state transition with no
server-side guard.

### 2.5 The network layer trusts its input structurally — LOW

`src/net/NetGame.gd:55,58` index `msg["i"]` directly, so a message missing that key
crashes the peer. `IntentCodec.decode` returns `null` for an unrecognised tag
(`src/net/IntentCodec.gd:139`), and `GameActionResolver.resolve` dereferences its argument
without a null check (`src/resolver/GameActionResolver.gd:42`).

### 2.6 The "One RNG" invariant has one exception — LOW (latent)

§1.1 states "All randomness comes from `DiceService`." One line does not:
`src/controllers/AIController.gd:967` adds `score += randf() * 4.0` to move scoring when
`difficulty == Difficulty.EASY` (gated at line 932). That draw comes from Godot's global
RNG — not `DiceService`, not seeded from `MapHandoff.dice_seed`, not written to the dice
log.

**This is latent, not live.** `_setup_network_controllers()` (`scenes/Main.gd:1664-1673`)
clears the controller dict and builds only a `LocalHumanController` and a
`NetworkController`; `AIController` is instantiated only for local hot-seat play
(`scenes/Main.gd:330`). So no AI currently runs inside a lockstep match. Two consequences
remain: §27.1's byte-identical golden trace cannot hold at EASY difficulty, and the spec
never records which difficulty the trace was run at; and the moment AI is wired into
networked play — AI-vs-AI spectating, for instance — this line desyncs on the first move.

For contrast, `scenes/Placement.gd:117`'s `randi()` is *correct* usage: the host draws the
shared seed once and ships it. `scenes/DiceRoller.gd:85`'s `randi_range(1,6)` is cosmetic
face-spinning before the authoritative value lands.

### 2.7 The network layer writes turn state directly — LOW

`src/net/NetGame.gd:92-95` assigns `state.turns.round_order`, `active_index`,
`round_number` and `initiative_rolled` outside the resolver, to force the client's
`TurnManager` onto the host's authoritative initiative. The reasoning is documented in
place (lines 64-70) and the step is one-time and immediately followed by
`feed_scripted()`, so it does not diverge — but it establishes a precedent that a
non-resolver path may write core simulation fields.

`scenes/Main.gd:261-275` similarly calls `state.spawn_unit`, `state.spawn_vehicle` and
`state.turns.begin_match` directly. That is roster bootstrap before any turn logic exists
to route through, and is best read as a deliberate exception rather than a defect.

---

## 3. The missing safety net

**§27.1 makes a byte-identical golden trace the sole proof that #101, #102 and #106
changed no rule, number or decision** — "Not by reading the diff… The trace must come back
byte-identical after every single change." §27.2 then warns that the AI is
order-sensitive, so a refactor producing the same *set* of legal moves in a different
*order* silently deploys the army differently, and "only a byte-exact trace catches that."

No test, trace, harness, benchmark or fixture exists anywhere in the tree. The stated
regression safety net is not reproducible, so none of §27's invariants — nor its
performance figures — can be re-verified after any future change. Given §27.2's warning,
this is the finding most likely to cost real time later.

---

## 4. Spec drift

The drift is narrow. Everything not listed here was checked and matched.

### 4.1 §24 "Known Gaps" is wrong in three of five claims

It states the AI "does not throw grenades, build, dig, pilot drones, or ram with
vehicles."

| Claim | Reality |
|---|---|
| does not **dig** | `src/controllers/AIController.gd:233` issues `DigIntent` in `_forced_action`, reachable from `_decide()` at line 134 |
| does not **pilot drones** | `AIController.gd:311` routes any drone through `_drone_action`; `:1153` detonates, `:1167` moves |
| tank-cannon AI **ignores the blast-shield rule** | The opposite: `AIController.gd:1182` calls `_ally_near(state, target.coord, MCF.CANNON_BLAST_RADIUS)` and **withholds** cannon fire when a friendly is in the blast |
| does not throw grenades | Accurate — no `UseItemIntent` in AI code |
| does not build | Accurate — no `BuildIntent`/`BuildWallIntent`/`WeldAirlockIntent` in AI code |
| does not ram | Accurate |

The drone conclusion is nonetheless *effectively* right, for a reason the spec does not
give: the AI never issues `SpawnDroneIntent`, so an AI side can never get a drone onto the
board. `AIController.gd:311`, `:1153` and `:1167` are complete but unreachable in
AI-controlled play.

### 4.2 `TRENCH_DEPTH` is inert, and the spec attributes the trench rule to it

`GAME_SPEC.md` states four times — §6.6 (line 404), §9.1 (714), §23.4 (1734) and §25
(1807) — that the trench's protection "comes from `TRENCH_DEPTH = 2.0`, not from cover."

`const TRENCH_DEPTH := 2.0` exists at `src/sim/MCF.gd:148` and is **read nowhere in the
project**. `trench_protected()` (`src/resolver/GameActionResolver.gd:1175-1186`) implements
the immunity entirely from `feature_id == MCF.FEATURE_TRENCH`, Chebyshev distance, and
`_trench_run_clear()`. The *behaviour* the spec describes is correct and was verified;
only the causal attribution is wrong, and the constant it names is dead.

### 4.3 §1.3's source layout under-lists two directories

`src/controllers/` (`GAME_SPEC.md:70-71`) names four files and omits `AIPlanner.gd` and
`GeoField.gd` — both of which the spec gives their own sections (§17.0, §27.17).
`src/intents/` names 23 subclasses; there are 25 on disk. Missing: `MoveHeldIntent` and
`WeldAirlockIntent`, both documented in prose elsewhere (lines 646, 781, 1649).

### 4.4 Smaller documentation gaps

- **§25 omits `CORPSE_SCATTER_RADIUS`** (`src/sim/MCF.gd:170` = 3, used at
  `GameActionResolver.gd:1315-1316`). The corpse-wall prose says bodies scatter "onto
  random empty tiles nearby" without ever giving the radius.
- **§25 lists `POTENTIAL_PER_DURABILITY` twice** (`GAME_SPEC.md:1829` and `:1853`), the
  same correct value both times.
- **§20's summary of `MapData` omits `spawns`**, a real serialized field carrying
  `town.json`'s twelve civilian placements.
- **`GameActionResolver.gd:632`'s comment credits the laser preview to `laser_path`**,
  which is dead code; the preview actually comes from `laser_preview()` (see §5.1).

---

## 5. Code health

### 5.1 Dead code

Verified by whole-tree grep including `.tscn` and `.tres`.

Functions with no callers:

| Symbol | Location |
|---|---|
| `laser_path()` | `src/resolver/GameActionResolver.gd:849` — superseded by `laser_preview()` (`:858`), which `scenes/Main.gd:2462` actually calls |
| `_free_cell_near()` | `src/resolver/GameActionResolver.gd:2481` |
| `orthogonal_neighbors()` | `src/sim/Grid.gd:103` |
| `roll_d6_many()` | `src/sim/DiceService.gd:32` |
| `seat_cell()`, `has_driver()` | `src/sim/Vehicle.gd:129,140` |
| `is_active()`, `is_host()` | `src/net/NetworkSession.gd:59,62` |
| `text_accent_color()`, `header_color()` | `src/ui/UiTheme.gd:85,88` |
| `_make_p2()` | `scenes/Main.gd:318` |
| `deliver_remote_intent()` | `src/controllers/NetworkController.gd:9` — see below |

Constants declared and never read: `DRONE_ARMOR` (`src/sim/MCF.gd:57` — the real value is
duplicated as a literal in `src/data/units/drone.tres:11`), `DRONE_STATS_ID` (`:58` — code
uses the bare string `"drone"`, e.g. `scenes/Main.gd:2394`), and `TRENCH_DEPTH` (`:148`,
see §4.2).

Signals emitted but never connected: `CombatLog.dice_rolled`
(`src/log/CombatLog.gd:7`) — its `add_dice()` does not even append to `lines` the way
`add()` does, making the whole chain a no-op, since dice presentation goes through
`Main.gd`'s own `_play_dice()`/`DiceRoller.finished` path; and
`TurnManager.active_player_changed` / `round_started`
(`src/turn/TurnManager.gd:18-19`, emitted at lines 46, 62, 72, 73).

**`NetworkController` is a hollow shell.** Its comment still reads "Заглушка сетевого
игрока до M7" (`src/controllers/NetworkController.gd:4`) — the only placeholder-language
comment in the tree — and its sole method is uncalled. The class is instantiated at
`scenes/Main.gd:1673` purely to fill the remote side's slot in the `controllers` dict;
actual synchronisation runs through `NetGame.action_applied`, bypassing it entirely.

### 5.2 Duplication

**The straight-line walk is hand-copied six times inside `GameActionResolver.gd`** — the
same `(dx == 0 and dy == 0) or (dx != 0 and dy != 0 and absi(dx) != absi(dy))` guard plus
`sx`/`sy` stepping loop, in `_wall_between` (`:1018-1031`), `_fire_between` (`:1036-1051`),
`_fortification_between` (`:1054`), `_trench_run_clear` (`:1194`), `los_blocked`
(`:3300-3335`) and `first_unit_on_line` (`:3343`). The comment at `:1013-1017` explains
this is deliberate: calling `Combat.line_cells()` would allocate an array on every shot,
AI evaluation and preview. The tradeoff is defensible; the consequence is that a fix to
the primitive must be remembered in up to six places — and one already diverged, since the
`d <= 1` embrasure special case exists only in `los_blocked`.

**The move-budget formula is duplicated across the UI/resolver boundary.**
`scenes/Main.gd:934-945` and `src/resolver/GameActionResolver.gd:115-126` carry the same
eight-line burdened/carry-budget/credit computation verbatim. Main.gd's own comment states
the hazard: the budget *must* match the resolver or the highlighted cells will not match
what it accepts. Preview-only, so not a lockstep risk, but fragile by the code's own
admission.

Minor: `_throw_path` (`src/resolver/GameActionResolver.gd:3087`) recomputes Chebyshev
distance inline as `maxi(absi(dx), absi(dy))` instead of calling `Combat.distance()`
(`src/sim/Combat.gd:9-11`).

### 5.3 A long function that should be left alone

`scenes/Main.gd:_draw()` is 471 lines, the longest in the project, ahead of `_handle_click`
(219) and `_open_menu` (193). It is visibly hand-optimized with documented reasoning —
node and autoload property reads hoisted into locals outside a 2,500-iteration loop, the
fog set taken from the resolver's cache, the fog fill skipped wholesale when fog is off.
It is long *because* of §27's optimization passes, not through neglect. Anyone tempted to
split it should read §27.6 first.

---

## 6. Assets, data and packaging

1. **The custom UI font never loads.** `src/ui/UiTheme.gd:16` declares
   `FONT_TTF := "res://interface_textures/ui_font.ttf"`; no `.ttf` exists anywhere in the
   project. `_font()` (lines 281-289) guards with `FileAccess.file_exists` and falls back
   to a `SystemFont`, so nothing breaks — the game has simply never rendered in its
   intended typeface. Ship the font or drop the constant.
2. **`interface_textures/logo.png` is dead.** It is the only one of the 22 tracked
   interface PNGs never requested by code; the public `get_texture()` accessor has zero
   call sites project-wide.
3. **`project.godot` lacks what a shippable project carries**: no `[input]` InputMap, no
   `application/config/icon`, and no `export_presets.cfg` anywhere in the tree. Fine for
   development, blocking for a build.
4. **Minor hygiene.** `textures/all_textures.txt` is regenerated at runtime by
   `src/ui/Sprites.gd::_write_manifest()` yet is committed to git — currently in sync, so
   not stale, just a build artifact under version control. `.gitignore` line 2
   (`.import/`) is a Godot 3 pattern that matches nothing in a Godot 4 project.

---

## 7. Project context

- **No project-level `CLAUDE.md`**, which the host's `/root/CLAUDE.md` calls for, and
  `README.md` is 14 bytes (`# mcf-isotope`) with no build, run or licence information.
  `GAME_SPEC.md` is doing all the work.
- **The original design document is unavailable.** It is recorded as
  `/Users/28azverev/Downloads/112/MCF_Design_Document.md` — a macOS path that does not
  exist on this Linux host. `GAME_SPEC.md` is now the only design document.
- **Nine source comments cite the older *isotope* project as their design precedent** —
  `TurnManager.gd:4,64`, `GameActionResolver.gd:10,156,1697`, `Setup.gd:3`,
  `MainMenu.gd:3`, `GameConfig.gd:14`, `VehicleDB.gd:5` — referring to sections like
  "isotope §12b" and "isotope §6.5". That document is neither on this host nor in this
  repo, so those citations cannot be followed. This also explains the naming: the git
  remote is `mcf-isotope` and the directory `mcf-isotope 1.0`, while `project.godot`
  declares `config/name="MCF Tactics"`. Inherited lineage, not a mistake.
- **The language split is a documented convention.** 2,803 of 14,706 GDScript lines (19%)
  carry Russian comments, heaviest in the files a newcomer opens first
  (`GameActionResolver.gd` 782, `Main.gd` 515, `AIController.gd` 335). §21 states the rule
  outright: "All UI strings are **English**; all code comments are **Russian**." Both
  halves verified true. The practical consequence is that `GAME_SPEC.md` is the only
  English entry point to the codebase.

---

## 8. Verified clean

The negative results are the most useful part of this audit, and are recorded in full so
that future work does not re-litigate them.

### Spec conformance

- **§25's constants match the source exactly** — every named constant and value across
  `MCF.gd` (AP, movement, climb, cover, hedgehog, sight, capture, corpse wall, dirt,
  grenade, anti-tank, drone, cannon, assault, flame, the complete marksman `LASER_COST`
  table, glass recharge, sniper, shield push, fire spread, RSP, airlock, zero-g knockback,
  BRU, all build and break costs, `DOT_DURABILITY`, all three enums),
  `GameActionResolver.gd` (dig credits, glass armor, weld AP, `OFFBOARD`, `BURNS_AWAY`)
  and `Main.gd` (menu anchor and chrome, BRU colour, AP dot delay, zoom limits).
  **No value mismatches found.**
- **§1.2's distance-metric table is accurate on all eight rows** — `Combat.distance`
  (Chebyshev), `blast_square`, `blast_x`, `blast_diamond`, `DRONE_DIRS_8` (ortho 1 /
  diag 2), `_ortho4` fire spread, orthogonal grenade throw, and flat-cost 8-direction
  movement. Every named function exists and implements the claimed metric.
- **§4.2's 15-unit roster matches the `.tres` files field by field**, including stats that
  come from `UnitStats.gd` defaults rather than being set explicitly, and the commander's
  `action_points = 3` override.
- **§16's vehicle data matches `VehicleDB.gd` exactly**, including the destruction-roll
  table. §16.6's "unwired" shuttle fields (`driver_move_ap`, `passenger_defense_bonus`,
  `collision_durability_threshold`) are confirmed genuinely unread.
- **A dozen formulas spot-checked and correct**: hit number and clamp, the two-roll
  hit/parry pipeline, corpse-shield bonus, the distance ≤1 / ==2 no-cover rule, assault
  and shield-push chains, engineer build costs, dig credits (3 / 6), RSP seize and fire
  counts, pillbox absorption, fire spread, drone rules.
- **§17.2's 80% turnout rule** is `MIN_ARMY_ACTIVITY := 0.8`
  (`src/controllers/AIController.gd:56`) with a single forced second pass (lines 133-140);
  **§17.4's AI-vs-AI support** exists at setup (`scenes/Setup.gd:68-71`, correctly using a
  `CheckBox`) and as a mid-battle toggle (`scenes/Main.gd:3088`).
- **§11's fog default is exactly as described** — `true` on the resolver
  (`GameActionResolver.gd:12`), off at the UI (`GameConfig.gd:19`), reconciled at
  `Main.gd:233`. This looks like a bug until you read §11, which explains it correctly.
- **§18.2's undo rules hold**: dice-rolling actions clear the stack, AI and civilian turns
  are never pushed, and the stack is cleared on a turn boundary (`scenes/Main.gd:1520-1533`).
- **Every `§N.N` cross-reference in the spec resolves to a real heading.** The `§3.6`–`§3.14`
  references are rulebook paragraphs, documented as such in the preamble.

### Architecture and code

- **The resolver-only mutation invariant holds everywhere except §2.1.** A systematic
  sweep against every mutable field on `UnitInstance`, `GridCell`, `Vehicle` and
  `GameState`, across `scenes/`, `src/controllers/` and `src/net/`, found only
  `Main.gd:963` and the documented turn-sync at `NetGame.gd:92-95`.
- **`IntentCodec` type coverage is complete** — all 25 concrete `Intent` subclasses have
  matching encode and decode branches. The gap is in *fields*, not types (§2.2).
- **No leftovers**: zero `TODO`/`FIXME`/`HACK`/`XXX`, zero `print()`/`print_debug()`, zero
  commented-out code blocks, zero `assert()` — so nothing depends on behaviour stripped
  from release builds.
- **`push_error` is used deliberately**, at four sites only: `Grid.gd:158,181` refusing to
  stack occupants (the #103 one-unit-per-cell enforcement) and `NetworkSession.gd:32,46`
  catching an out-of-tree host or join.
- **No wall-clock or frame-time anywhere in `src/`** — no `Time.get_ticks`, no `OS.get_*`.
- **Dictionary iteration order is not a divergence source.** `GameState.units`/`vehicles`
  are keyed by monotonically increasing spawn ids and `all_units()` returns `.values()` in
  insertion order, which both peers reproduce identically from the shared seed.
- **Null-safety is sound.** `Grid.cell()` returns `null` out of bounds by design and its
  callers are guarded by `in_bounds()`, a reachability computation, or `Grid.neighbors()`
  (itself in-bounds filtered). No chained `state.get_unit(x).field` pattern exists.
- **`CivilianAI` is correctly reduced**, not half-deleted: two static predicates and no
  behaviour, its own comment explaining that the second AI brain was folded into
  `AIController` per #103.
- **The static cross-scene globals are sound.** `GameConfig` and `MapHandoff` use static
  vars deliberately and document why; `MapHandoff.take_seed()` consumes-and-resets.

### Assets, data and repository

- **Every unit id the code can construct has a `.tres`.** Six dynamic-load sites
  (`Main.gd:259,266`, `Placement.gd:190`, `MapData.gd:141,157`,
  `GameActionResolver.gd:2449`) can request fifteen ids between them; all fifteen files
  exist and all fifteen are reachable. Vehicle ids `tank` and `shuttle` both exist.
- **`maps/town.json` is valid and schema-exact** — 50×50, nine keys matching
  `MapData.to_dict()`/`from_dict()` with nothing missing and nothing ignored; every
  `feature_id`, `floor_type` and `zone_owner` value maps to a real `MCF` constant.
- **`MapData` round-trips completely** — all eight member fields plus a `version` appear
  in `to_dict()`, so map saves drop nothing.
- **No orphaned sidecars** — 63 `.gd`/`.uid` pairs and 22 `.png`/`.import` pairs, zero
  mismatches in either direction.
- **The five tiny `.tscn` files are correct, not broken.** Each is a bare root node with
  an attached script and no children; every script's `extends` matches its root type, and
  no script anywhere uses `get_node` or `$` — the UI is built procedurally by `UiTheme`
  and `SteamChrome`.
- **The engine and class registry agree.** Godot 4.7.stable is installed at
  `/usr/local/bin/godot`; `.godot/global_script_class_cache.cfg` lists exactly the 59
  `class_name` declarations present in source, no more and no fewer.
- **Git is healthy** — working tree clean, `main` identical to `origin/main` at `f76900e`,
  205 tracked files, `.godot/` correctly ignored, no stray binaries or large-media commits.

---

## 9. Method and limitations

Findings were produced by four independent passes — spec conformance, code health, asset
and data integrity, and a networking/determinism review — with each pass's claims
re-verified against the source before being recorded here. Where two passes disagreed, the
source settled it; §2.6 in particular was narrowed from "live desync" to "latent risk"
after checking that `_setup_network_controllers()` never instantiates an `AIController`.

The audit is static. **The game was not run.** A clean read of the source is not evidence
that it plays correctly, and no finding here should be treated as a substitute for
observing the behaviour. The §27 performance figures and the byte-identical trace claim
are unverifiable until the harness described in §3 is rebuilt.
