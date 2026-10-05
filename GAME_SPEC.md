# MCF Tactics — Full Game Specification

A turn-based tactical skirmish game built in **Godot 4.7 / GDScript**, adapting the
tabletop wargame *Mind Control Factor (MCF)*.

This document describes every mechanic, unit, screen, and system **as actually
implemented in the codebase**, together with the design decisions taken during
development. Where a number appears here it was read out of the source, not out of an
older draft of this document. Section markers like *(§3.x)* refer to the original MCF
rulebook paragraphs a mechanic derives from; markers like *(#42)* refer to numbered
development tasks (see §26).

---

## 1. Architecture & Guiding Principles

### 1.1 Core invariants

- **Intent → Resolver.** The simulation never mutates itself. UI and AI construct
  immutable **Intent** objects; **every** state change flows through
  `GameActionResolver.resolve(intent)`, which returns an `ActionResult` carrying
  `ok`, `reason`, `log_lines`, `dice_events`, and `deaths`. Controllers never touch
  `GameState`. This keeps the rules in one file, and makes undo, replay, and lockstep
  networking tractable.
- **`deaths` is a presentation contract** (#46). The kill is *already applied* in the
  resolver, but the id list is handed back so the UI can reveal the death **only after**
  the defence-roll animation finishes. Without it a corpse would pop into existence
  before the dice landed and spoil the outcome.
- **One RNG.** All randomness comes from `DiceService`. The host can `begin_record()`
  and `take_log()`; a client can `feed_scripted()` the same sequence. Two machines
  running the same intents with the same dice log produce byte-identical states.
- **Data, not code.** Unit statistics live in `.tres` resources (`UnitStats`), vehicles
  in `VehicleDB`, tunable constants in `MCF.gd`. Balance changes are data edits.
- **Rendering.** GL Compatibility, 2D top-down grid. Map and unit graphics are vector
  primitives (`draw_circle` / `draw_rect` / `draw_string`) with optional texture layers
  on top (§21).
- **One autoload.** `Ui = "*res://src/ui/UiTheme.gd"`. Everything else is a
  `class_name` in the global registry.

### 1.2 Distance metric

The board uses **Chebyshev** distance (`Combat.distance`, diagonal = 1) for ranges,
sight, and blasts. Seven systems deliberately deviate, and each deviation is a rule,
not an oversight:

| System | Metric | Why |
|---|---|---|
| Ranges, sight, most blasts | Chebyshev | Default |
| Movement cost | 8-dir Dijkstra, all steps 1 | Diagonals are not penalised on foot |
| Drone flight | 8-dir Dijkstra, ortho 1 / diag 2 | Flight budget approximates Euclidean |
| Fire spread | 4-orthogonal | Fire does not cut corners |
| Grenade throw line | 4-orthogonal | Throws are axis-aligned (#4) |
| Grenade blast | X / diagonal-only (`blast_x`) | Distinct shape from anti-tank (#64) |
| Tank cannon blast | Diamond, radius 2 (`blast_diamond`) | Distinct shape again (#63) |
| BRU / airlock adjacency | Manhattan ≤ 1 | Structural, not spatial |

### 1.3 Source layout

```
src/sim/          MCF.gd (constants + enums), GameState, Grid, GridCell,
                  Movement, Combat, UnitStats, UnitInstance, ActionState,
                  Vehicle, VehicleRules, DiceService, CivilianAI
src/turn/         TurnManager.gd — initiative order and round accounting
src/resolver/     GameActionResolver.gd (the single mutation point), ActionResult.gd
src/intents/      Intent.gd + one subclass per action: Move, Shoot, Capture, Break,
                  Build, BuildWall, Dig, Drag, Release, Push, UseItem,
                  PickUpCorpse, DropCorpse, RSPFire, SpawnDrone, DroneMove,
                  DroneDetonate, VehicleBoard, VehicleDisembark, VehicleMove,
                  VehicleTurn, VehicleCannon, EndTurn
src/controllers/  PlayerController (base), LocalHumanController,
                  AIController, NetworkController
src/data/         VehicleDB, GameConfig, MapData, MapHandoff, units/*.tres
src/log/          CombatLog.gd
src/net/          NetworkSession, NetGame, IntentCodec, NetHandoff
src/ui/           UiTheme (autoload `Ui`), SteamChrome, Sprites
scenes/           MainMenu, Setup, Placement, Main (battle), MapEditor, DiceRoller
```

Note the controller trio: `LocalHumanController`, `AIController`, and
`NetworkController` all implement the same `PlayerController` surface
(`begin_turn`, `notify_state_changed`, `notify_intent_denied`, `is_local_human`) and
emit intents through a single `intent_ready` signal. **The simulation cannot tell them
apart** — that is what makes hot-seat, AI, and network play the same code path.

---

## 2. Board Model

### 2.1 The grid

`Grid` owns a `width × height` array of `GridCell`. Coordinates are `Vector2i`.
There is no chunking; maps up to 50×50 are routine.

### 2.2 Cell fields

| Field | Type | Meaning |
|---|---|---|
| `floor_type` | int | normal / flammable / none (space) |
| `cover_height` | float | 0.0 … 2.0; ≥ 2.0 is a wall |
| `on_fire` | bool | burning |
| `fire_owner` | int | who started it (for spread turn order) |
| `is_space` | bool | vacuum — zero-G rules apply |
| `occupant_id` | int | living unit standing here |
| `vehicle_id` | int | vehicle footprint covering this cell |
| `feature_id` | int | fortification / terrain object (§9) |
| `feature_owner` | int | who built it |
| `feature_durability` | int | remaining structural points on the unified damage scale (§9.8); 0 = no durability, destroyed by any hit |
| `corpse_count` | int | stacked bodies; 5 → corpse wall |
| `dirt_level` | int | 0 … `DIRT_MAX_LEVEL` (2) |

**One man to a cell, enforced by the board (#103).** `occupant_id` is not merely a
record of who is standing here — it is a lock. `Grid.place()` and `Grid.move_occupant()`
**refuse to overwrite** an existing occupant and return `bool` to say so; every caller
must check. Before this the rule lived only in the movement and spawn code, and anything
that bypassed them — a civilian driven by its own brain, an AI ordered onto a cell a
second unit had already claimed, a body ejected from a wrecked vehicle — could quietly
stack two units on one tile. Now the invariant holds no matter who asks.

The single deliberate exception is `GameState.spawn_unit(stats, coord, owner, occupy := true)`.
Passing `occupy = false` creates a unit that exists on the roster but claims no cell: this
is how a crewman is launched straight into a vehicle seat or a drone slot (§10), where his
`coord` is `OFFBOARD` and no tile is his to hold.

### 2.3 Heights and climbing

A cell's `cover_height` is both cover and an obstacle. **Height ≥ `WALL_HEIGHT` (2.0)
is impassable.** Below that, entering costs extra movement:

```
CLIMB_COST = { 0.5 → 2, 1.0 → 3, 1.5 → 4 }
```

Dirt piles above 1 m and drone stations block standing entirely.

---

## 3. Turn Structure

### 3.1 Sides

**Player 1**, **Player 2**, and **Neutral** (civilians). Player 2 may be a local human,
the AI, or a network peer.

### 3.2 Initiative (#53)

Initiative is an order of **sides**, not of individual units, and it is rolled
**exactly once per match** — in `TurnManager.begin_match(all_units, dice)`, called after
placement so the roll can see whether any civilians exist. `initiative_rolled` latches;
a second call is a no-op.

- **The players' order is a dice shuffle (batch 14).** Player 1 used to precede Player 2
  by right of letter; now `begin_match` runs a Fisher–Yates over the player slots with
  indices drawn from `DiceService` (three d6 per draw), so the host and a guest with the
  same seed shuffle identically — and the host announces its order over `K_INIT` anyway.
- If any living civilian is on the map, the **Neutral slot** is inserted at one of three
  positions by `dice.roll_d6() % 3` (equiprobable 0/1/2):

  ```
  P1 → P2 → CIV
  P1 → CIV → P2
  CIV → P1 → P2
  ```

- **The order is never re-rolled.** New rounds reuse it verbatim.
- A slot whose side has **no living units** is silently **skipped** — a wiped-out side
  or exhausted civilian population simply drops out of the rotation.
- `order_names()` renders it as `"P1 → CIV → P2"` for the HUD and combat log.

**In a network match the roll is a handshake, not two local rolls** (#93). Both peers
seed `DiceService` from the same `MapHandoff.dice_seed` (shipped by the host with its
roster), so the local rolls already agree — but the host's order is still made
authoritative explicitly. `NetGame.announce_initiative()` sends `K_INIT` carrying the
order, `active_index`, `round_number`, **and the recorded dice of the opening civilian
slot**. Civilians act outside the intent stream, so without shipping those rolls the
two machines would play the very first civilian activation differently. The client
adopts the order, latches `initiative_rolled`, replays the civilian slot from the
scripted log, and emits `initiative_synced` so the HUD redraws. Both peers stash the
slot's result in `NetGame.opening_civilians`, and the battle screen plays it back on
`initiative_synced` (§14.1) — the rolls stay inside the atomic call, only the *showing*
of them moves out.

Within its own turn a player activates **any number of its units, in any order**, and
may pass at any moment.

**AP restore is a round-boundary event, not a turn event.** `end_turn` only resets AP
when the order wraps around to a new round (`_reset_all_ap`). Held units *do* get their
AP back, specifically so they can attempt to break free (§8.2); corpses do not.

### 3.3 Action points

Each unit gets **`AP_PER_ACTIVATION` = 2** per activation. The **Commander** gets
**3** (#66). Base actions cost 1 AP each: Move, Shoot, Capture, Use Item — plus the
derived actions (build, dig, break, drag, release, board, drive, fire RSP, …).

Two actions cost the full activation:

- **Marksman laser** — 2 AP.
- Anything a 1-AP unit cannot afford is simply refused with a `reason`.

### 3.4 Fragmented movement

Movement is a **budget**, not a step. If a Move spends less than the unit's speed, the
remainder stays available and the unit can keep moving **on the same AP** until the
budget is exhausted. Two credits interact with this:

- `dig_credits` — free follow-up digs inside one AP (§9.6). Cleared by `resolve()`
  unless the intent is Dig or Move (#65).
- `move_credit` — a movement allowance granted by grabbing/dragging (§8). It survives
  *every* intent and is only cleared by `reset_ap` at end of turn (#33).

### 3.5 End of turn

`_resolve_end_turn` runs a fixed five-step sequence:

1. `state.turns.end_turn(all_units)` — advance to the next playable slot; restore AP
   **only** if the order wrapped into a new round.
2. `play_civilian_slots()` — civilians take their activations (§14).
3. `advance_fire(state.active_player())` — fire creeps at the start of the turn of
   whichever side started it (#45).
4. Zero every unit's `dig_credits` — a dig series never carries across turns.
5. Per vehicle: `ap = _vehicle_crew_ap(veh)` and `cannon_shots_this_round = 0`, so the
   main gun becomes available again.

---

## 4. Units

### 4.1 Stat schema (`UnitStats`)

| Field | Default | Meaning |
|---|---|---|
| `fire_range` | 12.0 | Range band for `hit_number` |
| `rate_of_fire` | 1 | Hit dice per Shoot action |
| `armor_threshold` | 4 | Defence roll target ("4+") |
| `target_defense_penalty` | 0 | Subtracted from the *target's* save |
| `speed` | 6 | Movement points per Move |
| `sight_range` | 0 | 0 → use `DEFAULT_SIGHT_RANGE` (12) |
| `action_points` | 0 | 0 → use `AP_PER_ACTIVATION` (2) |
| `cost` | 1000 | Point-buy price |
| `special_ability_id` | "" | See §7 |
| `default_item_id` | "" | Copied into `held_item_id` at spawn; see §15 |
| `notes` | "" | Designer commentary, not read by the sim |

`fire_range` has two magic values: **`inf`** means the hit number is always 1
(auto-hit — the Marksman), and **`0` or less** means the unit has no weapon and cannot
shoot at all (the Drone).

Stats load from `res://src/data/units/<id>.tres`. There is no `UnitDB` — the resource
file *is* the database. Only three units define a `default_item_id`: Machinegunner
(frag grenade), Flamethrower (extinguisher grenade), Drone Operator (drone station).

### 4.2 Roster

| Unit | Range | RoF | Armor | Speed | AP | Cost | Ability / Item |
|---|---:|---:|:---:|---:|:---:|---:|---|
| Light Infantry | 12 | 2 | 4+ | 9 | 2 | 99 | — |
| Heavy Infantry | 12 | 3 | 3+ | 6 | 2 | 108 | — |
| Assault | 3 | 8 | 4+ | 9 | 2 | 45 | Shotgun chain (§7.4) |
| Machinegunner | 6 | 4 | 3+ | 6 | 2 | 56 | Frag grenade |
| Sniper | 30 | 1 | 4+ | 6 | 2 | 135 | Auto-hit ≤ 12, −2 target def |
| Marksman | ∞ | 1 | 4+ | 4 | 2 | 90 | Piercing laser, potential 10 |
| Anti-Tank | 18 | 1 | 4+ | 6 | 2 | 81 | 3×3 auto-kill blast |
| Flamethrower | 6 | 1 | 3+ | 6 | 2 | 50 | Flame jet + extinguisher grenade |
| Commander | 12 | 4 | 2+ | 6 | **3** | 160 | High output, tough (#66) |
| Engineer | 12 | 1 | 4+ | 6 | 2 | 51 | Build / BRU / dig ×6 |
| Miner | 1 | 1 | 4+ | 6 | 2 | 25 | Demolish, −1 target def |
| Drone Operator | 12 | 1 | 4+ | 6 | 2 | 51 | Drone station |
| Shield Bearer | 1 | 1 | 2+ | 4 | 2 | 70 | Shield block/push, −2 target def |
| Civilian | 12 | 1 | 5+ | 9 | 2 | **20** | Neutral (§14), purchasable (#91) |
| Drone | — | 0 | 5+ | 30 | — | 20 | Summoned, flies 30, self-detonates |

### 4.3 Runtime state (`UnitInstance`)

Beyond stats, a unit carries: `coord`, `owner`, `remaining_ap`, `status`,
`held_item_id`, `captor_id`, `is_drone`, `home_station`, `operator_id`,
`wall_entry_from`, `civilian_active`, `carried_this_round`, `aboard_vehicle_id`,
`dig_credits`, `bru_wall_used`, `move_credit`, `carried_corpses`, `dragging`,
`action_state`.

Every one of these is captured by `GameState.snapshot()` for undo (§18.2).

---

## 5. Movement

`Movement.reachable(state, unit, budget)` runs an 8-directional Dijkstra and returns
every reachable cell with back-pointers for path reconstruction. Costs:

- Flat step (orthogonal or diagonal): **1**
- Climbing: `CLIMB_COST[height]` = 2 / 3 / 4 for 0.5 / 1.0 / 1.5 m
- Height ≥ 2.0, dirt > 1 m, drone stations, **hedgehogs**, vehicle hulls, living units:
  **impassable**

Corpses **block movement** (batch borg-corpses, 2026-10-02): a body lying where it fell
(the cell's `occupant`) and a pile of bodies (`corpse_count`) are both impassable and
cannot be stood on, like a living unit. Vehicles still roll over them (§17.3).

**Hedgehog jump (#78).** An anti-tank hedgehog is barbed steel: `GridCell.blocks_move()`
refuses it as a destination outright. Instead the Dijkstra treats it as a **hop** — when
a neighbour carries `FEATURE_HEDGEHOG`, the real destination becomes
`Movement.hedgehog_landing()`, the next cell **along the same straight line**, at a flat
`HEDGEHOG_JUMP_COST = 2`. If that landing cell is off-board, walled, or occupied, the
hedgehog is simply impassable from that direction. Because the hop is expressed as an
edge in the same search, path reconstruction, the green move overlay, and the AI's
distance field all understand it for free.

---

## 6. Combat Core

### 6.1 Hit number

```gdscript
Combat.hit_number(dist, fire_range) = clampi(ceil(dist / (fire_range / 6.0)), 1, 7)
```

The range band is split into six steps; each step costs one pip. **7 means
impossible** — the shot is refused rather than rolled.

### 6.2 The firing line

**This is the single most restrictive rule in the combat model, and it gates every
shot.** `Combat.is_on_firing_line(a, b)` requires the target to lie on one of the **8
rays** radiating from the shooter:

```gdscript
delta.x == 0 or delta.y == 0 or absi(delta.x) == absi(delta.y)
```

That is: same row, same column, or a perfect 45° diagonal. Anything off-axis **cannot
be shot at all**, regardless of range, line of sight, or cover. A unit standing one
step off the diagonal is untouchable by that shooter until somebody moves.

One exemption exists: attacks that resolve against a *cell* rather than a unit — grenades
and the tank cannon — have their own axis rules (orthogonal-only) instead.

**Civilians are not an exemption.** They briefly were, by accident: `_civilian_can_shoot`
skipped the firing line, which let them shoot at any angle (§14). #99 closed that hole and
#103 deleted the separate path entirely — a civilian fires an ordinary `ShootIntent` and
meets this gate like everybody else.

### 6.3 The two-roll model

Every shot surfaces two separate rolls to the player:

1. **Hit roll** — shooter rolls ≥ `need`.
2. **Defence / penetration roll** — target rolls ≥ `parry_need`.

```gdscript
var need := Combat.hit_number(dist, shooter.stats.fire_range)
var parry_need := target.stats.armor_threshold + shooter.stats.target_defense_penalty

need       += cover["hit_penalty"]
parry_need -= cover["defense_bonus"]
parry_need -= _corpse_shield_bonus(target)          # +1 per carried corpse

if not sniper and _fire_between(shooter, target):
    need += MCF.FIRE_SHOOT_PENALTY

if sniper and dist <= MCF.SNIPER_AUTOHIT_RANGE and not _fortification_between(...):
    need = 1

need = clampi(need, 1, 7)
```

**Death happens only after the defence roll.** Nothing is revealed early. Defence rolls
made by the defending human player are **manual** (press Roll) for tension; the AI's
are automatic. Every modifier is labelled on the dice prompt (`hit_mods` / `def_mods`)
so the player can see exactly why a number is needed.

### 6.4 Rate of fire and bursts

`rate_of_fire` is the number of hit dice in one Shoot action. A burst may **retarget
between shots without spending extra AP** (#5) — the pending `ActionState` keeps the
burst alive. `ShootIntent.shots` of `−1` means "full rate of fire"; a positive value
fires a fragment of the burst and leaves the rest pending (§3.4).

**Every ordered bullet rolls, even after the target dies (#96).** A kill on the first
bullet used to `break` out of the loop, and the very next lines cleared `action_state` —
so a machinegunner paid 1 AP for four bullets, killed on the first, silently lost the
other three, and the player saw **one** die instead of four. The burst leaves the barrel
as a unit; one unparried hit still kills, it just no longer swallows the rest of the
magazine.

### 6.5 Cover

`cover_effect_from(from_coord, target)` checks **exactly one cell** — the step from the
target toward the shooter:

```gdscript
target.coord + _step_toward(target.coord, from_coord)
```

- At distance ≤ 1, and at distance exactly 2, **there is no cover at all**.
- `COVER_MOD = { 1.0: 2 }` → a 1 m obstacle is **−2 to hit**.
- A corpse lying in that cell grants **no cover at all** (#97). Flat on the ground it
  hides nobody; only the 5-body **corpse wall** shields, and that already counts through
  its own `cover_height`. A *carried* corpse is a different rule — see `_corpse_shield_bonus`.
- `defense_bonus` is **always 0**. Cover in this game makes you harder to *hit*, never
  harder to *kill*. This is deliberate and differs from the tabletop.

### 6.6 Trenches

`trench_protected(from_coord, target, flat_beam := false)` returns true when the target's
cell carries `FEATURE_TRENCH` and the shooter cannot reach down into it. A protected
target simply **cannot be shot** — this is immunity, not a modifier ("Target is below the
trench line"). The trench's own `FEATURE_HEIGHT` is **0.0**; the protection comes from
`TRENCH_DEPTH = 2.0`, not from cover.

For an ordinary shooter the rule is distance: at **> 1** he is blocked, adjacent he is
not. A bullet flies in an arc and can be aimed downwards, so a man who walks to the lip of
the trench shoots into the pit from above.

**A laser is a flat beam, and the adjacency concession does not apply to it (#103).**
`_fires_flat_beam(shooter)` is true for the **Marksman** (`ABILITY_MARKSMAN`), and for him
`trench_protected` ignores range entirely: the only way to hit a man in a trench with a
beam is to **be in a trench yourself**, so that shooter and target sit at the same level
and the beam runs along the ditch. From any surface tile — including the neighbouring one —
the beam passes exactly over the target's head. Previously a marksman standing next to the
trench killed the man lying in it, which is the precise opposite of what a trench is for,
and contradicted the beam preview's own label.

**A beam fired from inside a trench is trapped in that trench (#105).** The rule is
symmetric, and the second half was missing: a marksman standing on the floor of a ditch is
himself below the surface line, so his beam can no more rise than it could descend. He
cannot touch anyone standing on the ground above him, at any range including adjacent, and
he cannot reach a *different* trench across open ground. He can hit only a man lying in
**the same ditch, with the ditch running unbroken between them**: `_trench_run_clear`
walks the firing line and requires every intervening cell to carry `FEATURE_TRENCH`.
Connectivity in general is not enough — a beam is straight, so a trench that bends between
the two men does not count, and that case is already refused one gate earlier by
`is_on_firing_line`.

`_laser_trace` enforces the same thing physically rather than by a separate rule: when the
shooter's own cell is a trench, the trace **stops at the first cell that is not**, emitting
a `"Trench wall"` record at zero potential cost. The beam runs down the ditch as far as the
ditch goes and then buries itself in the earth wall — so the preview and the shot cannot
disagree about where it dies, and everything beyond the ditch is simply unreachable.

Because the two halves fail for opposite reasons, they report different messages:
`_trench_block_reason` says "Target is below the trench line" for a shooter on the surface,
and **"The beam only runs along this trench"** for one at the bottom. A single shared
string would mislead the player at exactly the moment he is trying to work out why the shot
is refused.

Outside the flat-beam case `_laser_trace` still walks over a trench occupant at **zero
potential cost**, labelling him "over the trench".

`AIPlanner._fire_ease` passes the flat-beam flag too, so the planner models the rule the
resolver enforces; without it the AI kept promising its marksman shots that were then
refused.

### 6.7 Line of sight

`los_blocked(from, to)` walks `Combat.line_cells`:

- Walls (height ≥ 2.0) block — **except** `FEATURE_HEDGEHOG_SANDBAGS` at distance ≤ 1,
  which is treated as a lattice you can shoot through from an adjacent cell.
- **`FEATURE_DOT_OPEN` at distance ≤ 1** is likewise transparent (#86): the embrasure
  pillbox is a firing slit, so anyone pressed against it shoots through — but only from
  an adjacent cell, never from range. The third argument `allow_embrasure` turns this
  off for the **Anti-Tank** (`can_shoot` passes `not _is_anti_tank(shooter)`, and
  `can_blast_cell` passes `false` outright): a rocket does not fit through a slit.
- Vehicle hulls block **line of fire** (#47) — but not **sight** (batch 13 #1, §11).
- **Living units block** — unless the caller passes `ignore_units = true`. Since #100
  `can_shoot` does exactly that: a body no longer *forbids* the shot, it *intercepts* it
  (§6.9).
- **Corpses do not block** (#15) — an explicit author decision.

### 6.8 The shooting gate

`can_shoot(shooter, target)` returns **`""` when the shot is legal**, otherwise a
human-readable reason. It is the same function the UI uses to highlight valid targets
and the AI uses to filter its options, so the two can never disagree. In order:

| Check | Refusal |
|---|---|
| Target alive | "No target" |
| Not the shooter himself | "Can't shoot yourself" |
| Visible through fog (§11) | "Target not visible" |
| On the firing line (§6.2) | "Target not on the firing line" |
| Not trench-protected | "Target is below the trench line" |

Then it branches by ability: the **Marksman** returns legal immediately (the laser has
unlimited range and pierces obstacles); the **Flamethrower** checks jet length and
`_wall_between`; everyone else falls through to `los_blocked` and the range test.

Separately, `shot_is_futile` (#69) tells the AI when a shield bearer would absorb the
shot outright, so it never spends an action on a shot that cannot possibly land.

### 6.9 Friendly fire (#100)

A bullet does not know whose uniform it is passing. Two rules implement this:

1. **You may aim at anyone but yourself.** `can_shoot` refuses only `target.id ==
   shooter.id`; owner is not checked at all. `shootable_target_ids` therefore offers
   friendlies to the UI, while the separate `hostile_target_ids` gives the AI the
   enemies-only list it wants (§17.1).
2. **The shot is redirected, not blocked.** `first_unit_on_line(from, to)` returns the
   first **living** unit standing strictly between the two cells (endpoints excluded, and
   anyone `trench_protected` is skipped — the bullet flies over him, §6.6). If there is
   one, `_resolve_shoot` **replaces the target with that unit** before any dice are rolled,
   and logs `"X fires through Y — the shot hits them instead!"`. All burst bookkeeping and
   the `dice_events` name the *actual* victim, so the log never lies about who was hit.

Exempt: the **Marksman** (the laser pierces bodies by its own rules, §7.3) and the
**Flamethrower** (the jet covers the whole line anyway, so everyone on it already burns).
Area weapons needed no change — `_blast` has always killed everyone inside the radius
regardless of side.

---

## 7. Special Attacks & Abilities

**There are no separate intent classes for the special attacks.** They all arrive as a
`ShootIntent` and `_resolve_shoot` branches on the shooter's `special_ability_id` into
`_resolve_anti_tank`, `_resolve_flame`, `_resolve_laser`, or `_resolve_assault`.
`ShootIntent` carries `target_id`, `shots` (−1 = full rate of fire, otherwise a
fragmented burst), and an optional `target_cell` — the sentinel `(-999, -999)` means
"no cell", and a real value lets anti-tank, flame, and laser aim at **empty ground**
rather than at a unit.

### 7.1 Anti-Tank (§3.13)

Shell auto-kills all infantry in `blast_square(landing, ANTI_TANK_BLAST_RADIUS = 1)`
(a 3×3). Can target an empty floor cell. On a **miss** the shell falls short along the
firing line and **still detonates**:

```gdscript
land_index = clampi(int(dist * roll / float(need)), 0, dist)
```

A vehicle takes damage only from a **direct hit** — the charge must land *on* its
footprint (`_damage_vehicles_in_area(area, center, …)` checks `center` against the hull,
item 16). A blast in the next cell over shreds the infantry around the vehicle and leaves
its armour untouched; splash from a mine, a drone, or another vehicle's detonation never
damages a hull at all.

**A cell with someone in it is checked like any other (team-session batch, items 4 and
8).** `can_blast_cell` used to accept any cell holding a living unit before checking
anything else — firing line, walls, range. The AI asks it while scoring shells, so a
soldier's cell (a tank passenger's, typically) was a legal target from any angle: Hard AI
fired along lines the rules forbid — the "non-diagonal weird lines" — and rolled checks
that needed 7+ on a d6. The shortcut is gone; an occupied cell passes the same line, wall
and range checks as an empty one. `tests/run_team_session.gd` pins it.

### 7.2 Flamethrower (§3.8)

Projects a **6-cell** jet, igniting each floor cell with `shooter.owner` as
`fire_owner`. On hitting a wall or a shield, the remaining length **splashes**:
`left_count = ceil(remaining / 2.0)`, the rest goes right. **A side the wall cuts short
hands its unburned cells to the other side (batch 17)**, so the jet burns six cells
whenever the board allows — a diagonal jet into a straight wall used to lose the half of
its splash that ran back into the same wall. `flame_cells(from, step)` is the one
geometry for the shot, the preview and the AI; `_resolve_flame` only kills and ignites
what it lists.

### 7.3 Marksman laser (§3.13)

Costs **2 AP** (the whole activation). The marksman fires in a **direction**, not at a
unit (#49): `_step_toward` reduces the aimed cell to one of eight unit steps and the
beam travels forward from there.

**The beam destroys what it pays for (#75).** Potential is a budget of **10**; each
obstacle on the line has a price, and paying it **removes the obstacle** and lets the
beam continue. Anything absent from `MCF.LASER_COST` is passed through for free.

| On the line | Potential | Result |
|---|:---:|---|
| Glass, wooden wall | **0** | Destroyed, beam undiminished (but see the glass rule below) |
| Trench | *(absent from the table)* | **Untouched.** The beam flies **over** the pit — the trench survives and so does whoever is lying in it (#99) |
| Airlock | **1** | Destroyed |
| Every 1 m cover — sandbags, hedgehog, dirt pile, RSP, drone station | **1** | Destroyed (#99) |
| Wall, sandbag wall, hedgehog+sandbags | **2** | Destroyed |
| Nameless terrain wall (`LASER_COST_TERRAIN_WALL`) | **2** | `cover_height → 0` |
| Corpse wall | **3** | Collapses; the 5 bodies **scatter forward along the beam** |
| BRU cell | **4** | Destroyed |
| Living unit (`LASER_COST_KILL`) | **2** | Killed |
| Unit carrying a corpse shield (`LASER_COST_KILL_CORPSE`) | **3** | Killed |
| Shield bearer (`LASER_COST_SHIELD`) | **4** | Killed, and the shield **stops the beam no matter how much potential is left** |
| Vehicle (tank, shuttle) | `durability × 10` | Destroyed if fully paid; otherwise **every whole 10 potential strips 1 durability**, and the beam **dies on the hull either way** |
| Pillbox / embrasure pillbox (either variant) | `durability × 10` = **20** | **10 potential = 1 durability**; if that does not finish the box, it cracks and the beam **stops** |

**Glass refocuses the beam (#99).** Panes are free to break, and every **second** pane
along the line hands **+1 potential back** (`LASER_GLASS_RECHARGE_EVERY = 2`,
`LASER_GLASS_RECHARGE = 1`). The rule is cumulative and uncapped: four panes return 2,
six return 3. A marksman shooting down a glass corridor therefore arrives **stronger**
than he started.

Durability is paid in whole units — `cracks = min(durability, potential / 10)` is integer
division. A beam that arrives with fewer than 10 potential left buys **nothing**: it
cannot crack the box and dies **in front of** it. The same rule holds generally — if the
remaining potential cannot pay for the next obstacle at all, the beam stops short of that
cell rather than partially damaging it. Any record flagged `stop` (shield, vehicle hull,
an unfinished crack) also ends the trace.

`_laser_trace(from, step)` computes this as a **pure, state-free list of records**
(`kind` / `cost` / `label` / `left` / `destroyed` / `cracks` / `damage`). `_resolve_laser`
applies that list, and the UI's aim preview renders the very same list — highlight and
outcome cannot drift apart.

**Aim preview (#99).** While the direction is being chosen, `laser_preview()` returns
that trace and the battle screen draws, for every object on the line, a floating
**`−N`** (or **`+N`** where glass gives potential back) above its cell, plus the running
potential left. The cell where the budget runs out is marked as the **beam's end**, so
the player sees exactly how far the shot reaches before committing 2 AP.

**Naming the part (batch 12 #5).** When the beam's trace reaches a vehicle with damage
to spare, the battle screen opens the component picker for **that** vehicle before
sending the intent — whichever cell was clicked. It used to ask only when the click
landed on the hull itself, so a click past or short of the tank sent the same beam into
the same tank silently, and always into the Hull. The picker lists only the components
visible from the marksman's side (`_aimable_components`), without the "(N+)" roll hints:
a laser burns what it is told to, it does not roll.

**Volley (team-session batch, item 12).** With several marksmen multi-selected, the group
menu offers **Laser Volley** (`Mode.GROUP_LASER`). One click picks the direction — the
eight-way step from the group's centre to the clicked cell (`_volley_dir`) — and every
selected marksman with 2 AP fires his own beam that way from his own cell. Each beam is an
ordinary `ShootIntent`, so lockstep, undo and the log see separate shots.

**Friendly units in the beam ask first (item 13).** Before a beam is sent, the screen walks
the trace the preview draws (`laser_preview`) and collects every own or allied unit on it
(`_beam_friendlies`). If there are any, a confirmation window lists them — type, side and
cell — and the shot goes only on *Fire anyway*; a volley gathers the friendlies of all its
beams into one window. Presentation only: the rules of the beam are unchanged.

### 7.4 Assault (§3.14)

Shotgun chain of up to **3 targets** in a straight line directly behind one another.
Each link rolls `parry_need = armor + 1 − corpse_shield`. The chain **stops at the
first survivor**.

### 7.5 Shield Bearer (§3.14)

Blocks shots and lasers outright. Immune to fire (#50). Shield **push**: the target
rolls at `need = armor + 2`; **failure kills**, success shoves it 1 cell if the space
behind is free. In a blast, a shield bearer outside the epicentre survives and
**protects adjacent friendlies** via `_protected_by`.

### 7.6 Sniper (§5)

Auto-hit (`need = 1`) at distance ≤ `SNIPER_AUTOHIT_RANGE` (12), provided no
fortification lies between. Exempt from the burning-cell penalty. −2 to target defence.
Fires **one** bullet per action.

### 7.7 Miner

Demolishes fortifications at 1 AP each (§9.5). −1 to target defence in melee.

### 7.8 Engineer (§3.7)

Builds fortifications, raises the once-per-match BRU wall, and digs at **6 credits per
AP** instead of 3.

---

## 8. Grab, Carry, Drag & Corpses

### 8.1 Capture (§3.4)

`_resolve_capture` seizes an adjacent unit; the target's `status` becomes HELD and its
`captor_id` is set.

- **Allied grab is uncontested** — no roll (#37).
- **Enemy grab** is an opposed d6, **re-rolled on ties**.

On success `_grant_carry_move` **sets** `move_credit = speed − CAPTURE_CARRY_PENALTY (3)`
(#33). This is an assignment, not an addition — carrying gives a fixed reduced budget.

**The prisoner spends nothing (#76).** Being carried is not an action: the capture only
clears the target's `action_state`, and its `remaining_ap` is left **untouched**. What
stops it acting is `_validate_actor`, which now refuses any intent from a held unit with
*"Unit is being held — break free first"*. The old implementation zeroed the prisoner's
AP instead, which had two bugs: the whole turn was burnt even after escaping, and the
"Break Free" button (it requires `remaining_ap > 0`) could never be pressed at all — a
grabbed unit was held forever.

**One grab per soldier per round (#100).** `_resolve_capture` refuses a target whose
`carried_this_round` flag is already set — *"Target was already grabbed this round"* — and
sets that flag on every successful grab, allied or opposed. The flag already existed on
`UnitInstance`, was already snapshotted by `GameState` and already cleared by `reset_ap()`
at the top of each round; it simply had no reader until now, so **no new state was
introduced**. Without it a relay of carriers could pitch one prisoner across half the map
in a single turn: grab, drop, next man grabs, drop, repeat.

**Shifting a captive is free (#100).** `MoveHeldIntent(actor, to)` moves an **already
held** prisoner to any cell adjacent to the captor (validated by `_valid_carry_drop`,
listed for the UI by `carry_drop_cells`). It costs **no AP and no move_credit** — the
captor does not step anywhere, he just passes the body from one hand to the other. If the
destination is on fire the captive dies there and the death is reported in
`ActionResult.deaths`. `update_airlocks()` re-runs afterwards, since a body can be set
down inside a doorway.

### 8.2 Release

**A captor's death frees the captive (batch 12 #1).** `_kill` — the resolver's single
death point — looks up `held_unit_of(victim)` before marking the corpse and sets the
captive back to `ALIVE` with `captor_id = -1`, logging "X is free — Y is dead". Without
this the captive stayed HELD pointing at a corpse: unable to act and unable to break
free, because `_resolve_release` looks for a living captor.

Escaping an **allied** captor is free and needs no roll (#37). Escaping an enemy costs
1 AP and requires a **4+**.

### 8.3 Drag

`DRAGGABLE_FEATURES = [sandbags, hedgehog, dirt_pile]`, plus corpses — and every *heavy*
single-cell piece of furniture (`GameActionResolver.grabbable_cell`, §9.9), which keeps its
durability on the way. Nothing that is part of a multi-cell structure (a bed, a table, a
segment joined to its counter or shelf) can be grabbed; portable furniture is carried,
not dragged (§9.9).

- Corpses pile up; at `CORPSE_WALL_COUNT = 5` the stack becomes a **corpse wall**.
- Stacking table: `{ sandbags: { sandbags → sandbag_wall, hedgehog → hedgehog_sandbags } }`.
- A drag that doesn't stack leaves the object **in hand**, and grants `_grant_carry_move`
  the same way a grab does.
- `resolve()` drops the `dragging` flag on any intent that isn't Move or Drag (#34).

### 8.4 Corpses as objects

Corpses occupy cells, can be grabbed and dragged, form walls at 5, and each **carried**
corpse grants `+1` to the carrier's defence (`_corpse_shield_bonus`). Corpse markers
and textures appear **only after a real death** (#6, #71, #72) — never pre-spoiled by
the renderer.

**One count per tile (#98).** Corpses used to live in two places — a body could be the
cell's `occupant` *or* a tick in `corpse_count`, and the two disagreed. Everything now
goes through `corpses_at(coord)` (read) and `_add_corpse_to_cell(coord)` (write), which
is the only reason stacking can be counted at all.

**Stacking, capped at 5 (#98).** A tile holds up to **5** bodies. `_add_corpse_to_cell`
refuses the sixth, so `_resolve_drop_corpse` and every death that would overflow spill
onto a neighbouring cell instead. The renderer draws **one** corpse marker per tile with
a small **count** next to it once there is more than one.

**The fifth body is a wall.** Reaching 5 turns the cell into `FEATURE_CORPSE_WALL` at
full `WALL_HEIGHT`: it blocks movement and line of sight exactly like any other wall,
and it grants cover through the ordinary `cover_height` path (a corpse merely *lying* on
the ground still grants nothing, #97).

**Blowing it up scatters the bodies.** A blast — or a laser paying the corpse wall's 3
potential — collapses the wall and throws the **5 bodies onto random empty tiles**
nearby. The scatter draws from `DiceService`, so it is part of the recorded roll stream
and the client replays the identical layout (§22.1). Bodies that find no free tile are
simply lost.

**Dropping a corpse is free (#99).** `_resolve_drop_corpse` validates with `credit = 1`,
so it works at **0 AP**. The button and the red target tiles were always offered
regardless of AP; before this the resolver quietly refused and the click looked inert.

---

## 9. Fortifications & Terrain Objects (§3.7)

### 9.1 Feature table

| Feature | Height | Notes |
|---|:---:|---|
| Sandbags | 1.0 | Soft cover; draggable; stacks |
| Sandbag Wall | 2.0 | Two sandbags stacked |
| Anti-Tank Hedgehog | 1.0 | Build 2 AP; draggable; **cannot be stood on — jumped over for 2** (§5) |
| Hedgehog + Sandbags | 2.0 | Blocks LOS **except** at distance ≤ 1 |
| Dirt Pile | 1.0 / 2.0 | `DIRT_HEIGHT_PER_LEVEL = 1.0`, `DIRT_MAX_LEVEL = 2` |
| Trench | **0.0** | Height 0; protection via `TRENCH_DEPTH = 2.0` (§6.5) |
| Wall | 2.0 | Blocks move and sight |
| Glass | 2.0 | Wall; defends at `GLASS_ARMOR = 5` vs grenades (#44) |
| BRU | 2.0 | Engineer's 6-tile deployable wall; **black** (#85); **fireproof** (§10) |
| Wooden Wall | 2.0 | **Flammable** — catches fire and burns away |
| Corpse Wall | 2.0 | 5 stacked corpses |
| Airlock | 2.0 / 0.0 | Opens when a living non-drone is within radius 1 |
| RSP (Machine Gun) | 1.0 | Range 12, RoF 8, fired from an adjacent cell (#28) |
| Pillbox (Concrete) | 2.0 | Reinforced concrete; build 2 AP; **durability 2** (§9.8); fireproof |
| Pillbox (Embrasures) | 2.0 | Same box with firing slits — adjacent soldiers shoot through it, anti-tank cannot (§6.7, #86) |
| Drone Station | 1.0 | Blocks standing; spawns drones (#28); deploying one **launches a drone** (§13) |

### 9.2 Build costs (`ENGINEER_BUILDABLE`)

| Cost | Features |
|:---:|---|
| 1 AP | Sandbags, Wall, Glass, Airlock, BRU, RSP |
| 2 AP | Hedgehog, Pillbox, Embrasure Pillbox |

Both pillbox variants are on the engineer's build menu and in the map editor's palette
(tags `PBX` and `PBX+`).

### 9.3 BRU wall (#58, #80)

Engineer-only, **once per match** (`bru_wall_used`). Exactly **6 distinct buildable
cells**, **one** of which must be adjacent to the engineer.

**All six must form a single orthogonally connected chain** (#80) — this **reverses**
the original no-connectivity rule. The BRU is a sectional structure: sections mate on
their faces, so diagonal contact does not count and the tiles cannot be scattered around
the map. `bru_cells_connected(cells)` is a 4-directional flood fill over the proposed
set, and it is **public on purpose**: the placement UI calls the same function to refuse
a disconnected tile, so the highlight can never disagree with the resolver
("BRU tiles must form one orthogonally connected chain").

Raising the wall **extinguishes fire** under every section it covers (#82). The BRU is
also **fireproof** — fire neither burns it away nor spreads through it (§10). It renders
as a solid **black** block (`BRU_COLOR`), distinct from the grey concrete structures
(#85). When the engineer has spent it, a small pixelated **"!"** is drawn beside them.
The same badge (`unit_missing_equipment`) marks a flamethrower without its extinguisher
grenade, a machinegunner without its frag, and — inverted by request in batch 17 — a
**drone operator whose station is deployed** (`operator_has_station`); an operator still
carrying the station has no badge.

### 9.4 Airlocks (§3.11)

`update_airlocks()` runs at the top of **every** `resolve()` — and, since #100, **again
right after a unit finishes a move**, so a doorway that has just been vacated shuts at
once instead of hanging open until somebody's next action. An airlock's height is **0.0**
if any living non-drone unit is within `AIRLOCK_OPEN_RADIUS = 1`, otherwise
`WALL_HEIGHT`. Radius 1 includes **distance 0**: standing inside the doorway holds it
open.

**A closed airlock is not a wall to a route (#100).** Height alone made `is_wall()` true,
so every path planner treated a shut door as solid and nobody ever walked through one.
The fix is a three-layer split, and everything reads the same predicate:

| Layer | Function | Question it answers |
|---|---|---|
| `GridCell` | `airlock_opens()` | is this an airlock that will still part for someone? (welded ⇒ no) |
| `GridCell` | `walkable_terrain()` | is the **terrain** passable on foot? (`airlock_opens()` or not a wall/blocker) |
| `Grid` | `blocks_walk(coord)` | terrain **plus** occupancy — a unit, corpse-wall or vehicle hull |

`Movement.enter_cost`, `_resolve_move`, `carry_drop_cells`, the AI's geodesic BFS and
`CivilianAI` all go through these instead of `is_occupied_or_wall`. The doorway also costs
`FLAT_MOVE_COST`, not a climb: reading a shut airlock's 2 m `cover_height` as a wall to be
scaled would have charged a soldier for vaulting a door that simply slides aside. A
**welded** airlock fails `airlock_opens()` and therefore stays impassable forever, exactly
as #99 intends.

**A body in the doorway holds the doors (batch 13 #4).** `update_airlocks()` treats a corpse
*on the airlock cell itself* (`corpses_at(cell) > 0`) as a permanent "open": the doors
cannot close on a body, and they stay open until somebody drags it out. A corpse on the
threshold *beside* the doorway does nothing. Welding such an airlock is refused
("A body is jamming the doors — drag it out first") and `weldable_cells` never offers it.

**Welding (#99).** An **engineer** standing next to an airlock can weld it shut for
**1 AP** (`WELD_AIRLOCK_AP`, `WeldAirlockIntent`). The cell gains `airlock_welded`, its
height snaps to `WALL_HEIGHT` immediately — even with the engineer himself standing
there — and `update_airlocks()` skips it from then on: the doors never part for anyone
again. The flag rides in `GameState.snapshot`/`restore` (so Undo restores it) and in
`IntentCodec` (`T_WELD`), and it is cleared only by `clear_feature()`, i.e. by
demolishing the airlock outright. `weldable_cells(unit)` lists the adjacent unwelded
airlocks and drives both the menu button and the highlight. This is how a corridor gets
sealed without spending an engineer's whole turn building a fresh wall.

### 9.5 Demolition (`BREAKABLE`)

Wall, Glass, Airlock, BRU, Corpse Wall, **both pillbox variants**, Sandbag Wall,
Hedgehog+Sandbags, Hedgehog, and nameless terrain walls. **Miner or Engineer**, 1 AP
each — demolition ignores durability, so a pillbox falls to one miner action even though
it soaks two shells.

### 9.6 Digging

`_resolve_dig` digs a trench under the digger (distance 0) or in an adjacent cell —
including **under another unit** (#43).

- Requires capacity for **2 dirt loads**: `_dirt_capacity = DIRT_MAX_LEVEL − dirt_level`
  (#51). The digger chooses where the spoil goes.
- The **first** dig spends 1 AP and opens `dig_credits` = **3** (normal) or **6**
  (engineer). Subsequent digs inside that AP are free.
- The flow is **3 clicks** by design. It is load-bearing elsewhere in the UI and is not
  to be "simplified".

### 9.7 RSP

An **enemy** RSP can be seized for 1 AP. Your own RSP fires **8 shots from the RSP's
cell** at range 12, subject to every normal gate (LOS, cover, trench, shield).

### 9.8 Durability and the unified damage scale (#89)

MCF has **one** damage scale, and it is anchored on the vehicles that were already in
the data:

```
1 durability = 10 laser potential = 1 drone explosion = 1 anti-tank shot = 0.5 tank shots
```

Since milestone 14 a vehicle's durability is split across components (§16.2b), so this
scale describes what one point *costs*, not how many points a vehicle has: the laser
still buys one point per 10 potential, the anti-tank still takes 1 and the tank gun 2 —
they simply now land on a named component rather than a single pool.

`POTENTIAL_PER_DURABILITY = 10` makes it explicit — a shuttle (2 durability) is 20
potential, a tank (6) is 60, which is exactly what the laser-potential table prescribes.

Fortifications now sit on the same scale. `GridCell.feature_durability` is seeded by
`MCF.feature_durability(id)` when the feature is placed; **0 means "no durability"** —
i.e. the object is removed by any hit that reaches it, which is every feature except the
pillbox. Both pillbox variants carry `DOT_DURABILITY = 2`.

**Direct hits are absorbed whole.** `_pillbox_absorbs(center, damage, res)` runs *before*
any blast is applied — for the anti-tank shell, the drone detonation, and the tank
cannon alike. If the landing cell holds something with durability:

1. it loses `damage` durability (1 for anti-tank and drones, 2 for the tank gun);
2. at 0 it collapses (`clear_feature`), otherwise it logs *"absorbs the hit and
   cracks"*;
3. the function returns **true and the explosion never happens** — no blast area, no
   area damage, no deaths.

So a soldier standing on the cell next to a pillbox **survives** a rocket aimed at the
pillbox. The absorption is keyed on the **landing cell only**: a shot that merely lands
*near* a pillbox is an ordinary explosion, and `_blast_destroy_terrain` skips any cell
with `feature_durability > 0` — splinters do not chip concrete (#17).

The laser uses the same currency rather than a special case: every full **10** potential
strips 1 durability (§7.3). A marksman firing down a **clean line** arrives with the full
10, so one shot cracks the pillbox and a second levels it; a beam that spent potential on
obstacles first arrives with less than 10 and cannot crack it at all (§7.3). A cracked
pillbox is drawn with a **red notch** in the corner of its tile.

### 9.9 Furniture (§3.15)

Furniture is an ordinary **cell feature** — `GridCell.feature_id` is the piece's id, its
height is `cover_height`, its durability `feature_durability`. There is no second grid,
no node per piece and no separate save path: movement, sight, cover, the undo journal,
`StateCodec`, the network, replays and the tile chunks all see furniture the way they
see sandbags.

**Multi-cell pieces.** A cell still holds one object, so a large piece is several cells of
the same id that join up by autotiling (`join` in the table):
- *whole* pieces — bed (1×2, 2×2), sofa (2×1, 3×1), desk and office desk (2×1), dining
  table (2×1 to 3×2), conference table (3×2, 4×2), wardrobe, dresser, generator, machinery
  (2×2, 3×2), examination table, bench, park table, dumpster, piano (2×1), bunk bed (1×2),
  fuel tank (2×2). The piece is the group of
  same-id cells joined side to side (`Furniture.piece_cells`): it is smashed, wrecked and
  drawn **as one**. No shared id is stored, so the generator never puts two whole pieces
  of the same kind side by side (they would read as one).
- *runs* — kitchen counter, reception and checkout counters, bookshelf, display shelf,
  filing cabinets, lockers, workbench, storage shelving, server racks, industrial
  cabinets. Each cell is a segment; neighbouring segments join into one long counter or
  shelf, and a segment is smashed or burnt on its own.
Every cell keeps its own height and durability.

**The table** is `src/data/Furniture.gd` (`_BASE`, 54 types in four palette groups —
*Home*, *Office & shop*, *Industrial*, *Outdoor*; 0.9.2 added toilet, sink, console,
practice target and vent fan). Each row gives name, height class,
material, durability, mobility (`PORTABLE` / `HEAVY` / `FIXED`), AP to smash, preferred
rooms, preferred spot (`wall`, `corner`, `center`, `free`) and whether the generator uses
it. A new piece is a new row plus, optionally, `textures/<id>.png`.

**Colours.** `VARIANTS` gives some pieces extra colours — beds, bunk beds, sofas,
armchairs, generators, lockers, tool cabinets, barrels, vending machines, dumpsters, bins,
fuel tanks, the piano. A variant is its own id (`bed_red`) with `base` pointing at the
row it copies: same rules, its own tile. `DEFS` is `_BASE` plus the variants. Two cells
of different colours never join, so a red bed and a blue bed side by side are two beds.
The generator places the base id and picks the colour itself (`Furniture.variant`),
once per recipe step, so a row of bunks comes out one colour. The editor palette
keeps one button per piece, and a *Colour* row under the brush name switches the
variant.

| Height | Pieces (examples) | Movement | Shooting past it (cell next to the target) |
|---|---|---|---|
| 0.5 m | chair, nightstand, coffee table, crate, pallet, toolbox, trash bin, bed, bench | climb, 2 points | no modifier |
| 1.0 m | desk, dining/conference table, counters, filing cabinet, locker, workbench, barrel, ammo crate | climb, 3 | −2 (the ordinary `COVER_MOD`) |
| 1.5 m | wardrobe, bookshelf, refrigerator, server rack, industrial cabinet, generator, dumpster | climb, 4 | **−3** |
| 2.0 m | storage shelf, vending machine, machinery | wall: impassable, blocks sight and fire | — |

The −3 lives in `Furniture.COVER_MOD` and applies **only** when the covering cell holds
furniture (`cover_effect_from`). `MCF.COVER_MOD` still knows only 1.0 m, so a bare 1.5 m
terrain step, a dirt pile or any other object gives exactly what it gave before.
Movement costs and wall behaviour are not furniture rules at all — they come from
`cover_height` through `CLIMB_COST` and `WALL_HEIGHT`. `blocks_move` in the table is
derived (height ≥ 2.0), and a test holds it to that.

**Mobility.**
- *Portable* (chair, nightstand, coffee table, crate, pallet, toolbox, trash bin, potted plant — all
  durability 1, so a carried piece has no damage to remember): **Carry Furniture** picks
  an adjacent piece into the hands (`CarryIntent`, 1 AP — like folding a drone station);
  hands must be empty (no item, corpse or captive), and shield bearers, borgs, drones and
  seated passengers can't. **Put Down** sets it on an adjacent empty cell for free
  (`UseItemIntent` with the piece in `held_item_id`); never onto another object, a body,
  a hull or open space. A carrier who dies loses the piece.
- *Heavy* single-cell pieces (armchair, cabinet, refrigerator, barrel, a lone locker or
  shelf segment, …) drag exactly like sandbags (§8): **Grab** → the piece, then a cell; it
  stays in tow while the dragger walks (−3 move). Its durability travels with it.
  **Nothing that is part of a multi-cell structure can be grabbed** — not a cell of a bed
  or a table, not a segment joined to its run (`grabbable_cell`; refused with *"Too big to
  move"*). A segment left alone (its neighbours smashed) is a single cell again and can be.
- *Fixed* (built-in counters, server rack, generator, machinery, vending machine, street
  cabinet, park table) cannot be carried or dragged.
Nothing ever moves furniture by walking into it.

**Smashing.** Any soldier — not just a miner or engineer — can **Break Furniture** in an
adjacent cell (`BreakIntent`, the same intent and cell clear as demolition): 1 AP for
ordinary pieces, 2 for large, 3 for heavy industrial (`ap` in the table) — once for the
whole bed or table, per segment of a run. The floor stays; the cells drop to height 0 and
leave debris decals. The AI does not smash,
carry or drag furniture (§17 is unchanged; it walks, climbs and takes cover over it like
over any other object).

**Weapons** converge on the same durability:
- every **explosion** whose area touches a piece **destroys it whole**, whatever its
  durability (0.9.2 — there used to be survivors: a generator outlasted two blasts and a
  frag grenade never touched furniture at all). Frag grenades included: furniture in
  their X goes. Furniture does **not** absorb a direct hit the way a pillbox does
  (`_pillbox_absorbs` skips it): the blast happens in full.
- the **laser** burns through a piece for its current durability in potential (a chair 1,
  a wardrobe 3, a generator 5) and carries on, or stops in it if it can't pay.
- **fire**: wood, fabric and plastic catch like a wooden wall (3/6) and burn away with
  the cell; metal never catches from spreading fire (`FIRE_NEVER`), and a flame jet
  scorches the cell but leaves the metal piece standing.
- **tracks** flatten furniture like every other object under a hull.
- ordinary bullets do not damage furniture — the game has no bullet-versus-object damage
  outside armoured glass, and none was invented.

When an explosion or the laser destroys any cell of a *whole* piece, the whole piece goes
(`_destroy_furniture`); fire and tracks take cells one by one, as they do with everything.
A damaged cell (durability below the table's) is drawn with cracks baked into its tile.

**Drawing.** Pieces are baked into the `TerrainTiles` chunks like walls (so they are known
under fog, as the plan of a building is). The art is drawn from above with the back of
the piece at the top. A single piece turns so its back faces the first adjacent wall, a
chair faces its table. A multi-cell piece uses a 4×4 autotile sheet
(`<id>_autotile.png`) drawn in the piece's own frame: the tile is chosen by the same-id
neighbours *in that frame* and then turned with the piece — a whole piece turns as one
(a bed with its head, i.e. its short side, to a wall; a sofa or desk with its long side;
a table along its long axis), a run follows its row and its wall. In the editor and on the
deployment screen a change to any cell of a whole piece re-bakes the whole piece, so its
cells never disagree.
**In battle, furniture does not re-join.** When the match opens, the battle screen
snapshots every furniture cell's look: its joins, inner corners and turn
(`TerrainTiles.freeze_furniture` → `furniture_look`, held by `Main` so a resync, a fog
switch or a replay rewind keeps it). From then on each cell is drawn as the generator or
the editor built it. Half a bed flattened by tracks stays half a bed. A counter with a
smashed segment stays two cut-off ends. A blown-out wall doesn't turn the wardrobe
beside it. A piece that lands on a new cell during the battle (dragged there) joins
nothing and keeps the turn it lands with. This is drawing only: whole-piece smashing and
Grab still read same-id neighbours (`piece_cells`, `grabbable_cell`). A save loaded
mid-battle freezes from the loaded board.
Changing durability now writes the cell into the look log, so a cracked piece re-bakes.
Far-zoom colours, map previews and the editor minimap use the pieces' own tones.

**Saving.** `feature_id`, `cover_height` and `feature_durability` already went through
`GridCell.image()` (undo), `StateCodec` (save, resync) and replays. `MapData` gained a
sparse `feature_dur` — `{cell: [id, durability]}`, written as `feature_durability` only
when a map has damaged furniture, applied only while the same id stands on the cell, so
an ordinary map saves byte for byte as before.

---

## 10. Fire (§3.8)

`advance_fire(owner)` spreads to the **4 orthogonal** neighbours of every burning cell:

- Flammable floor or wooden wall: ignites on **3+**
- Any other floor: **4+**
- **Blocked entirely** by space, **BRU** (#84), and both pillbox variants — `_fire_blocked`
  refuses to ignite those cells at all, so a BRU section neither burns nor lets fire past
- An occupant of an igniting cell **dies**, unless it's a shield bearer (#50)
- **Nothing burns in vacuum (editor-rework).** `_ignite` — the only way a cell catches
  fire — refuses space cells, so neither the spread nor the flamethrower lights them. A
  jet passes over a gap without burning a unit floating there; floor beyond still burns.

**Fire eats the structure on the cell it takes (#83).** Anything in `BURNS_AWAY` is
cleared the moment the cell ignites:

```gdscript
const BURNS_AWAY := [FEATURE_WOOD_WALL, FEATURE_WALL, FEATURE_GLASS, FEATURE_AIRLOCK]
```

The frame gives way, glass shatters, the airlock jams and burns out — the tile is left
as **open flame with no cover**, which is what makes a fire genuinely open a breach.
BRU is deliberately *not* on the list: it never ignites in the first place.

**Fire is permanent, but building over it puts it out (#82).** Nothing in the resolver
extinguishes a burning cell by itself, and the extinguisher grenade still douses an
area — but `_extinguish_cell` is now called from every path that puts something solid
on a burning tile:

| Path | Why |
|---|---|
| `_resolve_build` | a fortification presses down on the fire |
| `_resolve_build_wall` (each BRU section) | same, six cells at once |
| `_resolve_dig` — trench **and** each spoil heap | the ground is turned over, and the dug-out earth smothers whatever it is dumped on |
| `_resolve_drag` / dragged object arriving on a cell | a dragged sandbag or hedgehog snuffs the flame |

Shooting *through* fire is `FIRE_SHOOT_PENALTY` to hit (snipers exempt).

`state.combat_started` is a **latch**: set by the first shot or explosion anywhere on
the map, never cleared. Civilians key off it (§14).

---

## 11. Fog of War (§3.9)

| Function | Purpose |
|---|---|
| `_seen_from(coord, r, viewer)` | Everything visible from a cell to the eyes of side `viewer`: a Bresenham ray to every cell of the board. **A wall-height cell that is not glass blocks** — a wall, a closed airlock, a BRU, a pillbox — and so does the hull of an **enemy tank** (below); **living units, corpses, other vehicles and your own or allied tanks do not**. Sight is unlimited in range and in direction (batch 13 #1). |
| `_vehicle_seen(veh)` | A vehicle's eyes are its **crew's**: an empty or wrecked vehicle sees nothing. It looks out from **every hull cell**, so a tank in a doorway sees round both jambs. |
| `team_sees(owner, coord)` | Visibility is **shared across the whole team**. |
| `is_visible_to_team(owner, target)` | The targeting gate used by `can_shoot`. |
| `team_visible_coords(owner)` | The set the renderer uses to draw the fog overlay. |

**Tanks block the enemy's sight — and only tanks, and only the enemy's.** A living tank's
hull (all 3×3 cells) blocks the line of sight of every side that is neither its owner nor
an ally: the enemy cannot see — and so cannot target — anything behind it, while the
tank's own side looks straight through (its crew and the infantry around it see as
before). The tank itself stays visible: a ray ends *on* its near hull cells. Shuttles and
borgs never block; a **wreck** blocks no one (it is no longer a tank); a **captured** tank
blocks its former owner. The same rule applies to the single-line check
`_vision_blocked(a, b, viewer)` (the sapper's mine sweep). Line of *fire* is unchanged;
the omniscient AI (#43) is unaffected, as it is by all fog. Because the answer now
depends on who is looking, the per-cell sight cache is keyed by the exact set of enemy
tank cells as well (`_tank_sig`: one number per distinct set, never reused); a tank
moving, changing hands or burning bumps `UnitInstance.vision_epoch`, so the team fog
notices on its own.

**How sight is computed — the same answer, without walking the rays.** The ray is this
Bresenham variant: `err = dx − dy`; step x when `2·err > −dy`, y when `2·err < dx`. Along
the major axis its cell in column *i* is exactly `(i, ⌈i·s − ½⌉)` with `s = minor/major`
— the slope rounded half *down* — so a blocker at column *i*, row *j* hides exactly the
cells beyond column *i* whose slope lies in `((2j−1)/2i, (2j+1)/2i]`. `_sweep_seen` walks
the eight octants column by column, keeps the blocked slopes as merged intervals of exact
integer fractions, marks a cell visible when its slope is outside all of them, and stops
an octant once slopes 0…1 are all blocked. It works in **row ranges**, not cells: a
blocked interval `(lo, hi]` hides exactly the rows `a·lo < b ≤ a·hi` of column *a*
(exact integer floor division), so the visible rows are the gaps between those runs and
each gap is written out at once as a progression of indices; the walls of a column are
found by a byte search over a copy of the wall table in which that column is contiguous
(transposed for the octants where it runs along a grid column). The old cell-by-cell
sweep is kept in `tests/run_fog.gd` as a reference and must agree with it — visible and
sensitive cells both — on 800 random boards. The result is the identical set, in the
identical order, as the per-cell ray it replaced — `tests/run_fog.gd` checks that on 600
random boards and on real generated maps with tanks, and a one-character change to the
tie rule fails it on half of them. One soldier's unlimited sight on a 250×250 map went
from ~175 ms (town) / ~364 ms (field) to ~23–27 ms, and to ~9 ms in a station, where
walls close every slope early; a Large town went from 3.2 ms to 0.5 ms.

**Why hulls stopped blocking (batch 13 #1).** A tank used to look out from its `origin`
— the top-left hull cell — and its *own* hull blocked the ray, so it saw only up and
left: the "weird FOV" in the report. The rule became `GridCell.blocks_sight()` — a wall and a closed airlock (glass
excepted, #29) — and a vehicle's *own* hull never blocks its own view (the enemy-tank
rule above is per viewer, so it cannot bring that bug back). Because hulls do not
change the terrain, `vehicle_id` does not bump `vision_version`; instead
`Vehicle.origin` / `owner` / `wrecked` bump `UnitInstance.vision_epoch`, which is what
tells the team-fog cache that a vehicle moved. A wall turned to glass at the same
height bumps `vision_version` from the `feature_id` setter — the height setter cannot
see that change.

**Which cached views a changed wall touches.** Sight is unlimited, so every soldier's
window is the whole map, and invalidating cached views by window meant that any airlock
opening anywhere recomputed every soldier's sight — with doors on every room, that was
most actions. The sweep therefore also returns the view's **sensitive cells**: the cells
whose slope interval `((2j−1)/2i, (2j+1)/2i]` is not wholly inside the slopes already
blocked by nearer walls. Only a change on a sensitive cell can change that view: if a
target behind cell *c* changes visibility, its ray runs through *c* with everything before
*c* clear, so its slope is open at *c*'s column and lies in *c*'s interval. Cells beyond the
column where an octant closed completely are never looked at and never marked. The cache
drops exactly the views that list a changed cell (`_catch_up_seen`, a binary search per
entry), keeps entries in least-recently-used order and evicts the oldest instead of
clearing everything when it fills (8192 entries or 16 M stored cells, `SEEN_CELLS_CAP`),
patches the wall table (`_blockers`) from the vision log instead of rebuilding it, and
caches a vehicle's merged hull view as one entry. When an **enemy tank** moves, changes
hands or burns, the set of tank cells a side must look past changes and so does the key
of every view — but a view whose sensitive cells include none of the cells the tank left
or took is still exact, and is reused under the new set without a sweep (`_reuse_under`,
over the side's last few sets). The team counts are a flat array; a
moved soldier's new view is added before the old one is taken away, so cells seen both
before and after never leave the set, and the scouting memory grows only on the cells that
just became visible. `tests/run_fog.gd` flips unmarked cells on 500 random boards and
checks the view never changes, and compares the incremental team view with one built from
scratch after every action of a game full of airlocks.

- **`fog_enabled` defaults to `true`** on the resolver; the Setup screen turns it off
  (#12 made the checkbox default to off at the UI level). With fog disabled,
  `is_visible_to_team` is unconditionally true.
- Hidden enemies are neither drawn nor targetable.
- **`omniscient_side` (#43)** is the AI's own owner id. It affects
  `is_visible_to_team` — that is, **targeting legality only**. It deliberately does
  *not* feed `team_visible_coords`, so the player's fog overlay is unchanged: the AI
  sees through fog, but the player's screen never reveals that it does.

---

## 12. Space & Zero Gravity (§3.11)

In cells flagged `is_space`, firing (anti-tank excepted) knocks the shooter back **1**
cell and the target back **2**. `_apply_zero_g` / `_knockback` are **all-or-nothing**:
if any cell along the knockback path is obstructed, no displacement happens at all.

---

## 13. Drones (§3.12)

- Deployed from a drone station; armor 5+, flight budget 30.
- **Deploying the station launches a drone with it (#77).** `_resolve_use_item` calls
  `_launch_drone_at(target, operator)` immediately after planting the station, so the
  operator does not have to spend a second action to get airborne. `SpawnDroneIntent`
  still exists for relaunching after the drone is spent, and both paths share the same
  helper, so placement rules ("nowhere to place the drone", "drone already airborne")
  cannot diverge.
- A drone **spawns on top of its station** (#22) and does **not** take the cell's
  `occupant` slot (#13) — the station cell stays walkable-through for occupancy logic.
- `operator_controls` requires the operator to be **alive** and at distance **exactly 1**
  from the station.
- `_drone_reach` is an 8-directional Dijkstra with **ortho 1 / diag 2**, budget 30, a
  tether of ≤ 30 cells from the home station, and burning cells treated as terminal.
- **A drone hovers over walls but never crosses them (#96).** Wall cells are *reachable*
  and *terminal*: the Dijkstra may land on one but never expands out of it, so a wall is
  a perch, not a corridor. On arrival the drone records `wall_entry_from`, and while it
  sits on the wall `_drone_reach` offers exactly **one** destination — back the way it
  came. Without that memory the drone would creep across a wall cell by cell and come
  out the far side. Walls are therefore no longer ram targets in `_approach_cell`; the
  point of perching is to **detonate on the wall**, which levels it (§9.5, `_blast`).
  The AI skips wall cells when routing its drone — for hunting people they are dead ends.
- **Coming back down is free (#99).** A drone has 2 AP. Climbing onto the wall cost one
  and the descent cost the other, so peeking over a wall consumed the drone's entire turn
  and returned it to the exact cell it started from — a full round for zero movement. The
  descent is now part of the *same* hop: `_resolve_drone_move` charges nothing when the
  drone is on a wall and the target is its recorded `wall_entry_from`, and it lets that
  move happen even at **0 AP** (otherwise a drone that spent its last point climbing
  would be stranded on the wall until the round ended). The battle screen mirrors this —
  the button reads **"Descend"** instead of "Fly" and stays enabled at 0 AP. Ramming
  still costs a point, so this cannot be used for a free attack.
- **Self-detonates** when an enemy is within blast radius 1; otherwise flies toward the
  nearest enemy.

---

## 14. Civilians (#42, #56, #79)

Civilians are Neutral-owner units that receive **real initiative slots** — and, since
#79, actually **use** them: they hunt the nearest soldier and shoot him.

**What makes a civilian an NPC is the side, not the profession (#96).** `CivilianAI.is_npc`
is `owner == NEUTRAL and special_ability_id == "civilian"`, and every civilian rule below
keys off it. A civilian **bought with deployment points enters as an ordinary soldier of
the buying side**: the player selects and orders him with normal intents, he counts toward
that army, he cannot shoot his own side (the standard "Can't shoot your own" gate applies),
and `advance_civilians` never picks him up (he *can* now be shot at by his own side like
anybody else — see friendly fire, §6.9). Only a civilian **authored on the map as
Neutral** is driven by `CivilianAI`, hostile to everyone, and outside both armies' counts.
The AI's heuristics respect the same split — the "don't waste bullets on civilians"
discount applies to NPCs only, so a bought civilian is targeted like any other enemy.
Stats are identical either way: speed 9, armor 5+, range 12, RoF 1, 20 points.

- `_update_breached(civ)` — latches "breached" when `state.combat_started` is true **or**
  the civilian has its own clear LOS to a combatant. Once latched, it stays. A passive
  civilian is not a bug; it has simply not been uncovered yet.
- `advance_civilians()` — plays NPC civilians **one at a time**, each running its whole
  activation before the next begins. Held civilians are skipped. It returns an
  **`ActionResult`**, not bare log lines (#96): a civilian's turn has to be *watchable*.
  See "Presentation" below.

**The civilian brain is the AI, with the owner set to Neutral (#103).** Everything above
this line used to have a second implementation: `_civilian_activate` / `_civilian_move` /
`_civilian_clear_corpse` / `_civilian_shoot` in the resolver, plus `step_toward`,
`pick_target` and `soldier_distance_field` in `CivilianAI`. It was a strictly worse copy
of the army AI — it moved a civilian **one cell per activation**, knew nothing about the
turn plan (§17.0), fragmented movement (§3.4), partial bursts or corpses in the road — and
every rule fix had to be written twice or it silently applied to soldiers only. All of it
is deleted. `advance_civilians` now:

1. Wakes and refills the block (`_update_breached`, `reset_ap` for anyone whose slot
   arrived before the round boundary that would have refilled it).
2. Holds one `AIController(MCF.Owner.NEUTRAL)` on the resolver — **one** instance, so the
   commander plans the block's whole slot once instead of re-planning per action.
3. Loops `_decide()` → `resolve()` until the brain answers `EndTurnIntent`. A denied
   intent calls `notify_intent_denied` (the same recompute would produce the same order,
   so the actor leaves the queue) and the loop continues.

The Neutral side is not a special case inside `AIController`: `_enemies_of` is "everyone
whose owner differs from mine", which for Neutral is **both armies**, and civilians never
shoot each other because they share an owner. Two adjustments carry the §3.10 rules into
the shared brain:

- `_can_command(u)` — an **un-breached** civilian is immovable, so it is skipped by the
  executor; `AIPlanner._plannable_units` drops it for the same reason, which keeps it out
  of the destination assignment entirely.
- `_activity_quota()` returns **1.0** for Neutral against `MIN_ARMY_ACTIVITY = 0.8` for an
  army (§17.2) — "every civilian must move or do something" is literal, while a soldier
  may legitimately hold a rear position.
- **Breached civilians are ruthless (playtest-20).** The old survival priority (get off a
  firing lane, run for cover, retreat, grab a corpse shield, unless outnumbered 1.75×) is
  gone. `_neutral_candidates` offers a corpse pickup first (any body on a neighbouring
  cell, up to the carry limit), then a shot (infantry or vehicle) and a move that closes
  on the nearest enemy; the move skips the staff plan and the cover bonus. Neutrals never
  put a body down. Fire is still avoided — walking into it is suicide, not an attack.

A civilian therefore walks its **whole speed** in one order, banks the remainder as
`move_credit` and spends it after shooting, fires partial bursts, hauls corpses aside and
piles them (§8.4, §17.3), and routes through closed airlocks — because those are the
army's rules and there is now only one implementation of them. `CivilianAI` is reduced to
`is_npc` and `is_soldier`: identification, not behaviour.

- A civilian **carrying a corpse moves at half speed**, and one that walks into fire
  burns.
- **A civilian's shot uncovers the block.** Any `ShootIntent` sets
  `state.combat_started = true` at the top of `resolve()`, so a civilian's bullet breaches
  every other civilian on the map exactly as a soldier's would.

Civilians act **outside the intent stream**, which is why the network layer has to ship
their dice explicitly (§3.2, §22) rather than letting each peer roll its own.

**A civilian shoots by the ordinary rules (#99, #103).** There used to be a private
`_civilian_can_shoot` that delegated to `CivilianAI.can_attack` with only an LOS
predicate — no firing-line gate. That looked like a deliberate "civilians may shoot
off-axis" licence, but it was the opposite of one: `Combat.line_cells` returns an **empty
array** for a pair of cells that is neither orthogonal nor diagonal, so `los_blocked`
answered "clear" for exactly those pairs. The result was a civilian shooting **through
walls and cover at any angle**. #99 made that private check run the same four gates as
everyone else; #103 deleted the private check outright, because a civilian's shot is now
an ordinary `ShootIntent` through `_resolve_shoot` and there is nothing left to keep in
sync. The gates are therefore the shooting gate itself (§6.8):

1. `Combat.is_on_firing_line` — the target must lie on one of the eight axes.
2. `los_blocked` — the line must be clear.
3. `trench_protected` — someone lying in a trench is reachable only point-blank, and by a
   flat beam not even then (§6.6).
4. `_shield_blocks_shot` — a shield bearer is not worth a bullet.

The shot goes through the same modifier stack as any other: target `cover_effect` (hit
penalty **and** defence bonus), the carried-corpse defence bonus, and `FIRE_SHOOT_PENALTY`
for fire on the line. Those modifiers are listed in the dice event, so the defender sees
*why* the roll is what it is.

**Where NPC civilians come from (#99).** A **neutral zone painted on a map is a
neighbourhood, not a deployment area**: `MapData._fill_neutral_zone` (called from
`build_state`, before `begin_match` rolls initiative) puts a civilian on **every**
stand-on-able cell of the neutral zone. Space, vehicles, features, walls and occupied
cells are skipped. **How many of them reach the board is the lobby's *Civilians* slider
(team-session batch, item 11):** `GameConfig.civilian_count` (0–`CIVILIANS_MAX` 200;
`civilians_enabled` is now just `count > 0`) caps every neutral spawn of the map — painted
zones, placed residents and generated ones alike. `build_state` keeps an even spread in
map order (the same choice on every peer), not the first N. Authors mark the block once instead of placing residents one spawn at a time —
and the placement screen already refuses to deploy into a neutral zone, so the quarter
stays civilian.

### 14.1 Presentation: a civilian turn is played, not applied (#96)

The rolls were always made — they were just made *silently*, inside the resolver, and the
board jumped straight to the outcome. To the player that read as civilians teleporting
across the map and half a squad dropping dead at once. The simulation is unchanged; what
changed is that the civilian slot now **reports what it did** so the battle screen can
replay it through the ordinary dice pipeline (§18.5):

- A civilian's shot is `_resolve_shoot`, so it emits the standard `"attack"` dice event
  including `def_owner`. That single field is what makes the defending player **roll for
  their own defence by hand**, exactly as against any other shooter. (Before #103 this was
  a hand-written copy of the same event inside `_civilian_shoot`.)
- Each relocation emits a `"walk"` event carrying `from` and the **cell-by-cell path**
  (computed *before* `move_occupant`, or the route would be read off a changed grid).
  `Main._play_walk` seeds `_walk_cells[unit_id]` and advances it one cell per
  `WALK_STEP_DELAY`, so the civilian is *seen* walking. `_walk_cells` is a **draw override
  only** — state has already moved, so this cannot affect the simulation or lockstep.
- Kills go into `ActionResult.deaths`, which feeds `_pending_death_ids`: the corpse
  appears only **after** its defence die lands (#46), never before.
- **Who is acting is stated, not inferred (#103).** `advance_civilians` prefixes each
  civilian's action with a `{"kind": "focus", "unit", "coord"}` marker, and
  `Main._play_dice` uses it to pan the camera to that civilian if it is off-screen
  (`_ensure_visible`; the zoom is left alone — the player chose it). Walk and AP events
  alone were not enough: a civilian that merely **shoots** takes no step, and the second
  volley of a burst costs no AP (§3.4), so the dice rolled with nothing on screen to
  attribute them to. Like every other dice event, the marker is a presentation record —
  never serialised (§22.1) and never read by the simulation.
- `play_civilian_slots()` merges the slots into one `ActionResult`. `_resolve_end_turn`
  carries it out with the turn hand-off, and in a network match `NetGame.opening_civilians`
  carries the opening slot to `_on_initiative_synced`. Resolution still happens **inside**
  the atomic `resolve()` / `announce_initiative()` call, so host and client consume the
  same dice in the same order — the lockstep contract (§22.1) is untouched.
- **The AP dots drain one at a time (#99).** A civilian burns its whole activation before
  playback starts, so the yellow pips used to vanish all at once, before the first die
  even rolled — the player could see a body drop but never what it cost. `_ap_event`
  appends a `{"kind": "ap", "unit", "from", "left"}` record whenever a unit's AP changes,
  and `Main._play_dice` rewinds `_ap_display[unit_id]` to the pre-action value, then steps
  it down as each event plays (`AP_DOT_DELAY`). `_apply` does the same for a single
  intent, which is what makes an **enemy's** dots visibly drain too. `_ap_display` is
  consulted only by `_draw_ap`, i.e. it is a **draw override**; the simulation never reads
  it, and `dice_events` are never serialised (§22.1), so none of this can desync.

---

## 15. Items & Grenades (§3.6)

A unit's `held_item_id` is seeded from its stats' `default_item_id` at spawn. **The item
is consumed on use regardless of outcome** — a missed grenade is still gone.

| Item | Carrier | Effect |
|---|---|---|
| `frag_grenade` | Machinegunner | Blast, see below |
| `fire_extinguisher_grenade` | Flamethrower | Douses fire in its area |
| `drone_station` | Drone Operator | Deployable station (§13) |
| `bru` | — | `MCF.ITEM_BRU` exists as an id, but **no unit carries it**. The Engineer raises the BRU through the build menu (§9.3), not by holding an item. |

### Frag grenade

- Range `GRENADE_RANGE = 12`, thrown **orthogonally only** (#4).
- On a miss it **falls short** along the throw line and still detonates.
- Blast shape is `blast_x` — the **X / diagonal-only** pattern (#64), deliberately
  distinct from the anti-tank square and the cannon diamond.
- **Epicentre** = automatic death, except a shield bearer.
- **Other cells**: the target rolls **two dice** at `armor + 1 − corpse_shield` and must
  pass **both**.
- **Glass** defends at `GLASS_ARMOR = 5`, also on 2 dice (#44).

### Blasts in general (`_blast`)

Auto-kill across the area, except shield bearers outside the epicentre (who also protect
adjacent friendlies). `_blast_destroy_terrain` removes wall, glass, airlock, BRU, wood
wall, corpse wall, drone station, RSP, sandbags, sandbag wall, hedgehog+sandbags, and —
since #97 — the bare **hedgehog** and **dirt pile** as well, so a shell no longer leaves a
chequerboard of low cover standing where it flattened the stone wall beside it.
**DOT survives blasts** (#17). A nameless terrain wall is flattened to `cover_height 0`.

---

## 16. Vehicles

### 16.1 Data (`VehicleDB`)

| Vehicle | Size | Hull | Crew | Speed | Facing | Cost | Model |
|---|:---:|:---:|:---:|:---:|:---:|---:|---|
| Tank | 3×3 | 8 (+ tower, tracks, gun) | 3 | 16 | yes | 500 | crew off-board, own AP pool |
| Space Shuttle | 2×2 | 4 | 4 seats | 30 | no | 125 | **seated** — passengers sit in the hull cells (§16.7) |
| Borg | 1×1 | 2 | 1 | 9 | no | 100 | **mounted** — the operator stays on the grid and plays as a unit (§16.8) |

`OFFBOARD = Vector2i(-9999, -9999)` marks a unit that is aboard rather than on the map.
Boarding removes it from its cell (`occupant = null`) and moves it there, so
`state.grid.cell(unit.coord)` is **null** for the whole time it rides.

**Every loop over `all_units()` must skip `aboard_vehicle_id != -1` (#95).** The renderer,
the box-select, and the camera centring all do. `_is_own_active` did not, so
`_after_action` reopened the *infantry* menu for the passenger the instant it boarded, and
`_open_menu` went looking for a corpse to pick up at `(-9999, -9999)` — a hard crash on
`Nil`. A passenger has no ground presence and no infantry menu; it leaves only through
**Disembark** on the vehicle's own menu. Public helpers that take a unit and read its cell
(`corpse_pickup_cell`, `corpse_drop_cells`, `has_corpse`) null-check the cell for the same
reason.

### 16.2 Crew and capture

- Units may board **enemy** vehicles.
- `_recompute_vehicle_owner` hands the vehicle to whichever side holds a **strict
  majority** of the living crew.
- `_vehicle_crew_ap(veh)` counts **only owner-side living crew** — a contested vehicle
  with no majority does nothing.
- Crew seats hold living crew; `corpse_slots` hold the dead separately.

### 16.2b Modular armour — a tank is four separate machines (milestone 14)

A vehicle is no longer one pool of durability. It is a set of **independently damageable
components**, and only one of them can end it:

| Component | Tank | Shuttle | Borg | At 0 durability |
|---|:---:|:---:|:---:|---|
| Hull | 8 | 4 | 2 | The vehicle is finished — crew die, destruction roll, wreck |
| Tower | 6 | — | — | Fires only along its **last shot's direction** until repaired |
| Left Track | 4 | — | — | See below — one track stops it driving, not turning |
| Right Track | 4 | — | — | |
| Main Gun | 4 | — | — | Cannot fire the cannon |

**The shuttle and the borg are hull-only (batch 13).** The shuttle's shared track pool is
gone ("Shuttle changes" §6): every aimed shot at a shuttle is a Hull shot at 2+, and the
cascade has nothing to skip.

**A tank has two tracks, and they are not interchangeable.** Driving needs *both*;
turning needs *either*. So one broken track leaves a tank that can still traverse to
bring its gun round but cannot go anywhere, and two leave it frozen in place and facing.
A shuttle has no facing — "left" and "right" mean nothing without a front — so it keeps
a single shared track pool.

`Vehicle.durability` still exists and still means "is this thing alive", but it is now
literally the Hull cell of `Vehicle.components` — a synonym, not a second number, so the
two can never drift apart. A component the vehicle does not have (a shuttle's tower)
is absent from the dictionary and is skipped everywhere a destroyed one would be.

**Aimed attacks** (tank cannon, AT gunner) resolve in this order:

1. The existing **to-hit roll**. A miss falls short and explodes on the ground; per
   §16.4 it never damages the vehicle it was aimed at.
2. The attacker **names a component**, and rolls against its threshold **with +1**:
   Main Gun 5+, Tower 4+, Tracks 3+, Hull 2+ — so an aimed Hull shot cannot miss, and
   the choice is a real one: the Hull is the guaranteed point but needs eight of them,
   while the Tracks are riskier and disable in four.
2b. **The side you shoot from decides what you can hit.** A track is a flank
   component: from the tank's left only the left one can be aimed at, from its right
   only the right, and from dead ahead or behind, both. Ties — an exact 45° approach —
   count as the flank. The **main gun** is hidden from anyone standing behind where it
   points (its last shot's direction; before its first shot, along the hull), though it
   is plainly visible in profile from the side. This applies to the cascade as well as
   the aimed roll: a shell arriving from the left cannot clip the right track even by
   accident, because the hull is in the way. A drone detonating **overhead** has no
   side and picks freely.
3. On a failure the hit **cascades** Main Gun → Tower → Tracks → Hull at the *base*
   thresholds — the +1 is a reward for the declared choice, not for the whole queue —
   skipping the named component and every destroyed one.
4. If every check fails, the last surviving component is hit anyway. Once step 1
   connects there is no "hit the tank and damage nothing" outcome.

**Overkill runs into the Hull.** A tank cannon deals 2; against Tracks sitting on 1 that
is Tracks to 0 and one point into the Hull. Damage aimed at a component that is already
gone goes to the Hull whole. Nothing is ever silently lost.

**Fixed-target sources** skip the whole sequence:

| Source | Where it lands |
|---|---|
| Drone detonation | Component **chosen by the player**, 1 point, no rolls at all |
| Miner prying at the hull | **Hull**, 1 point, on a natural 6 |
| Anti-vehicle mine | **Tracks**, 1 point, no roll (Hull if the tracks are already gone) |
| Personnel mine | Nothing — it is an anti-personnel weapon and no longer touches vehicles |
| Marksman laser | Component **chosen by the marksman**, 1 point per whole 10 potential |
| Shield-bearer halting a vehicle | **A track**, 2 points |
| Driving over hedgehogs | **A track**, 2 points, once per move however many are crushed |
| Another vehicle detonating nearby | Normal cascade, no aim bonus |

**Crew are only ever at risk from Hull hits.** A non-lethal one gives a single crewman
the existing survival roll (`max(1, armour − 1)`, the +1 for being under armour); a Hull
taken to 0 kills the crew outright with no roll. Tower, Tracks and Gun hits never touch
them, however many land.

**Repair.** An Engineer standing on the ground beside an own or allied vehicle spends
1 AP to return **1 point to a component of his choice**, never above its starting value.
Several Engineers can work on the same vehicle in the same turn, and a component
crossing back above 0 re-enables its capability immediately — repair the tracks and the
tank drives that same turn. A Hull at 0 is not repairable: that is a wreck, not a fault.

**Capture** is unchanged in cost (boarding an empty enemy vehicle is the usual 1 AP) and
preserves the component state exactly — capturing neither repairs nor resets anything.

### 16.2c Armored wall and armored glass (milestone 14.1)

Two materials that look like their ordinary counterparts and are placed from the map
editor like them.

**Armored wall** is a wall in every visible respect — 2 m, blocks movement, sight and
fire. What makes it armoured is what *cannot* remove it: not a miner's pick, not fire,
not a tank's tracks (it stops vehicles outright rather than being flattened), not the
splinters of a blast next door, and not a marksman's beam, which dies on it whatever
potential is left. Exactly one thing destroys it: an explosion landing **on** it, which
takes it out whole. Its splash immunity lives in one place — it is simply absent from
`_blast_destroy_terrain`'s destructible list.

**Armored glass** is ordinary glass in every respect — you see through it, shoot
through it, a beam passes it, and it burns away when the tile ignites — save for its
save: against bullets it holds on **4+** where ordinary glass holds on 5+ (§16.2d). A
blast rolls a single die against 4+ rather than ordinary glass's two against 6+.
Everywhere the rules treat glass as special they ask `MCF.is_glass()`, so both kinds
travel together.

### 16.2d Shooting at and through glass (0.9.2)

**At a window.** Shooting a window is an ordinary burst: 1 AP starts it, the player picks
how many bullets to fire (1 … rate of fire, or All), and the rest of the burst can be fired
later without AP — at the window again or at anyone else (`ActionState.WINDOW`). Each
bullet rolls **to hit the window** like a shot at a target (`pane_hit_need`: the distance
table, the sniper's own ladder, fire on the line −1; no cover), the window **saves**
against every bullet that hit it (ordinary 5+, armored 4+), and if at least one bullet got
through, the window shatters.

**Through glass.** When glass stands between the shooter and the target, the burst meets
the panes **one by one, from the shooter**: (1) the bullets still flying roll to hit the
pane — a miss hits the frame or the wall around it and is gone; (2) the pane saves against
each bullet that hit it; (3) if one got through, the pane shatters — its dice show first,
then the shards fly, before anything further is rolled; (4) only the bullets that got
through fly on, to the next pane or to the target, where the usual to-hit and defence
rolls follow. Bullets of one burst fly together, so they all meet each pane intact. Both
kinds of glass count (armored glass on the line used to be skipped). The dice show each
pane as its own step (`"kind": "glass"` events); a burst that dies in the glass shows no
target roll at all. The laser and blasts keep their own glass rules.

### 16.3 Movement

**Bodies survive the tracks (batch 12 #2).** A vehicle driving over a cell no longer
clears its corpse occupant or `corpse_count`; only a *living* occupant is crushed (and
becomes a corpse on the same cell). A corpse **wall** stops being a wall — the feature is
cleared — but its five bodies stay as a loose pile of `CORPSE_WALL_COUNT`. A body under a
standing vehicle cannot be picked up (`corpse_pickup_cells` skips vehicle cells and
`_resolve_pickup_corpse` refuses); once the vehicle moves on, it is an ordinary corpse.

`_resolve_vehicle_move` crushes, scatters, or rams everything in the footprint's path,
reducing those cells to bare floor. Tanks have a `facing`; shuttles do not.

**An airlock is a doorway, not a shelter** (item 9). `VehicleRules.cell_entry` used to
answer an airlock cell and return there and then, which cost two rules at once: the doors
were never marked as rammed, so a tank drove through them and left them standing, and the
occupant check below was never reached, so a man caught inside an open airlock survived
the tracks. An airlock is now an ordinary crushable obstacle — rammed like glass, and the
cell's occupant is crushed exactly as on open ground.

**A crushed unit leaves a body** (#97). It is killed, its id goes into
`ActionResult.deaths`, and once the track-clearing pass has scrubbed the path, its corpse
is placed back as the cell's `occupant` — the same corpse a bullet would have left, so it
can still be picked up, dragged, or stacked into a wall. Order matters: the clearing pass
walks the very same cells, so putting the body down first would erase it.

**Boarding is not a refuel** (item 4). A vehicle's AP is set from its living
owner-side crew at the start of its activation. Someone climbing in mid-turn adds *his*
point but does not restore points the vehicle already spent — `veh.ap` becomes
`min(veh.ap + 1, crew)`, not `crew`. Before this, a tank that had driven and fired was
back to full the moment a passenger boarded, which read on the board as AP markers that
would not go away.

**Tracks leave a mark** (item 1). Everything the footprint flattens — rammed walls,
crushed cover, scattered bodies — is reported to the cosmetics layer as `debris`, the
same event an explosion sends, so the tiles read as destroyed instead of reverting to
clean floor. Purely visual: the cells were already cleared before.

**Vehicles finish partial moves like infantry** (#97). `Vehicle.move_credit` mirrors
`UnitInstance.move_credit` under §3.2 action splitting: a fresh Move spends 1 AP and banks
`speed − cost`, and any later Move that turn spends the banked points instead of AP. The
credit is cleared at the start of the owner's turn, and `vehicle_move_credit()` reports it
as **0 whenever the vehicle has no living owner-side crew**, so a shot-out tank cannot coast
on movement its dead driver never spent. `vehicle_move_targets` budgets off the same helper,
which keeps the highlighted cells identical to what the resolver will accept.

**Turning to the direction already faced is refused at zero cost** — `VehicleTurnIntent`
returns "Already facing that way" before touching AP. The bug reported against this (#96)
was in the *renderer*: `_facing_degrees` mapped only the cardinal directions from a table
and defaulted every diagonal to 0°, while `facing` is chosen from all **eight**. A tank
turned north-east spent its AP and was still drawn pointing north, which read as "the turn
did nothing but cost me an action". The angle is now computed
(`rad_to_deg(Vector2(facing).angle()) + 90°`, the sprite being drawn nose-up).

### 16.4 Tank main gun

- Range 30, 1 AP, **2 damage to vehicles**, max **2 shots per round**
  (`cannon_shots_this_round`).
- Must fire through a valid `cannon_port` (#62) and pass `los_blocked` (#58, #70).
- Rolls to hit; on a miss the shell **falls short** and still detonates.
- Blast is `blast_diamond(landing, 2)` (#63).
- **The tank's secondary laser was removed** (#63). The cannon is its only weapon.

### 16.5 Damage and destruction

`_apply_vehicle_damage` applies points one at a time; for tanks each point triggers
`_tank_crew_hit`. At 0 durability `_destroy_vehicle` emits a **visible** `check` dice
event so the player watches the roll (#68):

| Vehicle | Roll | Result |
|---|---|---|
| Tank | any | Leaves a **wreck** (blocks movement and LOS) |
| Tank | 4+ | **Additionally explodes**, radius 2 (diamond) |
| Shuttle | any | Leaves a **wreck** |
| Shuttle | 1–2 | **Additionally explodes**, radius 1 |
| Borg | any | Leaves a **wreck** |
| Borg | 4+ | **Additionally explodes**, 3×3 square |

**Every vehicle leaves a wreck, exploded or not (batch 17).** An explosion runs through
the same `_blast` as an anti-tank charge: everyone in the area dies (shield / trench
protections apply), fortifications in the area are demolished, and the floor under and
around the hull is scorched (`debris` decals with the epicenter texture) — the wreck sits
on the scorched floor. Before this a shuttle vanished on any roll and an exploded borg
left nothing.

### 16.6 Shuttle data is wired now

The old unread `driver_move_ap` / `passenger_defense_bonus` /
`collision_durability_threshold` keys are gone from `VehicleDB`; what replaced them is
the seated model below (`"seated": true`, `MCF.SHUTTLE_CELLS_PER_AP = 15`,
`MCF.SHUTTLE_PASSENGER_DEFENSE_BONUS = 1`).

### 16.7 The seated shuttle (batch 13, "Shuttle changes")

A shuttle has **four seats, one per hull cell** (`Vehicle.SEAT_OFFSETS`, top-right is the
**driver's seat**). A passenger is not parked off-board like tank crew: they **sit in the
hull cell** — `coord` is the seat cell, they are the cell's `occupant`, they are drawn on
top of the hull, and `aboard_vehicle_id` marks the shuttle. Everything else follows from
that one fact:

- **Boarding is free (0 AP, allowed at 0 AP — batch 17)** from any cell adjacent to the hull into a chosen free seat
  (`VehicleBoardIntent.seat`, `-1` = first free, the driver's seat first). The UI
  **always asks which seat** (batch 14) — from the vehicle menu and from the soldier's own
  *Board* button alike — and labels the driver's seat, so a player can deliberately take
  the wheel or deliberately stay off it. **Changing seats costs 1 AP**
  (`VehicleSeatIntent`); **exiting is free** and goes through your own side — any free
  cell adjacent to *your seat's* hull cell (`vehicle_disembark_cells(veh, unit_id)`).
  Shield bearers and corpse carriers cannot board; enemies can (the majority rule of
  §16.2 still decides who owns it).
- **Driving is paid by the driver.** There is no crew AP pool (`_vehicle_crew_ap` is 0
  for a seated vehicle): a Move may cover `move_credit + 15 × driver AP` cells, and the
  driver pays **1 AP per 15 cells or part** (`MCF.SHUTTLE_CELLS_PER_AP`); the unused
  remainder of the last paid AP is banked in `move_credit`. `vehicle_ap(veh)` is the
  driver's AP; with nobody alive in the driver's seat the shuttle does not move.
  Passengers ride along (`VehicleRules.cell_entry` treats a unit whose
  `aboard_vehicle_id` is the moving vehicle as part of it), a body under a seat is folded
  into the cell's `corpse_count`, and a station in a seat moves with the hull.
- **Passengers fight from their seats** with their own weapon, AP and rules: the firing
  line, LOS and range are measured from the seat; `los_blocked` never lets a hull block
  a line that starts or ends on that hull. Fellow passengers **block** the line like any
  other unit — nobody shoots through the soldier in the next seat. Grenades, the laser, the flame jet and the AT
  rocket all work from a seat. Only what needs the floor is refused
  (`_aboard_allowed`: move, grab, build, dig, weld, repair, mines, boarding another
  vehicle).
- **Passengers are targets.** Anyone with a firing line and LOS to the seat cell may
  shoot them; small arms roll against their armour **+1 for the hull**
  (`SHUTTLE_PASSENGER_DEFENSE_BONUS`). They cannot be grabbed.
- **Heavy hits** (AT shell, cannon, drone, mine, a neighbour's detonation): the passenger
  on the **landing cell dies outright**, every other passenger of that shuttle inside the
  blast area **rolls a plain defence** (`_shuttle_passengers_hit`, ordinary `check` dice
  events), and the hull takes its usual damage on a direct hit. Passengers are exempt from
  the blast's general auto-kill so that rule can apply.
- **A dead passenger keeps the seat** (`_kill` drops them from `occupants` but not from
  `seats`). A unit standing next to *that* hull cell pulls the body out for 1 AP
  (`VehicleUnloadCorpseIntent`) and it lies down beside them.
- **Drone station in a seat.** A seated operator plants their station into an empty
  adjacent seat (1 AP, `station_place_cells`); the seat is marked `SEAT_STATION`, the
  hull cell carries `FEATURE_DRONE_STATION`, the drone launches from it, is controlled
  from any adjacent seat, may land back on it, and packing the station up frees the seat.
  When the shuttle moves, the station moves with it **and so does its drone**
  (batch 14): every drone tethered to that station gets the new `home_station`, and a
  drone that was sitting on the station is carried to the new cell. Before this the drone
  stayed behind over empty floor and lost its operator.
- **Hull 0**: passengers die where they sit, the seats empty, the destruction roll of
  §16.5 is unchanged.
- **The AI** boards its shuttle on the first turn, flies toward the enemy with the driver's
  AP and, after the vehicle queue, activates every passenger for shooting only
  (`_passenger_candidates`).

### 16.8 The borg (batch 13, "Borg characteristics")

A borg is a **1×1 vehicle bought for 100 points** that is *played as a unit*. Boarding it
(free — 0 AP, allowed at 0 AP, batch 17 — from an adjacent cell; shield bearers and corpse
carriers cannot; a fresh soldier climbs in and has the full 3 AP) does not take the
operator off the board: they **stand in the borg's cell** with `borg_id` set, the borg's
`origin` follows them after every resolved action (`_sync_borgs`), and its hull footprint
is **not registered on the grid** while someone alive is inside — so it is transparent to
lines of fire and to pathing exactly like a soldier, and cover applies to it like a
soldier. Empty, or with a dead operator inside, it *is* registered as a hull so it can be
clicked, boarded and shot.

While inside, the operator's numbers come from the borg via
`UnitInstance.speed()/armor()/fire_range()/rate_of_fire()/max_ap()` — the only way
those stats are read anywhere any more:

| | Any unit | Engineer |
|---|---|---|
| AP per activation | 3 | 3 |
| Move | 9 | 9 |
| Armour | own threshold −2 (4+ → 2+) | −2 |
| Weapon | **range 12, RoF 4** replaces the base gun; abilities stay (laser, jet, rocket, chain, sniper auto-hit) | own gun |
| Fire | immune (`is_fireproof`) | immune |
| Trenches | cannot enter (`reachable_for` adds them to the avoid set) | same |
| Mines | AV mine: hull −1, stops there; personnel mine ignored | same |
| Builds | — | **batches**: 1 AP buys 3 credits of one type from wall / glass / airlock / sandbags / hedgehog, spent one at a time between other actions, expiring at the end of the round (`build_credits`); pillbox 1 AP; trenches 6 per AP as before |

Everything else a soldier does — grab, carry, dig, items, drone launch — still works.
**Exit** costs 1 AP to a free adjacent cell and leaves the borg on the cell as a hull.
Small arms never touch the hull: bullets go at the operator. Heavy weapons landing on the
cell kill the operator outright and take 1 hull point (2 for the cannon); other passengers'
rule applies to the operator in the blast area (a defence roll). At **hull 0** the operator
dies, then a d6: **4+ explodes** — a 3×3 auto-kill square like an AT shell, flattening
terrain, and nothing is left; **1–3 leaves a wreck** on the cell. **Overtaking**: boarding a
borg whose operator is dead pushes the body onto a free neighbouring cell. **No corpses in
a borg**: a soldier carrying a body cannot climb in (the Board option is not offered), and
the operator cannot pick bodies up. The AI boards an
empty borg it finds next to it (the first-turn "fill your vehicles" rule) and then fights
with the operator as with any soldier; it does not buy them.

---

## 17. Artificial Intelligence

Since #100 the AI is **two layers**: an `AIPlanner` that lays out the whole turn before a
single man moves, and an `AIController` that plays it out one Intent at a time.

### 17.0 The commander (`AIPlanner`, #100)

Once per AI turn, `_sync_turn` calls `plan(state, r, field, vehicle_rows)`. The planner
looks at the army as an **army**, not as a bag of independent soldiers:

- **Every (unit, reachable cell) pair is scored**, not just the cells around one unit.
  `_score_cell` sums: firing opportunities from that cell (`W_FIRE = 30` per enemy it
  could shoot, plus `W_FIRE_EASE = 2` per point of hit-roll comfort), geodesic advance
  toward the enemy (`W_ADVANCE = 3`), cover and trenches (`W_COVER = 2.5`), enemy
  exposure (`W_DANGER = −5`), and path length (`W_STEP = −0.15`). Standing still is worth
  `W_STAY = 2`, so nobody shuffles for nothing. A cell **adjacent to fire** scores
  `−1e9` — it is never chosen (#48).
- **Firing lanes are army property.** `_lane_conflicts` counts how many friendly lines of
  fire a cell would stand in. Blocking one costs `W_LANE_BLOCK = −20`; **stepping out of
  one is worth `W_LANE_CLEAR = 14`**. This is what makes a soldier walk aside so the man
  behind him can shoot. Marksmen are skipped — their laser pierces anyway.
- **Assignment is army-wide and greedy.** All offers from all units are sorted descending
  and consumed in order, one unique destination per unit and **no two men sent to the same
  cell** — otherwise "make room" would be meaningless.
- **Activation order respects dependencies.** If A's destination is currently occupied by
  B, the planner records `waits[A] = B` and runs a bounded topological pass (with cycle
  breaking) so **B vacates before A arrives**. Vehicles are appended at the end: their
  geometry is course-plus-steps, which a single destination cell cannot describe.

The plan reaches the controller as `order` (activation sequence) and `destinations`
(unit → cell). The controller **duplicates** the order before draining it, so the plan
itself survives the whole turn for inspection.

> **Before touching this code, read §27.** Two things here are load-bearing in a way the
> source does not advertise. First, ties between equally-scored cells are broken by the
> *order* rows were generated in, which means the key-insertion order of
> `Movement.reachable`'s dictionary decides where the army stands — a "smarter" priority
> queue changes deployment without changing any rule. Second, `_lane_cells` and
> `_exposure` are precomputed once per plan on the assumption that **nobody moves during
> planning**; if that ever stops being true they must be rebuilt.

### 17.1 The executor (`AIController`)

`AIController` is a greedy tactician. Each call it scores every legal action across all
its units and vehicles, emits the single best one as an Intent, and the host re-invokes
it until it returns `EndTurnIntent`. Movement now starts from the plan: `_plan_move`
returns a `MoveIntent` to the assigned cell (or the reachable cell nearest to it), worth
`SCORE_PLAN_BONUS = 26`; only if there is no assignment does the old per-unit heuristic
run.

Since #100 the AI also **fires like a player**: it iterates `hostile_target_ids` (never
friendlies) but consults `first_unit_on_line` first, and **skips a shot that would be
redirected into its own man or into an NPC civilian** (§6.6). Its geodesic fields read
`walkable_terrain()`, so a closed airlock is a route, not a wall (§9.4).

- **Priority shape:** Shoot > Capture > Move. Shooting favours guaranteed hits; capture
  favours high-value targets; movement favours closing distance and taking cover.
- **Target value:** special shooters (sniper, marksman, anti-tank) are prioritised;
  civilians are avoided.
- **Geodesic pathfinding:** movement is scored against a **wavefront BFS distance field**
  from the target across all passable cells. Walls and blocking features are impassable;
  living units are treated as passable because they will move. This replaced a
  straight-line heuristic, so units route **around** walls and corners toward openings
  instead of stalling in a local minimum. The same field drives vehicle approach.
- **Futile-shot gate:** the AI calls `shot_is_futile` (#69) and will not fire into a
  shield that would absorb the shot.
- **Miners and engineers breach instead of detouring (#90).** `_best_break` scores a
  `BreakIntent` against any adjacent breakable cell that is **closer to the target than
  the actor is** (`gain > 0`, so it never demolishes scenery off the route), starting from
  `SCORE_BREAK_BASE = 34` plus `3 × gain`. If the enemy is **walled off entirely** — the
  BFS distance field never reaches the actor — the score gains a further **+20**, because
  the alternative is an AI miner shuffling along a wall forever.
- **Held units only struggle.** A captured unit keeps its AP (§8.1), so `_best_for_unit`
  short-circuits to `ReleaseIntent`. `ReleaseIntent` costs 1 AP whether or not the roll
  succeeds, so the attempt always drains AP and the turn terminates.
- **Per-actor queue** with cached geometry fields, so one `resolve()` per call keeps the
  animation pacing readable (`AI_STEP_DELAY = 0.12`).
- **Denial guard:** `AI_MAX_DENIED = 12`. `notify_intent_denied` forces the AI to
  advance rather than re-proposing a rejected intent forever (#60).
- **Difficulty:** EASY adds noise and permits aimless moves; NORMAL is the baseline;
  HARD weights guaranteed hits and cover more heavily.

### 17.2 The army must actually turn up (#103)

The executor was silently losing most of its army. `_best_for_actor` returned an empty
dictionary whenever nothing scored — and something as ordinary as "no reachable cell
strictly improves my geodesic distance" produces exactly that — whereupon the actor was
popped off the queue and never asked again. On an 11-a-side board this routinely meant
three or four men doing anything at all per turn while the rest stood in the deployment
row for the whole match.

`_decide` now makes **two passes** over the turn:

1. The ordinary pass: drain `AIPlanner.order`, taking the best-scoring action per actor.
2. When the queue empties, `_forced_pass` flips and `_idle_rows(state)` rebuilds it from
   everyone who *could* still act and did not. `_acted` (keyed `u<id>`/`v<id>`, cleared by
   `_sync_turn`) is the attendance register.

`_idle_rows` returns **nothing** once attendance already meets `_activity_quota()` —
`MIN_ARMY_ACTIVITY = 0.8` for an army, `1.0` for the civilian block (§14). Beyond the
quota a soldier is allowed to hold his position; below it, the AI is obliged to do
*something* with him. Infantry only: a vehicle is skipped, because its geometry is not a
destination cell.

`_forced_action` is deliberately dumber than the planner — it is the answer to "you must
move, so where?", not "what is optimal":

1. Any reachable non-burning cell, scored by cover minus distance-to-enemy minus
   `SCORE_STEP_COST` per step. This is the same shape as `_best_move` **without** the
   requirement that the step be an improvement, which is precisely the condition that was
   dropping units.
2. Failing that, break an adjacent obstacle; failing that, dig in.

Termination is guaranteed twice over: `FORCED_TRIES_PER_UNIT = 2` caps how often any one
actor may be re-offered, and every action it can pick strictly decreases AP or
`move_credit`.

### 17.3 Partial moves, partial bursts, blasted paths, stacked corpses (#103)

The rules always allowed a soldier to move part way, act, and then finish the move
(§3.4), and to fire part of a burst. The AI could do neither — it read `remaining_ap` as
its only budget, so a unit with `move_credit` but no AP was treated as spent.

- **Movement.** `_move_budget(u)` returns `move_credit` when it is non-zero, else
  `stats.speed` — the same precedence `_resolve_move` uses when charging. `_best_for_actor`
  no longer bails at `remaining_ap <= 0` if credit remains or a burst is pending, and the
  candidate list splits into three tiers: always available (shoot, blast, **drop corpse**
  — that one is free), AP-only (capture, pick up corpse, break), and
  AP-or-credit (flee fire, board a vehicle, move).
- **`SCORE_STEP_COST = 0.35`** is what makes fragmentation *happen* rather than merely
  being possible. Between two cells of equal tactical value the AI now takes the nearer
  one; the unspent speed becomes `move_credit` and is spent **after** the shot, when it
  knows where the bullets landed.
- **Bursts.** `_shots_for` computes the per-shot kill probability from the actual modifier
  stack — `Combat.hit_number` plus cover's hit penalty, against `armor_threshold` plus
  `target_defense_penalty` minus cover bonus minus carried corpses — and orders
  `ceil(1 / p)` shots, clamped to what is available. A near-certain kill costs one bullet
  instead of the whole magazine; a hopeless shot (`p ≈ 0`) falls back to `-1`, the whole
  burst. A pending burst whose target has died **falls through** to ordinary target
  selection, so the remainder is retargeted for free (#5) instead of being wasted.
- **Anti-tank sappers blast a path (#103).** `_best_blast_path` fires only when the enemy
  is genuinely unreachable: either the geodesic field does not reach the actor at all, or
  the detour is worse than `BLAST_DETOUR_FACTOR = 2` times the straight-line distance. It
  then scans the **eight real firing lines** (not a ray toward the enemy — `can_blast_cell`
  requires `Combat.is_on_firing_line`, so an off-axis aim is rejected outright), takes the
  first non-walkable cell beyond `ANTI_TANK_BLAST_RADIUS`, and demands that the cell
  *behind* it be closer to the enemy than the actor is. The blast destroys terrain in its
  3×3 (§7.1), so this is the demolition charge doing sapper work, not a wasted shot.
- **Corpses get stacked, not hoarded (#103).** `_best_corpse_grab` already lifted a body
  out of the road; `_best_corpse_drop` is its other half. It refuses to drop with an enemy
  within `CORPSE_GRAB_ENEMY_RANGE = 8` (a carried corpse is +1 defence, §8.4), and only
  onto a neighbouring cell whose geodesic value is **not lower** than the carrier's — i.e.
  aside, never into its own path — preferring cells that already hold bodies, with a bonus
  for the fourth, which makes the next one a corpse wall (`CORPSE_WALL_COUNT = 5`). Grab
  and drop can never fight over the same cell: grab requires `field[n] < start_geo`, drop
  requires `field[n] >= start_geo`. The pair terminates because a pickup costs 1 AP and a
  drop always decrements `carried_corpses`, capped at `CORPSE_CARRY_MAX = 1` (item 15).

### 17.4 Both sides can be machines (#103)

`GameConfig.p1_is_ai` joins `p2_is_ai`, `Main._make_side(side)` builds either an
`AIController` or a `LocalHumanController` for **either** side, and the HUD carries a
"Player 1: Human/AI" toggle beside the existing one for Player 2 — so an AI-vs-AI match
can be started from Setup or switched on mid-battle. Two consequences had to be handled:

- **Omniscience is a single field, and two AIs do not fit in it.** The AI aims through fog
  (#43) via the resolver's `omniscient_side`, which names exactly one side. The split:
  each AI decision runs on **its own** resolver and marks itself omniscient there
  (`AIController._decide`), so `Main`'s shared resolver only governs what is *drawn*.
  `_refresh_omniscience` therefore turns fog **off entirely** when both sides are machines
  — with no human at the table there is nobody to hide anything from, and the spectator
  gets to watch the whole battle — and otherwise names the one AI side, or nobody.
- **Nobody is waiting for a click.** The old loop only re-invoked the AI *after* a human
  action, so an AI-vs-AI match sat motionless — there was no human to act. `_kick_if_ai`
  runs after setup, after the opening civilian slot, and after every side switch.
  In a networked match the **host** runs the AI slots the same way (§22.4); guests never
  kick a side that is not theirs.

### 17.5 Sappers, mines and the paths that avoid them (batch 12 #3, #4, #7)

**Nobody walks onto a mine they know about.** `Movement.reachable(...)` takes an
`avoid_cells` set; `GameActionResolver.known_mine_cells(owner)` fills it with every
personnel mine that side can see — its own and its allies' always, an enemy's while a
sweep's highlight lasts (`mine_visible_to`). A known mine is neither a step nor a
destination, so the move highlight, the resolver's validation and every AI path agree:
all of them go through `resolver.reachable_for(unit, budget)`, and the bare
`Movement.reachable_for` is no longer called from the UI or the AI. The avoid set joins
the Dijkstra cache key, so a fresh reveal is a fresh flood. Unknown enemy mines still
detonate under foot exactly as before (`_mine_on_path`). Anti-vehicle mines are not in
the set — they do nothing to infantry.

**A mine laid under a standing unit goes off at once.** `_resolve_place_mine` checks the
target cell's occupant: a living unit — friend, foe or the sapper himself — is killed
outright (no roll), the mine is spent and the death is reported with a debris mark.
An anti-vehicle mine laid under infantry simply stays armed.

**The AI sapper** (`AIController._best_mine`) lays a field *in front of* his line while
the enemy is still on the way: candidate cells are `mine_cells(u)` minus his own cell
and any occupied one, must be reachable by the enemy (`GeoField`), at least
`MINE_ENEMY_MIN = 2` steps from the nearest enemy, and no farther from the enemy than
the sapper himself. Chokepoints (few walkable neighbours) score higher, cells adjacent to
an existing own mine score −10 (−3 at two cells) so the field spreads instead of
clumping, and a cell beside a squadmate loses a little. `SCORE_MINE_BASE = 28` sits above
an ordinary approach step and below every shot and grab; the free credit mines of the same
action add `SCORE_MINE_FREE_BONUS = 15`, and `_best_for_actor` keeps a sapper with
`mine_credits` in the queue at zero AP so the whole action is delivered. He lays
anti-vehicle mines while the enemy has more live vehicles than he has AV mines on the
board, personnel mines otherwise, and stops at `MINE_FIELD_CAP = 12` own personnel mines.

---

## 18. The Battle Screen (`scenes/Main.gd`)

### 18.1 Modes

A mode enum drives input: normal selection, move preview, shoot targeting, build
placement, dig placement, BRU placement, drone piloting, vehicle driving, and the
various sub-modes each of those opens.

**Hover previews need their own frame (#97).** Some modes draw a figure anchored to the
cell under the cursor — the grenade radius, the marksman beam, the trench outline, the
corpse drop, the tank's turn arc, the cannon's blast circle. Those modes are listed in
`HOVER_PREVIEW_MODES`, and `_unhandled_input` calls `queue_redraw()` on every
`InputEventMouseMotion` while one of them is active. Without the entry the preview only
appeared when something *else* forced a repaint, which in practice meant nudging the
camera — the reported symptom for the cannon, whose mode was missing from the old
hardcoded list. Add a mode here whenever its `_draw` branch reads
`get_global_mouse_position()`, and only then: the list is meant to be a truthful
statement of which previews follow the mouse.

### 18.2 Undo and redo

- **Undo restores a deep snapshot** (`GameState.snapshot()`) of units, vehicles, turns and
  roster — and, of the board, **only the cells the action touched**. While a player's
  action resolves, `GridCell.journaling` is on and the first write to any cell field
  stores that cell's whole previous look (`GridCell.image()`); the undo entry keeps those
  images, and undo/redo swap them with the cells' current ones (`_counter_snapshot`). A
  full copy of a 250×250 board was 62 500 dictionaries and ~250 ms on every click; every
  cell field now goes through a setter so nothing can slip past the journal.
  `tests/run_incremental.gd` plays twin games — one undoing through the journal, one
  through full board copies — and compares every field of every cell after each of ~700
  actions, 230 undos and 80 redos. Restoration mutates *the same* objects (units /
  vehicles / cells) so outside references — the selected unit in the HUD, for instance —
  stay valid.
- Undo granularity is **one atomic step**: a single BRU tile, a single grab.
- **Redo** (#38) re-applies a popped snapshot.
- **Undo never crosses a turn boundary (#94).** The stack is keyed on
  `_turn_key() = (round_number, active_index)` — the round plus the initiative slot — and
  is cleared the moment that key changes. Comparing the *active player* instead was not
  enough: a side whose opponent has no living units keeps its slot after the wrap
  (`_next_playable_from` skips empty slots), so `active_player()` reads the same on both
  sides of the round boundary while `_reset_all_ap` has already refilled everyone. Undo
  then reached back past the refill and handed a unit its spent AP again.
- **Undo is only offered on your own turn (#94).** `_my_turn()` gates both buttons and
  both handlers, and snapshots are pushed only when `_can_control(actor_before)` — the
  AI's and the civilians' moves are never recorded at all. Previously the AI's own
  snapshots sat on the stack during its turn, which both enabled the button and let a
  click rewind the computer's move mid-turn.
- **Dice are final (#81).** `_is_irreversible(intent, result)` returns true for anything
  that produced `dice_events`, and for `ShootIntent`, `RSPFireIntent`,
  `DroneDetonateIntent`, and `VehicleCannonIntent` regardless. Such an action **clears the
  whole undo stack** rather than pushing a snapshot, so a bad roll cannot be replayed.
  Previously a shot pushed no snapshot but left the stack intact, so pressing Undo after
  firing silently rewound the action *before* the shot — the worst of both behaviours.
- `feature_durability` is carried by `snapshot()` / `restore()` like every other cell
  field, so undoing back past a hit restores a cracked pillbox to full.

### 18.3 Selection

Multi-select (#18, #19, #21) via box drag (`BOX_DRAG_THRESHOLD = 8.0` px), with gating
so that only actions valid for the whole selection are offered. Group control is
**disabled in network matches** (desync risk).

**Group move preview (#88).** In `Mode.GROUP_MOVE` the map draws the union of every
selected unit's reachable set in **green** (`_group_reach_cells`). Hovering a green tile
tints it yellow and drops a **small circle on each cell the group would actually
occupy** if ordered there — the preview and the real order are one `GroupMovePlanner.plan`
call (cached per hovered cell), so the circles are exactly where the units land. The
preview redraws on mouse motion, but only while the left button is up, so it cannot fight
the selection box.

**Group order planner (#114).** The planner simulates the order the resolver will execute:
the unit nearest the destination goes first, and every later unit is planned on the board
as it will be by then — cells its squadmates left are free (`Movement.reachable`'s
`free_cells`), cells they took are blocked — so a unit boxed in by its own squad (the middle
of a blob, the tail of a corridor column) still moves. "Nearest" is steps to the destination
round walls (a wave bounded to where the squad can reach), then straight-line distance, then
the straightest own path; a squad sent beyond its reach advances in formation instead of
sliding to the map edge. Units are never ordered onto a burning cell (unless fireproof), and
the `GroupMoveIntent` list order is the execution order.

**Tactical Move (#114).** The group menu offers *Tactical Move* beside *Move* (cyan preview
circles instead of yellow). Each unit first finds where a plain move would put it, then
takes the most covered cell within 3 tiles of that spot. Cover is judged per visible enemy
by the shooting rules: a trench shields from every shot but point-blank bullets (and from a
marksman's beam entirely), a full wall or vehicle hull on the line toward the shooter hides
the cell (glass does not, nor anything from a marksman), and 1 m cover pressed against the
cell on the shooter's side halves the danger beyond 2 tiles. The direction to the shooter is
rounded to the nearest of the eight firing lines, because the enemy will step onto one. Only
the 8 visible enemies nearest the click count; with none visible (fog), every side counts,
so the squad hugs the most enclosed cover near the click.

**The move preview shows the route and its price (#103).** In `Mode.MOVE` the green
reachable spill now carries two extra layers. Every green tile is labelled
**`spent/budget`** — what standing there costs out of the unit's total movement, read
straight from `Movement.reachable`'s `cost` dictionary, not recomputed. And the tile under
the cursor draws **the actual path** to it, walked back through `Reachability.came_from`.

Both facts matter more than they look. `came_from` is the shortest-path tree of the very
Dijkstra the resolver will use to move the unit, so the drawn line is not an
approximation of the route — it *is* the route, and it is the cheapest one, because
Dijkstra puts no other into the tree. The label is likewise the number that will be
charged. `reach_budget` is stored alongside the reachable set so the denominator is the
budget actually used (`move_credit` when banked, §3.4). Labels are suppressed below
`MOVE_LABEL_MIN_ZOOM = 0.45`, where a cell is too small to hold a number — the path line
still draws.

**Shifting a captive (#100).** `Mode.MOVE_HELD` is entered from the **"Shift Captive
(free)"** button, which appears whenever `resolver.held_unit_of(unit) != null` and is
**not gated on AP** — the action costs nothing (§8.1). `_enter_move_held` fills
`item_cells` from `resolver.carry_drop_cells(u.coord)`; those cells draw in the
carry-drop blue with the hovered one emphasised, and a click submits
`MoveHeldIntent(selected_id, coord)`. The mode is registered in `HOVER_PREVIEW_MODES`, so
the highlight follows the mouse without waiting for a camera nudge (#97).

**Infantry and vehicle selection are exclusive (#97).** `_select_vehicle` already cleared
`selected_id`; `_select` now clears `selected_vehicle_id` (and the vehicle's move targets
and disembark state) to match. Both `_back_to_menu` and `_after_action` test
`selected_vehicle_id != -1` first, so a stale id left over from an earlier tank meant that
finishing *any* soldier action reopened the **tank's** menu instead of the soldier's.

**A spent unit shows no menu (#97).** `_open_menu` and `_open_vehicle_menu` both end with
`_has_action_button(vb)`: if nothing but Cancel was built, the panel is hidden instead of
shown. The **selection is kept** — the info line still reports the unit's stats, and a
click on empty ground deselects as usual. Note that a vehicle with no AP and no move
credit can still legitimately offer buttons: **Board** is paid for by the boarding
*soldier's* AP, so it is offered whenever infantry stands adjacent.

### 18.4 Camera

`ZOOM_MIN 0.12`, `ZOOM_MAX 2.5`, `ZOOM_STEP 1.1`, `PAN_SPEED 700`. WASD or
middle/right-drag to pan.

**The floor is "the whole board at once" (#103).** `ZOOM_MIN` was 0.5, which still left a
20 px cell — a 60×40 city (2400 cells, a 200-man battle) did not fit on any screen, so the
player drove the camera blind, seeing neither flank. 0.12 gives a ~5 px cell: the figures
are unreadable, but the *shape* of the battle is visible, and that is what one zooms out
for. `_ensure_visible(coord)` (§14.1) pans without touching zoom: the scale is the
player's choice.

**Camera row (team-session batch, item 10).** The side panel's *Camera* row has a **Me**
button and, in team mode, one button per teammate (their letter). Each pans — zoom
untouched — to the centre of that side's units and vehicles (`_home_focus(side)`,
`_center_on_side`). "Me" is the seat this machine holds (`NetHandoff.my_side_hint`).

**The far plan (big maps).** Below `LOD_ZOOM` (0.35, a cell under 14 px) the board is not
drawn cell by cell: at `ZOOM_MIN` on a 250×250 map that was ~37 000 cells and ~150 ms on
*every* frame — every mouse move, pan step and animation tick. A child layer drawn behind
the battle node (`LodLayer`, nearest filtering) shows three one-pixel-per-cell textures —
terrain, the fog, and objects above the fog, the same order the cell pass draws them in —
and follows the camera through its own transform, so panning and zooming never redraw
it. The textures are patched pixel by pixel: terrain and objects from the cell look log
(`GridCell.look_changes`), the fog from the resolver's visibility log
(`take_vis_changes`), scorch marks from `FxDecals.damage_version`; they are built whole
once (~55 ms on 250×250) and kept patched even while zoomed in, so zooming out again costs
nothing. Units, vehicles, corpses, mines, highlights and effects are drawn on top as
before; grid lines and height captions are left out — they are not readable at that
scale. Closer in, terrain is **baked, not drawn per cell (team-session batch, items 2 and 6)**:
`TerrainTiles` renders 16×16-cell chunks into textures at 16, 32 or 64 px per cell —
whichever is closest to the on-screen cell size — in two layers, floor and features,
with the fog drawn between them as before. Chunks rebuild only when `GridCell.look_changes`
touches them, at most four per frame (a missing chunk borrows another resolution
meanwhile), and old ones are evicted least-recently-used under 128 MB. The cell pass
keeps only what changes per frame or per unit: mines, held objects, DOT cracks, height
captions (zoom ≥ `HEIGHT_LABEL_ZOOM` 0.6), grid lines per row and column, corpse piles
from `GridCell.corpse_version`. A 6-side, 120-unit battle went from ~400 draw calls to
~140 and `_draw` from 3.2 ms to 1.4 ms; the placement screen and the map editor use the
same tiles. Measured `_draw` on a 250×250
town: 149 ms → 0.2 ms at `ZOOM_MIN`, 17 ms → 8 ms just above `LOD_ZOOM`, 2.8 ms → 1.4 ms at
1:1. The purchase screen got the same viewport culling (it drew all 62 500 cells every
frame: ~500 ms → 2–8 ms).

### 18.5 Dice presentation

Rolls play one at a time in a SteamChrome-framed **Dice Roll** window showing the
accuracy or defence prompt with every buff and debuff itemised. `FAST_ROLL_SPEED = 2.0`
speeds up long bursts. **The die is a die (team-session batch, item 16):** `DieView`
draws a rounded ivory cube with pips that tumbles — spin and hop decaying — before it
settles on the rolled face, outlined green for a success and red for a failure, instead
of numbers flicking past. An AI side's dice, steps and AP dots run at the **AI speed**
(§18.6).

**Who presses the button.** `_owner_is_local_human(owner)` decides whether a roll waits
for a click or spins by itself. In a network match it is `owner == my_owner`: the shooter
rolls to hit on their screen, the defender rolls to defend on theirs. This is presentation
only — the outcome is already fixed (the client's rolls are scripted), so the button is a
gesture, not a source of randomness, and it cannot desync. The AI never waits for a
click — but a **civilian's shot does**, because the one being shot at is the player
(§14.1).

**Everyone waits for that click (batch 12 #14).** Every step carries a `roller`. In a
network match a step whose roller is a networked human — `Roster.is_networked_human`,
a Player slot with a peer — is numbered with `_roll_seq`, identical on every machine
because actions and their dice arrive in one order. On the roller's screen the die shows
the Roll button; when pressed, `DiceRoller.rolled` fires and the screen broadcasts
`K_ROLL {n}`. On every other screen the same step shows "…Waiting for Player C to roll…"
(`DiceRoller.play(..., wait_remote = true)`) and spins only when that `K_ROLL` arrives —
early arrivals wait in `_roll_inbox`, since a faster peer may press before a slower one
has reached the step. Rolls belonging to the AI or to civilians spin by themselves for
everyone. The prompt also states the target before the die moves: "(need 4+)" for hits,
the armour number for defence, "beat N" for a grab.

**A newer roll cancels an older one cleanly (batch 14).** `DiceRoller.play()` carries a
generation counter: a play started on top of one still waiting (for a departed player's
Roll, say) makes the earlier coroutine return quietly when it wakes, instead of writing
into labels the new play has already freed ("Invalid assignment of property 'text' …
on a base object of type 'Nil'", the error in the batch-14 report). Waiters are always
released — `finished` is emitted either way.

**Event kinds.** `_dice_steps` splits an event into one-die-at-a-time steps: `attack`
(all hit dice, then all penetration dice), `opposed`, `check`, `grenade`. `walk` is the
odd one out — it rolls nothing. `_play_dice` intercepts it and hands it to `_play_walk`,
which steps the unit's **draw position** along the path one cell per `WALK_STEP_DELAY`
(#96). It is how an off-intent mover — today, a civilian — is seen crossing the board
instead of appearing at its destination.

### 18.6 HUD

A movable, resizable side panel (`HUD_START_SIZE = (330, 430)`) with a universal base
action menu shared by all units.

**Save Game is a button again (batch 13 #3).** It sits beside *Return to Menu* in the side
panel (Ctrl+S still works) and is hidden while watching a replay. **The pause button just
says Pause / Resume (batch 13 #10)** — the "(AI vs AI)" suffix is gone; the button still
appears only when every side is a machine. **The vehicle component panel stands to the
right of the action menu (batch 13 #13)**, on the same top line, instead of above the
combat log where a long vehicle menu used to grow over it; `_reposition_hud_grip` places it
once the menu's width is known, and it stays wherever the player drags it.

**Team-session additions (items 5, 17, 18, 19).** The side panel gains **Settings**
(§21), the *Camera* row (§18.4) and, when any AI plays, **AI speed** — 0.5× / 1× / 2× /
4× (`GameConfig.AI_SPEEDS`) dividing `AI_STEP_DELAY`, walk steps and dice time for AI
sides only (`_pace`). It is the host's control: guests see it disabled, and a change is
broadcast as `K_AI_SPEED`; the lobby sets the starting value. The **combat log** is a
half-transparent glass panel like the chat, and **both resize** from a grip in their
title bar. Their scrollbars are draggable bars: the theme's scrollbar styles now carry
6-px margins — with none, a scrollbar without a forced width (the battle panel's, for one)
collapsed to zero pixels.

**Action menus are anchored to the top-left corner (#87)**, at `MENU_ANCHOR = (16, 16)`,
not floated above the unit — over the unit they covered the board and slid off-screen
when zoomed. Every menu is a `ScrollContainer`; `_cap_scroll_height` clamps it to
`viewport.y − MENU_ANCHOR.y − MENU_CHROME_H (70)`, so a long menu scrolls instead of
running off the bottom. Pointer input over a visible menu belongs to the menu and never
pans or zooms the camera (#8).

Corpses render in `CORPSE_COLOR = Color(0.8, 0.1, 0.1, 0.5)`; BRU sections render as
solid `BRU_COLOR = Color(0.05, 0.05, 0.07)` fills (#85).

**Drawings (item 51, batch 17; raster since the team-session batch, item 15).** Free-hand
strokes over the board, cosmetic only, never part of the simulation. They are painted
like in Paint: each (author, scope) owns a sparse raster `DrawCanvas` of 256-px tiles,
the brush stamps round dabs along the mouse path, and the **eraser clears pixels** of the
viewer's own canvases wherever it passes (erasing used to delete whole strokes it
touched). Strokes and eraser passes travel as point lists with a radius (`K_DRAW`, `e`
marks an eraser) and are replayed into the same canvases on every screen. Each stroke carries its author and a scope — `SELF`, `TEAM`
("Share with team") or `ALL` ("Share with everyone", visible to enemies too). Every
stroke is sent over the wire; the viewer filters. Filters are plain checkboxes: *Hide
others' drawings*, *Hide my drawings*, *Hide all drawings*. The viewer is `my_owner` in a
network game and the active side in hotseat; **a side driven by an AI never counts as the
viewer's own**, and when a player leaves and an AI takes over, their strokes are dropped
on every screen (`_drop_drawings_of`) — before this the leaver's team drawings surfaced
for everyone once the host went local and the AI's turn made it the "viewer".

### 18.7 Escape

Context-sensitive cancel, in order: close dialog → exit build/sub-mode → deselect →
quit dialog. Actions can be **unchosen** as well as undone.

---

## 19. Screens & Flow

```
MainMenu → Setup → Placement → Main (battle)
        ↘ Multiplayer tab → Lobby → Placement → Main (battle)
                                  ↘ loaded .mcfs → Main (battle, no deployment)
        ↘ Load / Replay tab → .mcfs → Main (battle)  |  .mcfr → Main (replay viewer)
        ↘ MapEditor → "Main Menu" ↩ / "Play" → Main (battle)
```

- **Load / Replay** — saved games and recorded matches (§20.1). A replay opens the battle
  screen in viewer mode; a save resumes the match with the roles it was saved with.

- **Setup** — map, civilians on/off, fog on/off, budget, AI opponent, placement mode.
  **Free placement is the default** (#91); "Default squads" is the opt-in. The **host of
  a network match uses this same screen** (#99), with the AI and placement rows hidden;
  see §22.3.
- **Placement / "Deploy Your Force"** — pick a unit, click a cell in your zone to
  deploy, click a deployed unit to refund. **No point limit**: the label shows points
  spent and unit count for reference only. P1 deploys, then P2, then Start Battle.
  The roster includes a **Civilian for 20 points**. A deployed civilian is an **ordinary
  soldier of the buying side** (#96) — selectable, orderable, counted in the army, and
  unable to fire on its own side. Only map-authored Neutral civilians are NPCs (§14).
  (Under #91 a bought civilian entered play Neutral and hostile to everyone; that made the
  purchase unusable — the player paid 20 points for a unit that hunted their own squad.)

  **Eraser (batch 13 #5).** A toggle under the brush tools: while it is on, the point brush
  removes your own units under the click or drag, and Line / Rect / Circle / Full erase
  their whole area, refunding the points. Mirrored copies and other players' units are
  never touched; picking a unit from the palette turns the eraser off.

  **Mirrored placement is live (batch 13 #13).** There is no *Stamp Formation* step any
  more. Every change the first side makes — a unit placed, removed, or a tank rotated —
  rebuilds the mirror image in every other zone at once (`_refresh_mirrors`, records
  flagged `mirror`), so the other players watch their army appear as the host builds it.
  In hot-seat the flow goes straight from the first side to *Start Battle*; over the
  network the host sends the mirrors with its live placement, and a mirrored guest
  confirms readiness **automatically** the moment the host's final formation arrives.
  Units that do not fit the other zone are reported in the status line rather than
  silently dropped.

  **Every side gets the same units, wherever its zone is.** The mirror used to reflect
  the formation through the map centre, which is right only for two zones facing each
  other; with zones side by side, in quarters or at odd angles the reflected cells fell
  outside the other zone and whole squads were dropped. Now each zone gets the first
  side's army carried by one of the eight grid motions (four rotations, four
  reflections — `DIHEDRAL`) plus a shift, chosen per pair of zones
  (`Placement._zone_transform`): first a symmetry of **the map itself** that carries the
  first zone exactly onto that one, so every copy stands on the same ground (quarter
  turns and diagonals only on a square map); failing that, the motion that overlaps the
  two zones most once their centres coincide, ties going to the one that faces the
  formation towards the map centre. Each unit lands on its carried cell or, if that is
  taken or outside the zone, on the nearest cell where it fits; a tank's facing is carried
  by the same motion. `tests/run_mirror_stamp.gd` checks, on left–right, quartered,
  3-player symmetric and 3-player non-symmetric maps, that every side ends up with exactly
  the same units — and exactly mirrored positions where the map is symmetric.

  **The purchase screen draws the real map (#100).** Deployment used to happen over flat
  coloured squares, so the player picked positions blind and only discovered the walls,
  trenches and sandbags once the battle started. `Placement._draw` now runs the same
  terrain pass as the battle screen: floor / space / wall sprites through
  `Sprites.draw_texture_override_rect`, cover tinted by height, and each feature labelled
  with the battle screen's own tag (`ST`, `SB`, `hdg`, `tr`, `##`, `▢`, `BRU`, `††`, `AL`,
  `drt`, `MG`, `PBX`, `WD`, `hSB`, `PBX+`) plus a `"%.1fm"` height caption, including the
  BRU black-monolith special case (§18.6). Same tags, same colours, same heights — what
  you deploy onto is what you fight on.
- **Map Editor** (rebuilt in editor-rework, laid out "like Paint" at the owner's choice).
  Menu bar on top — **File** (New, Open, Save, Play This Map, Exit; *Save As* is gone —
  an untitled map asks for its name on the first Save), **Edit**
  (Undo, Redo, Cut, Copy, Paste, Delete, Select All, Rotate / Flip pasted, Clear Map;
  items with nothing to do are greyed out), **View** (zoom, Fit Map, Grid, Deployment
  Zones, Minimap, Keyboard Shortcuts) and **Map** (Resize, Preset) — with the tool
  options (brush size, *Filled*, Symmetry) and **Play** on the same strip. An icon
  toolbar on the left (chunky 12×12 pixel-art icons): **Brush, Eraser, Line, Rectangle,
  Circle, Fill, Select, Eyedropper, Stamp** (keys B E L U C F M I T; 0.9.2 moved Rectangle
  to U and added Circle — a circle or oval inscribed in the dragged box, *Filled* for a
  disc). **R** turns things: what is being placed, the selection in place (a click with
  Select picks a whole furniture piece or run), or the furniture brush a quarter at a time
  (Shift+R — back to turning to the wall by itself); a turned piece keeps its turn in the
  map (`MapData.feature_turn`). **+ / −** zoom, **Esc** cancels and, with nothing to
  cancel, leaves the editor (asking first if the map is unsaved). A palette on the right
  shows the **real tile thumbnails** of the map's preset: Terrain (with the room floors),
  Walls & doors, Objects, four **Furniture** groups, each split by height (Low 0.5 m,
  Waist 1 m, Chest 1.5 m, Tall 2 m; the tooltip gives material, durability, mobility and
  AP to smash — §9.9), Neutral units, Deployment zones (1–8, *More zones* for all 26) and
  Stamps. Status bar and a **minimap** (click or drag to move the view) at the bottom.

  - **The canvas is the battle's own renderer.** `TerrainTiles` chunks on a `Grid` kept
    in step with `MapData` cell by cell; GridCell's look log marks the touched chunks
    and only those rebuild. Zones are a 1-px-per-cell overlay texture with each zone's
    number in its middle; spawns, grid and overlays are drawn for on-screen cells only.
  - **Undo is per-cell deltas** (before/after of every touched cell, plus the spawn list
    if it changed), 100 deep. The old editor saved the whole map per stroke — 0.9 MB at
    250×250, 3.5 MB at 500×500. Resize and Clear Map still keep full snapshots; New and
    Open start a fresh history. A repeated stroke over identical cells records nothing.
  - **Symmetry**: Left / Right, Top / Bottom, Four quarters — strokes, shapes, fills,
    stamps and pastes are mirrored. A mirrored zone goes to the matching player (pair
    0↔1, 2↔3…; in quarters 0→1 by X, 0→2 by Y, 0→3 by both), neutrals stay neutral. A
    *moved* selection is not mirrored: it was lifted without its mirror.
  - **Select / copy / paste**: drag a box; drag inside it to move it (one undo step);
    Ctrl+C / X / V, Delete; R rotates and H / V flip what is in hand. Clipboard, moved
    selections and stamps share one pattern format (`MapPresets.pattern`).
  - **Stamps**: small room, large room, corridor, house, pillbox, sandbag nest, trench
    line, hedgehog row — drawn in the map's preset tiles, airlock doors included. A stamp
    stays in hand for the next placement.
  - **Eyedropper** (or Alt+click with any tool) picks the tile, unit or zone under the
    cursor. The **eraser** clears to the preset's empty ground (space on Station and
    Asteroid, grass in Field, bare floor in Town and Bunker), removing units and zones.
  - **New Map** asks for a name, preset and size, and starts either from the preset's
    pre-fill or from the **random map generator** (density, zones, seed, symmetrical,
    civilians), which you then edit. **Open** lists the maps with a preview. **Play This
    Map** keeps the map, name, view and unsaved mark in `MapHandoff.editor_session`, so
    the editor comes back to it after the trial battle; *Exit to Main Menu* clears it and
    `MapHandoff.pending` (#104).
  - Measured on 250×250: a size-5 stroke step 0.2–0.4 ms, a whole-map fill 0.67 s, its
    undo 0.25 s. Covered by `tests/run_editor.gd` (real input events) and the ported
    batch 13 checks.

  **Map presets** (`MapPresets`): Station, Town, Field, Bunker, Asteroid — the generator's
  styles. A preset is the map's environment (`MapData.env`): it picks the tiles of walls,
  floors and doors, and decides how a **new** map is pre-filled — Station a deck with a
  rim of space, Town street, Field grass with bare patches, Bunker solid rock (the eraser
  carves it), Asteroid an island in space. Per the owner, a preset does not change the
  brushes, the rules or the lobby. Map ▸ Preset re-skins an existing map (one undo step).
- **Quit-to-menu** — a SteamChrome overlay (dim + framed panel + title bar +
  Cancel / Main Menu), never an OS dialog.
- **Team-session batch (items 14, 21, 22).** **Game modes are gone** (`GameConfig.game_mode`
  and the lobby's mode picker; rules no longer carry `gm`). **Chat** lives in the lobby
  (its own group box) and on the purchase screen (a window bottom-left) as well as in
  battle — one conversation: `NetHandoff.chat_history` keeps it from the lobby to the end
  of the match (`ChatBox`). **Deploy zones:** the lobby's per-slot *Zone* is a drop-down
  (*Auto*, *Zone 1…N*); changing it redraws the map preview at once, and on a map without
  painted zones the preview shows each slot's vertical band in its colour.
  `MapData.band_of` is the one formula for that band, used by the preview and by
  placement — which before this ignored the chosen zone on such maps.

---

## 20. Maps & Data

`MapData` stores dimensions, per-cell floor type, cover height, space flag, feature id,
`zone_owner` and the environment preset (`env`). Maps serialise to disk and are picked in
the lobby. A new editor map starts pre-filled for its preset (§19, Map Editor).

### 20.1 Saved games and replays (items 42, 53)

Two file formats, one shared core. `StateCodec` turns a `GameState` into JSON-safe data
and back; `ReplayFile` puts it on disk as gzip-compressed JSON.

| File | Where | Holds |
|---|---|---|
| `.mcfs` — saved game | `user://saves` | one board snapshot + the rules of the match + the cosmetic decals |
| `.mcfr` — replay | `user://replays` | the starting snapshot, the opening civilian slot's dice, then every intent with its own dice, plus a full keyframe every 5 rounds |

**Why a replay is only intents and dice.** The whole architecture pays off here:
`GameActionResolver.resolve()` is the only mutation point and `DiceService` is the only
RNG, so *intent + its dice log* completely describes one board-to-board transition. That
is the same fact the lockstep contract rests on (§22.1) — a replay is simply the other
end of that wire being a file. Recording therefore costs exactly one hook in `resolve()`,
and it is skipped in network play, where the host is already recording the dice.

**Why `StateCodec` does not reuse `GameState.snapshot()` directly.** The undo snapshot
holds live object references (`rec["obj"]` *is* the `UnitInstance`) and native
`Vector2i`s: it is built for rewinding inside one process. `StateCodec` writes plain
JSON types, but *restores* through the very same `GameState.restore()`, so what counts as
"the state of a match" is defined in exactly one place. Cells are stored sparsely — only
those that differ from an empty cell.

The dice generator is saved as **seed + how many rolls it has made**, and reloading
replays those rolls to walk it back to the same position. Its internal 64-bit state
cannot survive JSON intact, and a loaded match that rolled a different stream than the
saved one would be a different game.

**Watching a replay** re-enters the battle screen with **no controllers at all** — that
is what makes it safe: there is nobody to submit an intent. Stepping forward resolves the
next recorded intent; stepping *back*, or any seek, rebuilds the board from the nearest
keyframe and fast-forwards, because the resolver is not reversible. Play/pause and
1×/2×/4×/8× sit on a bar at the bottom of the screen.

**Loading a save with role reassignment (item 42).** A `.mcfs` opens in the lobby, which
lists each saved army by unit count and lets the host rebind every slot — Player, AI, or
closed, with its colour and team. This is a **one-dictionary edit**: the roster is
separate from unit ownership (§3.2), so handing Player B's army to someone else never
touches a single `owner` field. Deployment is skipped — the armies are already on the
board. A networked host ships the whole save to the client (`K_LOAD`), for the same
reason it ships the map: the client does not have that file.

**Regression cover.** `tests/run_codec.gd` sweeps every script variable of every unit,
vehicle and cell through the file and back, and separately asserts that a snapshot does
not keep a live reference into the running match. That second check is not theoretical:
`Array(typed_array)` returns *the same array*, so the start-of-match keyframe kept
mutating with the game and replays began from the wrong board.

### 20.2 Random maps (`MapGen`)

The lobby's map list has a second built-in row, **Random map**, right under *Blank
arena*. Picking it shows the generator settings in place. Every change rebuilds the map
and its preview, and a network host re-sends it to the guests (`K_LOBBY_MAP`, the same
message a file map uses). A random map has no file: `GameConfig.map_path` stays empty and
the finished `MapData` reaches Placement through `NetHandoff.lobby_map` — in a solo game
exactly as over the network. The map section moved to the right column, under the slot
list, with the preview *beside* the settings: turn a knob and the result is on screen
without scrolling.

| Setting | Effect |
|---|---|
| Players | **Is** the lobby's slot count. Raising it adds AI slots in solo and Open slots when hosting; lowering it drops slots from the end, never one a guest sits in. One zone per slot, because `Slot.zone()` defaults to the slot id. |
| Units per side | Every zone gets `CELLS_PER_UNIT` (2) cells per unit, at least `ZONE_MIN` (16): room to arrange the squad and to park a 3×3 tank. |
| Style | Station / Town / Field / Bunker / Asteroid (below). Picking a style resets *Space* and *Flammable* to its defaults: Space on for Station and Asteroid only, Flammable on for Town and Field only. |
| Size | Small 28×20, Medium 38×28, Large 50×38, Huge 80×60, Giant 125×95, Colossal 250×250, or **Custom…** — any width and height from 16 up, with **no upper limit** (a row with both appears only for Custom). A *starting* size: if the armies do not fit, the map is rebuilt larger (automatic growth stops at `MAX_DIM`, 250×250; a larger custom size is kept as asked) and the readout under the settings says so. Beyond 250×250 the readout also warns what it costs: building takes seconds and a battle a lot of memory (measured ≈15 s and ≈1.3 GB at 1000×1000). |
| Density | Sparse / Normal / Dense: rooms, houses, clutter. |
| Layout | *Symmetrical* (off by default) — see below. |
| Mechanics | *Space* (vacuum only — doors are airlocks either way, below), *Flammable*, *Obstacles* — each can be switched off on its own. |
| Furniture | Off / Sparse / **Normal** / Dense / Very dense — how furnished the rooms are, independent of *Obstacles*. (The *wear* option is gone since 0.9.2.) |
| Civilians | The lobby's *Civilians* slider, 0–200: how many neutrals the generator places (it is also the cap at match start, §14). |
| Seed | The same seed and settings always build the byte-identical map. *Reroll* draws a new seed; *Save as Map* writes `user://maps/random-<style>-<seed>.json` (never over an existing file), after which it is an ordinary map — in the list and in the editor. |

**Furnishing (§9.9).** A last generator phase, `Phase.FURNITURE` with its own random
stream (added after the others, so every older seed builds the same structure, and *Off*
builds the byte-identical map), runs `MapFurnish` after the final pocket-join, when doors
and breaches are final. Each room rectangle is split into its connected pieces of floor
(a house partition makes two) and every piece gets a purpose from the style and its size:
*station* quarters, offices, storage, workshops, medical, command, server and utility
rooms, mess halls; *bunker* barracks, armouries, command, workshops; *town* bedrooms,
living rooms, kitchens, offices, shops, restaurants, garages, warehouses (in a split
house the bigger half is the living space); *asteroid* mining rooms, workshops, storage,
quarters; *field* huts and ruins only, so far less furniture. A purpose is a **recipe**
— a bed in a corner with a nightstand beside it, a desk against a wall with its chair in
front, a table in the middle with chairs around, counters in a row along one wall,
storage shelves in parallel rows with two-cell aisles and free ends, desks or dining
tables on a three-cell grid. The density sets how much of a room's free floor the recipe
may use (~15 / 32 / 48 / 62 %); a light clutter pass then drops crates, bins, carts and
toolboxes, and outside the rooms benches, park tables and bins go into parks, bins,
dumpsters and street cabinets against house walls on wide streets, crates and carts
against the walls of wide station halls, crates and barrels around field huts.

Large pieces use their footprints: a bed goes in a corner head-first against the wall, a
sofa or desk lies along it, tables and machinery stand in the middle along the room's long
axis, beds in a barracks line one wall with a cell between them, desks and tables sit on a
grid sized to their footprint with room for their chairs. Big pieces never touch each
other — only the small things meant to go with them (chairs, nightstands, bins, crates)
stand right beside a bed, table, sofa, counter or shelf. Furnishing does not depend on
*Obstacles*; when a station or bunker is furnished, the sandbag "crate piles" that
*Obstacles* used to drop inside its rooms are left out (the random stream is consumed the
same way, so nothing else moves) — halls, streets and parks keep their obstacles.

Walkways are kept **by construction**, not repaired afterwards: nothing stands within a
cell of a door or airlock, in a deployment zone or on a cell the generator keeps clear,
nothing tall (≥ 1.5 m) stands in front of a window, and a piece is placed only if every
free cell of its room stays connected to the room's ways out **even counting all
furniture as solid** (though everything below 2 m can be climbed). A cheap test of the
eight neighbours settles most placements; otherwise a search from one side of the cell
must find the others. Outside rooms the same neighbour test is the only gate. On a
symmetrical map the source half is furnished and mirrored; a room straddling the axis
stays empty.

*Wear* was removed in 0.9.2 at the owner's request: generated furniture is always whole
(an old saved option is ignored).

**Every map has an environment (team-session batch, item 24).** `MapData.env` —
`station`, `bunker`, `town`, `field` or `asteroid` — is set by the generator (from the
style) and saved with the map; a map without one infers it (`environment()`: wooden walls
or grass → town, otherwise space → station, otherwise town). It travels in `GameState.env`
and the state codec, and picks the tiles: a `<tile>_<env>` texture beats the plain one —
metal bulkheads and deck plate on stations, poured concrete in bunkers, brick on asphalt
in towns, brick on regolith on asteroids, board-formed concrete and dirt in the field.

**Styles.**
- *Station* — a facility of **departments** (0.9.2, the owner's design). The footprint is
  split recursively (BSP) and every split line is a passage running the full length of
  its piece, so the network is connected by construction: the top two levels are **main
  corridors** (2–3 wide), deeper lines are 1-wide **maintenance tunnels** (grating floor)
  that weave between the departments. Each sector becomes one department, by priority and
  map size — *Bridge*, *Service*, *Engineering*, *Medical*, *Security*, *Supply*,
  *Production*, *Research*, then *Misc* and repeats on big maps (`MapGen.DEPARTMENTS`,
  `DEPT_ORDER`). The bridge takes the sector nearest the middle, Service one of the three
  next to it, Production the sector **farthest from Service**, and Engineering, Supply
  and Research prefer sectors on the hull. Inside a department: a **reception** (on the
  bridge the command centre, in Service a lounge) opens onto the main corridor; behind it
  runs the department's own corridor, and every other room opens only onto that corridor
  (back doors only to maintenance tunnels) — so no inner room of Medical or Security, or
  of anyone else, opens onto a main corridor. Rooms by department: Service — kitchen,
  mess, restroom, quarters, laundry; Medical — ward, surgery, supply storage, restroom;
  Security — briefing room, armory, holding cells; Research — testing range, laboratory,
  assembly workshop, supply storage; Production — machine shops, assembly, warehouse,
  dock; Supply — warehouse, dock, storage; Engineering — power distribution, water
  processing, air exhaust, dock, supply storage; Bridge — command centre with consoles,
  captain's quarters and a **hidden storage** whose only door is into the captain's
  quarters. Small maps build only the first departments, with fewer rooms. A **dock** and
  the **testing range** take the biggest room on the hull and get a 2–3-cell airlock
  straight into space (in a bunker, or with Space off, the dock stays a sealed cargo bay).
  Maintenance: a few rooms against a tunnel become utility rooms with a door only into
  the tunnel — always a **waste recycling** room — and tunnels ending at the hull get an
  airlock out to a field of **solar panels** (a floor look on space cells). Up to a fifth
  of the sectors — edge ones more often — are left empty: open space the corridors pass
  as windowed tubes. With Space on, about one room in 40 is vented (zero-G), and the hull
  gets windows and a few exterior airlocks. Obstacles: pillars in big halls, stacks of
  crates (wooden 2 m crates on plank decks), sandbags in main corridors.
- *Asteroid* (team-session batch) — a little island in space with a town on it: a
  ragged ellipse of rock and regolith, a town of the chosen *Density* built inside it,
  craters of dirt piles, and vacuum all around (Space on, Flammable off by default).
  Doors whose far side ends up in rock are sealed into walls.
- *Bunker* — the same station from the same seed, dug underground: everything outside
  the rooms and hallways is solid rock, never vacuum (no vented room, no hull), so the
  Space toggle does nothing here. With Space off, a bunker and a station of the same seed
  are the byte-identical map.
- *Town* — a jittered street grid in **districts** (0.9.2): an industrial edge
  (warehouses, factories, garages — on the asteroid, mining sheds; one big building per
  block, few windows), a commercial centre (shops, offices, restaurants with shop windows),
  one or two civic buildings on big maps (police station, clinic) and homes everywhere
  else (houses, apartment blocks). The building's kind picks its rooms (`MapFurnish._part_of`:
  the biggest is the main room, a room of ≤ 8 cells is a bathroom), and most buildings
  get a small corner **bathroom** with a toilet. Blocks become brick or wooden buildings
  (doors, glass windows, a partition in big ones) or grass lots. Obstacles: barricades across streets
  with one gap, hedgehogs on the paving, trenches and sandbag nests in the lots. With
  Space on, the town stands on a platform with a ragged edge and holes.
- *Field* — grass in patches, ruins, rock outcrops, and huts: small 5–7 × 5–6 houses
  (brick, or wood with Flammable on) with an airlock door, a window opposite it and a
  doorstep that is always left clear — about one per 650 cells at Normal density.
  Obstacles: trenches, hedgehog belts (every other cell, so they can be jumped), horseshoe
  sandbag nests, and wooden fences when Flammable is on. Space adds chasms and a ragged
  edge.

**Room floors (0.9.2).** Every room gets a floor by its purpose — wood, parquet, tiles,
checker tiles, red or blue carpet, linoleum, steel plate, grating (`MapFurnish.FLOOR_BY_KIND`,
picked by a hash of the room, never from the generator's random streams). The look is
**display only** (`MapData.floor_look`, `Grid.floor_look`, `MCF.FLOOR_LOOKS`): fire still
asks `floor_type`, and plank floors always look like wood. It is saved with maps
(`floor_look`, run-length) and games (`StateCodec` `decor`), mirrored with the map, and
painted in the editor from the Terrain group. Floors are laid even with Furniture *Off*.

**Every door is an airlock.** Every doorway of every room, house and hut — whatever the
Space toggle — gets an airlock (`MapGen._seal_doors`, run right after the structure and
before space, zones and dressing): it opens for a living soldier beside it and closes
behind him (§9.4). A breach the sealed-floor pass cuts through a wall (below) that looks
like a doorway — wall on both sides — gets one too. Dressing never puts an obstacle right
next to an airlock (no crate, rock or sandbag walls a door shut) and a hut keeps its
doorstep clear, so every door has floor to step on at both sides — `run_mapgen.gd` checks
it on every generated map.

**Symmetrical.** Off: layouts are organic. On: the map is mirrored — the left half (or
the top-left quarter) is built and reflected, so every side fights over the same ground:
- 4 or 8 sides — **four quarters** (mirrored left–right and top–bottom), a zone per
  quarter (two per quarter for 8);
- any other count — **left–right**, zones in mirrored pairs; with an odd count the last
  zone sits **on the middle line** and is its own reflection.
Zones grow together with their reflections: a cell taken on one side is taken on every
mirrored side at once, each image keeping the usual gap to every other zone, so the
zones are exact reflections and the same size. Civilians are mirrored too. Anything the
mirror cut off (a room whose door was on the discarded side) is reconnected by the
sealed-floor pass below, mirrored as well.

**Fair without a mirror.** With Symmetrical off, fairness lives in the zones:
1. Anchors by farthest-point sampling: the first near the map edge, each next one as far
   as possible from those already chosen.
2. Zones grow in turns, one cell per zone per turn, closest-to-anchor first with a little
   jitter (round zones, ragged edges). Doorways are passed through but never claimed, and
   no zone comes within `ZONE_GAP` (3) cells of another.
3. The best of several attempts is kept, then **every zone is trimmed to the size of the
   smallest** — cutting the cells grown last, so each zone stays connected. All zones of a
   random map are always the same size.
4. If the zones still cannot hold the armies, the whole map is rebuilt larger. Only at
   `MAX_DIM` may the gap shrink to 2, then 1 — and the readout then says the zones are too
   tight.
5. **No sealed floor, anywhere.** After the structure and again after dressing, every
   walkable area is labelled (4-way, the cells `GridCell.walkable_terrain` accepts). Any
   area with floor that is cut off from the main one — before zones the largest, after
   them the one holding zone 0 — is joined by the shortest possible breach: a 0-1 BFS
   where walking is free and each wall, rock, crate or hedgehog removed costs 1, run once
   from the main area to every pocket. This is what fixes a town house whose door found no
   room, a crate line splitting a room, or a room cut off by the mirror. Vacuum-only
   areas (open space outside a hull) are left alone. The old generator left such pockets
   in a handful of *Space off* town and field maps (1–23 unreachable cells); the fix
   there is a single cell, and the rest of those maps is unchanged.

**How many civilians** is the slider's number since the team-session batch
(`civilian_count`). Older saved options without it still read the magnitudes: *None / Few / Normal / Many /
Crowd* (`MapGen.CIV_LEVELS`; Normal by default) scales the base rate of one per 160 cells
(times density) by ×0 / 0.35 / 1 / 2.5 / 6, with at least 0 / 1 / 2 / 4 / 8 and at most
0 / 12 / 32 / 80 / 200 per map (`CIV_MULT`, `CIV_MIN`, `CIV_CAP`). A Huge town measured
0 / 11 / 30 / 75 / 180. Old saved options with the on/off switch read as Normal / None.

**Neutrals start sealed and dormant.** A civilian wakes the moment it sees a soldier along
a clear row, column or diagonal, or when a neighbouring cell changes — an airlock opening
included (§14). Generated civilians live only in **sealed rooms** (`_sealed_rooms`):
indoor floor from which no deployment zone can be reached without passing an airlock.
Nobody can see them and nothing next to them changes until a soldier opens their door —
so no action at the start of the match can wake them, and waking a room is a choice. On
top of that: never in a doorway, never next to an airlock, never on a cell a zone cell
can see, 3+ cells from every zone, in clusters of one to three.

**Big maps stay responsive.** Everything that walks the whole map is linear in its cells
(summed-area table for anchor candidates, a heap for zone fronts, one directional sweep
for "seen from a zone", one BFS for sealed floor), candidates are thinned to 6000, and a
250×250 map builds in well under a second. The lobby rebuilds a map over 100×100 once
the clicks settle (0.3 s) instead of on every click; reading the map still builds it at
once.

**Toggles do not reshuffle the map.** Each phase — structure, space, zones, dressing,
civilians — draws from its own RNG stream, and decisions inside a phase are rolled even
when a toggle cancels them. Switching Civilians, Obstacles or Flammable off removes exactly
those things; streets, rooms and zones stay where they were.

**The preview shows zones** in the colour of the slot that deploys there — for every map,
not just random ones. It is redrawn only when the map or those colours change.

Regression cover: `tests/run_mapgen.gd` checks, over every style, the sizes up to Huge in
full and Giant/Colossal once each, 2–8 sides, large armies, each toggle, custom sizes and
Symmetrical with 2, 3, 4, 5, 6 and 8 sides, that the promises above hold — same seed, same
map; equal zones that fit the squads; **no walkable cell sealed off** on the real board;
every doorway an airlock, with somewhere to step on both sides, Space on or off; every
civilian sealed in behind airlocks and the civilian levels in increasing order; custom
sizes beyond 250×250 kept; toggles honoured; symmetric maps equal
to their reflections cell for cell, zone for zone and civilian for civilian; a bunker
without vacuum, walled in rock, and identical to the station of its seed with Space off;
stations and bunkers with rooms and hallways in proportion to their size; Colossal built
within a time budget; civilians under the cap; and, with every zone cell occupied by a
soldier, not one civilian awake after the first action. It also plays a few AI-vs-AI
rounds per style. `tests/run_lobby_maps.gd` drives the real lobby: the row, the settings,
Players ↔ slots, zone sizing, the start handoff, *Save as Map*, the bunker, Custom size
with no upper limit, the Civilians selector, Symmetrical and the delayed rebuild of big
maps.

---

## 21. Texture Replacement & Theme

- **Textures (#55, #57):** any map or unit primitive may be replaced by a texture drop-in;
  the vector draw remains the fallback so the game is always playable with no art.
- **Theme (team-session batch, item 23):** `UiTheme` (autoload `Ui`) applies the
  "MCF: Alert! UI kit" to the root window — neutral bevelled grey chrome from
  `interface_textures/` (regenerated by `tools/gen_ui_kit.gd`), grey title bars with a
  bold shadowed caption, framed group boxes with the caption on the border
  (`SteamChrome.group_box`), and one **accent colour** for checks, radios, progress fills,
  selections and status text. Accent pieces are drawn at runtime from `Ui.PALETTES`
  (eight colours), so changing the accent needs no files.
- **Font (0.9.2).** The whole game — UI, the dice, labels drawn on the board
  (`ThemeDB.fallback_font`) — uses **Handjet**, a slightly pixelated font (SIL OFL,
  `fonts/OFL.txt`). `fonts/handjet_ui.ttf` is Handjet with a smaller `unitsPerEm`, so text
  at the old sizes has the old x-height; spaces are 2 px wider. The bold Courier that status
  lines and value boxes used is gone: they are bold Handjet in the accent colour
  (`Ui.bold_font`). A `ui_font.ttf` dropped by the player still overrides it.
- **Main-menu background (item 35):** `Starfield` replaces the flat `ColorRect` with a
  gradient sky and three star layers drifting at 5 / 13 / 28 px per second — the *speed
  difference* is the whole parallax. Each layer is one 512-px tile tiled across the
  screen with only its position animated, so a frame costs three sprites no matter how
  many stars there are, and the layers are laid out from a fixed seed so the menu looks
  the same every launch. The bundled `logo.png` finally appears, beside the title.
- **Settings (items 17, 23).** `SettingsWindow`, opened from the main menu and the battle
  panel: *Interface size* 75–150 % (`root.content_scale_factor`; the game draws on a
  1280×720 canvas, and beyond 150 % the slot table and the battle panel no longer fit)
  and *Accent colour* with live samples. Both apply at once and persist in
  `user://settings.cfg`. Screens are built to survive the scale: the lobby's two columns
  wrap, its slot table scrolls sideways inside its box when it must, the main menu's
  middle scrolls, and the battle chat stacks above the log when they would overlap.
- All UI strings are **English**; all code comments are **Russian**.
- **Factions instead of colours (batch 17, item 13).** `Roster.FACTION_KEYS` /
  `COLOR_NAMES` / `PALETTE` are three parallel lists of the eight lore factions —
  Conclave-NOVA (red), National Front "Purifiers" (yellow), Prometheus Noocracy (blue),
  Alliance of Neutral Stations (green), League of Neutral Stations (brown), Martian
  Militia (orange), Saint Order (white), New Kingdom of Jerusalem (purple) — and the lobby's
  picker offers exactly those. Every side keeps its colour for rings, AP pips, zones and
  the fallback circle, but a soldier is drawn from `<unit>_<faction>.png` when it exists
  (`Roster.faction_suffix_of(owner)` → `_nova`, `_neutral` for civilians), else the plain
  `<unit>.png`, else the circle with initials. **A corpse is the soldier's own art turned
  90° clockwise**; `corpse.png` (turned 90° counter-clockwise, #21.4) remains the fallback
  for piles and for units without art. The lobby's colour square shows
  `faction_<key>.png` on top of the colour when that portrait is shipped.
- **Shipped 64×64 tiles (team-session batch, items 9 and 20).** `tools/gen_textures.gd`
  generates every floor and feature at 64 px in a brutalist look — poured and
  board-formed concrete, steel deck, brick, sandbags — from seamless toroidal noise
  whose features start at eight cells, so no cell-sized motif repeats. Each tile has six
  variants (a single tile is a 384×64 strip, an autotile sheet is 256×1024: six 4×4
  sheets stacked); the variant is a hash of the cell, so neighbours differ and the same
  cell always looks the same. Autotiling joins **families**, not just one id (walls,
  glass, airlocks, pillboxes, LDF blocks and corpse walls join each other; sandbags join sandbags;
  trenches join trenches; a sandbag or trench cell whose diagonal is the same family
  fills its corner notch — no holes where four cells meet). The generator takes about a
  minute (`-- --furniture`, `-- --doors`, `-- --floors` regenerate just those).
- **Doors seen from the front (0.9.2).** An airlock or door is drawn as the wall of its
  environment (the wall sheet, by the wall family's mask) with a door **seen from the
  front** over it — the same face in walls of any direction: a sliding hatch with a window
  and a red/green lamp on stations, a blast door with a wheel in bunkers and on asteroids,
  a panelled wooden door in towns, a plank door in fields; three variants each, chosen by
  cell, and an open state (a dark doorway with the leaf at the hinge, or the door's edge).
  Files: `door[_open]_<env>.png`. Under fog a remembered door is drawn closed.
- **Damage you can see (0.9.2).** A pillbox (plain or with embrasures) that lost
  durability shows cracks in its own tile — three crack patterns so neighbours differ, and
  on the embrasure they run from the slit's corners and chip its edges without crossing it.
- **Furniture corners (0.9.2).** A one-cell-wide furniture shape with a turn — an L sofa,
  an L counter, a ring of reception desks, a U of shelves — keeps one back side along its
  whole length (to the walls, without walls outward) and mitres its corners from two
  straight sections (`TerrainTiles._path_look`, `_corner_tile`), so the back no longer
  breaks at the corner.
- **Wall autotiling (batch 17, item 12).** A feature may ship a 4×4 sheet
  `<feature>_autotile.png`; `Sprites.draw_feature` picks the tile from the four
  orthogonal neighbours carrying the same feature id (`N·1 + E·2 + S·4 + W·8`, column =
  index % 4, row = index / 4). It is used by the battle screen, the placement screen and
  the map editor alike, and the plain `<feature>.png` still works where no sheet exists.
  The full layout, naming and the "how to prepare a graphical update" checklist are
  written by the game itself into `textures/all_textures.txt` (`Sprites._manifest_text`).
- **Shipped blood decals (batch 17).** `textures/blood_pool.png` and
  `textures/blood_splatter.png` are real textures now (generated once, imported), so
  blood no longer falls back to the vector oval and quad.

---

### 21.1 Particles stay on the board (batch 12 #6)

`FxDecals.bounds` is the grid size in cells, set by the battle screen after the state is
built. `_launch` clips every casing, blood drop and glass shard against the four edges:
the first edge the flight would cross becomes a `via` point at fraction `split` of the
flight, the remainder is reflected on that axis, and `flight_pos` follows the broken
line — to the wall, then back in. With no bounds set (unit tests without a scene) nothing
changes. This is cosmetics: it consults no dice and touches no state.

**Glass shards (team-session batch, item 7).** A broken pane throws 5–9 shards 0.7–2.4
cells in a ±70° fan (was 3–6 within one cell — "they barely spread"). A shard's flight
stops at the first wall cell (`FxDecals.solid_at`, set by the battle screen) instead of
landing inside it, and a shard carries its **origin** cell: the fog test draws it when
either the cell it lies in or the pane it came from is visible, so a player who saw the
glass break sees all of its shards, even those that landed in fog. Shards use
`glass_shard.png` when shipped (it is now).

## 22. Networking

### 22.1 The lockstep contract

The host resolves intents and records the dice log (`DiceService.begin_record()` /
`take_log()`); the client replays the same intent with `feed_scripted()`. Because
`DiceService` is the only RNG and `GameActionResolver` is the only mutation point, no
divergence is possible. `PlayerController` is the abstraction boundary — the simulation
cannot tell a human, the AI, and a remote peer apart.

Three message kinds (`NetGame`):

| Key | Direction | Payload |
|---|---|---|
| `K_INTENT` | client → host | "please resolve this intent for me" |
| `K_ACTION` | host → client | authoritative intent **+ its dice log** |
| `K_INIT` | host → client | initiative order, active index, round number, **+ the dice of the opening civilian slot** (§3.2) |
| `K_DENIED` | host → client | the host refused an intent: actor id + reason. The guest whose unit it was logs `[denied] …`; before batch 17 a refused guest intent was silent on the guest's screen and looked like a dead button |

Fog is **presentation only** — `is_visible_to_team` gates targeting, but the resolver's
outcome does not depend on it, so a `fog_enabled` mismatch between peers cannot desync.

**Every action carries the host's board signature, and a guest that disagrees resyncs
(batch 14).** `K_ACTION` now includes `h = GameState.digest_hash()` — a hash over every
unit's id/coord/owner/status/AP/credit/vehicle, every vehicle's origin/owner/durability
and the turn queue. After applying the action the guest compares its own hash; if it
differs, if the action the host accepted was *refused* locally, or if scripted dice are
left over, it sends `K_RESYNC` and the host answers `K_STATE` with the full
`StateCodec.encode(state)`, which the guest lays into its existing `GameState` through
`StateCodec.restore_into` (the same path a save is loaded by). The battle screen logs
"Board out of sync … resynchronising" and "Board resynchronised", re-reads the board
exactly as after an undo, and play continues from the host's truth. Before this a
desync stayed silent and surfaced as "Unit not found" on every one of the host's actions.

**The match result is the host's to declare (batch 14).** A guest never runs
`_winning_team()`; the host sends `K_OVER` with the title and the guest shows the same
window. A desynced guest can therefore no longer announce "Player B wins" in the middle
of somebody else's turn.

**Every field an intent carries must be on the wire.** `IntentCodec` gained `T_MOVE_HELD`
for `MoveHeldIntent` (§8.1) in #100, and the same pass fixed a latent desync: `MoveIntent`
has always had a `carry_drop` cell, and the codec had never serialized it. A player who
chose where to set a prisoner down sent a packet the client decoded with the `(-999, -999)`
sentinel, so the client dropped the body on the *automatic* cell while the host used the
chosen one — two different board states from one intent. `carry_drop` now rides in the
packet as `dx`/`dy`, and the sentinel round-trips intact when no cell was chosen.

### 22.2 Transport (LAN / Radmin VPN, #92)

`NetworkSession` is a thin ENet P2P relay: `start_host(port)` listens for **exactly one**
client, `start_client(ip, port)` dials it, `DEFAULT_PORT = 8642`. Any IP that routes
works — a LAN address or the 26.x.x.x address a Radmin VPN hands out. The session is a
**Node under `/root` with the fixed name `NetSession`**, because Godot delivers RPCs by
node path: a constant path on both peers means the relay keeps working no matter which
scene is loaded.

Scene changes are the hazard, and the buffer is the answer. `_relay` emits `message` only
while `_listening`; otherwise packets queue in `_inbox`. `attach()` flushes the queue and
starts listening; `detach()` goes back to buffering. So the handoff
**MainMenu → Placement → Main** never drops the host's opening packets:

- `NetHandoff.session` / `.is_host` carry the node between scenes; `take()` hands it over.
- Placement calls `attach()` **at the very end of `_ready()`**, after the UI exists —
  `attach()` flushes synchronously into a handler that touches the panel labels.
- On leaving, Placement calls `detach()`, disconnects its own handler, re-arms
  `NetHandoff`, and lets `Main._adopt_network()` re-`attach()`.
- Losing the peer at any point closes and frees the session node (it lives under `/root`
  and a scene change will not collect it) and returns to the main menu.

### 22.3 Match flow (#93)

**The host is Player A (`PLAYER_1`), the joiner is Player B (`PLAYER_2`).** On
`peer_ready` the menu forces `p2_is_ai = false` and `free_placement = true`.

**The host sets up an ordinary match (#99).** A connected game is not a fixed demo any
more — once a player joins, the host lands on the **same Setup screen** used in single
player and picks the map, the **point budget**, civilians and fog. The AI and
placement-mode rows are hidden there (the opponent is a person; deployment is always
free placement), the buttons read "Start Match for Both" and "Leave Match", and leaving
tears the connection down.

Pressing start broadcasts `NetHandoff.K_SETUP`, which carries the settings **and the map
itself** as `MapData.to_dict()`. The map travels whole rather than by filename on
purpose: the host may have drawn it in their own editor, and the client would have no
such file — shipping the data also guarantees the two fields match cell for cell. If no
map was chosen, the host sends `MapData.blank_arena()`, so even the default arena is one
definition rather than two. The client chooses nothing: it waits in the menu, applies
the announcement through `NetHandoff.apply_setup`, and both peers move on to
**Placement**, where the purchase phase runs against the host's budget.

**Deployment is simultaneous and private.** Each player buys and places **only their own
army**, **only inside their own zone**, and the flow button reads "Ready" instead of
"Next player". Pressing Ready broadcasts a `K_ROSTER` message — the list of
`{stats_id, owner, x, y}` — and once a peer holds **both** rosters it builds the battle.

Two details make that build byte-identical on both machines:

- **Canonical spawn order.** `MapData.build_state()` assigns unit ids by iteration order
  over `spawns`, and each side naturally appends its own army first. Left alone, the two
  peers would give the *same* unit *different* ids, and every intent — which references
  ids — would land on the wrong unit. `_sort_spawns()` therefore sorts by
  **(owner, y, x, stats_id)** before handing the map over.
- **One seed.** The host generates `_shared_seed = randi() & 0x7FFFFFFF` and ships it with
  its roster; both sides pass it through `MapHandoff.dice_seed` into `DiceService`, so the
  initiative roll inside `begin_match()` agrees before the `K_INIT` handshake even
  confirms it.

**Colour is the roster's, everywhere (batch 12 #11).** `_side_color(side)` in Placement
and Main both return `roster.color_of(side)`: the colour a player picked in the lobby is
the colour they deploy in and fight in, on every screen. The earlier "your army blue, the
enemy red" perspective is gone — with three or more players it merged two opponents into
one colour, and it made the deployment screen disagree with the battle.

In battle each player controls only their own units, the **defender rolls their own
dice** (§18.5), and group selection is disabled.

### 22.4 The lobby is one window shown on every machine (batch 12 #8–#10)

The host owns the roster and the rules; everyone else sees the same thing. Every change
the host makes — a slot's type, colour, zone, budget or allowed units, any rule row, the
map — is followed by `_broadcast_lobby()`, which sends `NetHandoff.K_LOBBY` carrying
`NetHandoff.encode_rules()` (the full `GameConfig` rule set **plus `Roster.to_dict()`**)
and the map's name. The map itself travels separately as `K_LOBBY_MAP`, only when it
changes, because a map dictionary is large and a snapshot is sent on every click. Guests
apply the snapshot through `NetHandoff.apply_rules`, rebuild their (read-only) controls
from `GameConfig`, and redraw the slot table.

**A guest that opens the lobby asks for it (batch 14).** The client lobby sends
`K_LOBBY_REQ op=hello` on entry; the host seats the peer if it has not yet, and re-sends
the snapshot and the map. A snapshot that raced ahead of the guest's scene change can no
longer leave the guest "waiting for the host's lobby" forever. The host also **caches the
selected map** instead of re-reading the file for every slot row (`_map_zone_count` used
to load the map from disk once per slot on every refresh), counts its zones once, and
renders the preview at one pixel per cell for big maps — that was the "it took a while
until it loaded".

**Black and White were colours (batch 14)**; since batch 17 the palette is the seven lore
factions (§21) and the personal square shows the faction's portrait when one is shipped.

**Seats.** The host's own slot carries `peer_id = 1` (the ENet server id). When a guest
connects, `NetworkSession.peer_joined` hands the host its id and `_seat_peer` turns the
first **Open** slot into **Player** with that `peer_id` — or adds a slot if none is open.
A **Who** column shows who sits where: "Player C (you)", "Player A (host)", or "(nobody
yet)" for a Player slot the host set by hand; an Open slot shows a **Join** button to
guests. Leaving returns the slot to Open. A guest cannot be un-seated from the slot list
(the host must wait for them to disconnect), and the host cannot start while a Player
slot has nobody in it.

**A player who leaves is replaced by a Hard AI (batch 13 #2).** In the lobby the slot flips
to *AI – Hard* instead of *Open*; during placement the host's `_on_peer_left` does the
same, keeps the army the guest had already sent (or, if they had not, un-readies the host
and walks it through deploying for that side), and tells the other guests with
`K_SLOT_AI`; in battle `Main._on_peer_left` swaps the `NetworkController` for an
`AIController` on the host and broadcasts `K_SIDE_AI` so guests stop waiting for that
player's dice (the roll wait re-checks `is_networked_human` and is woken by
`_roll_arrived`). A host left alone no longer falls back to the menu: the session stays
(closed, its `send` a no-op) and the match continues against the machines.

**Seating respects a reserved seat (batch 13 #11).** A slot the host set to *Player* by
hand before anyone joined is the seat prepared for the friend: a connecting guest is put
there first, then into the first *Open* slot, then into a new one. Before this the guest
landed in a fresh slot while the hand-made one stayed empty, and *Start Match* refused
with "nobody has joined it". As a further safety net, a guest still in the lobby that
sees placement traffic (`live_req` / `live` / `roster`) sends `K_SETUP_REQ`, and the host's
placement screen answers with the full `K_SETUP` (map with its neutral spawns included).

**Points survive a colour change (batch 13 #12).** The slot table is rebuilt on every
change, and a budget typed into a `SpinBox` but not yet confirmed lived only in its text
field — so choosing a colour reverted 500 back to 300. `_refresh_slots` now calls
`apply()` on every spin box before rebuilding, and the budget field writes the roster on
each keystroke.

**Guests ask, the host decides.** A guest's colour pick or Join click is a
`K_LOBBY_REQ` (`op: "color" | "slot"`) stamped by the transport with `_from`, the sender's
peer id. The host validates it (colour free? slot open?), applies it, and broadcasts the
next snapshot — there is no local prediction, so two guests can never disagree.

**Start** sends `K_SETUP`, which is `encode_rules()` plus the map: budgets, mirrored
placement, live-placement visibility, friendly fire, random events and the roster all
arrive together. Before batch 12 only the map, budget, civilians and fog travelled, which
is why guests deployed against the default 300 points (#9) and ignored the mirrored
setting (#10).

**Placement for N players (batch 12 #12, #15).** `_my_side` is
`roster.side_of_peer(my_peer_id())`. The host also deploys every **AI** slot in turn
("Next: Player B (AI) >" before "Ready"). Each Ready broadcasts `K_ROSTER` with two lists:
`sides` — the sides whose armies are in the packet (they replace what was known) — and
`ready` — the sides confirming. The battle starts on a machine when it is ready itself
and every other playing side has confirmed. In **mirrored** mode the host is the only
one who places: on Ready it stamps its formation into every other zone, sends all of
them in one packet, confirms the AI sides itself, and guests — whose screen is locked and
whose Ready button only lights up once the host's formation has arrived — confirm their
own with `sides: []`, so nothing they send can overwrite the stamped army. While "Live
placement visibility" is on, every placement change broadcasts `K_LIVE`, and a peer
entering the screen sends `K_LIVE_REQ` to see what the others already placed; live units
draw with a shadow, final ones plainly.

**Chat names the sender on the receiving screen (team-session batch, item 3).** A chat
message carries the sender's **side**, not a ready-made label; each screen builds the
label itself — the side's name, plus "(you)" only when the side is its own. The old
message carried the sender's label already rendered, so every player on the LAN showed
up as "(you)". Text is escaped (`ChatBox.escape`), so a message cannot inject BBCode.

**AI slots in a network match are driven by the host (batch 12 #15).** The host's
`_setup_network_controllers` gives every AI side a real `AIController` whose intents go
through `net.submit_local` like a human's — resolved on the host, broadcast to all.
Guests hold a `NetworkController` for those sides and only ever "kick" an AI that is
theirs to run. Network actions are shown **one at a time** (`_net_queue`): the state is
applied on receipt, the display waits for the previous animation to finish, and the
display path now matches the local one — lanes before the dice, blood and casings after,
undo/redo resyncing the board.

---

## 23. Design Decisions Worth Recording

These are deliberate choices that look like bugs if you don't know the reasoning:

1. **Cover gives no defence bonus** — only a hit penalty (`COVER_MOD = {1.0: 2}`).
2. **Cover is checked on exactly one cell**, the step from target toward shooter — not
   swept along the whole ray.
3. **No cover at distance ≤ 1 or exactly 2.** Point-blank ignores obstacles.
4. **Trench height is 0.0.** Protection is an immunity rule keyed on `TRENCH_DEPTH`,
   not a cover modifier.
5. **Corpses block movement but not line of sight.**
6. **Every miss still detonates** — anti-tank, grenade, and cannon all fall short and
   explode where they land.
7. **Three different blast shapes** — square (anti-tank), X (grenade, #64), diamond
   (cannon, #63) — so the player can read the weapon from the pattern.
8. **BRU must be one orthogonally connected chain** (#80), and exactly one tile must
   touch the engineer. This reverses the original #58 rule.
9. **A pillbox absorbs a direct hit whole** (#89) — it loses durability and the
   explosion does not happen at all, so the cell next door is safe. Splinters from a
   *nearby* blast never touch it (#17). A miner can still demolish it by hand.
10. **Fire is permanent, but construction smothers it** (#82) — building, digging, or
    dragging something onto a burning cell puts it out; nothing else does except the
    extinguisher grenade.
11. **The dig flow is 3 clicks** and stays that way — it is load-bearing elsewhere.
12. **Drag was merged into Grab entirely** — there is one verb, not two.
13. **`move_credit` is assigned, not added** (#33) — carrying gives a fixed budget.
14. **Allied grabs and releases are free** (#37).
15. **Bursts can retarget for free** (#5); one unparried hit ends the burst.
16. **The AI is omniscient by design** (#43) — it plays the true board, not a fogged one.
17. **The tank's laser is gone** (#63). One weapon, one identity.
18. **Death is never spoiled** — no corpse marker, texture, or log line before the
    defence roll resolves (#6, #71, #72).
19. **The laser pays to destroy, not to pierce** (#75). Every obstacle has a price from
    the potential table; paying it removes the obstacle. A beam that cannot afford the
    next obstacle dies *in front of* it.
20. **One damage scale for everything** (#89): 1 durability = 10 laser potential = 1
    anti-tank shot = 1 drone detonation = 0.5 tank shots. It was derived from the vehicle
    data, not invented, which is why shuttle = 20 and tank = 60 potential.
21. **A hedgehog is jumped, never stood on** (#78) — modelled as a 2-point edge in the
    movement graph so pathing, previews, and the AI all inherit it.
22. **A prisoner keeps their AP** (#76). What stops them acting is the held gate in
    `_validate_actor`, not an empty AP pool — otherwise breaking free would cost the
    whole turn, and the Break Free button (which needs AP) could never be pressed.
23. **Anything that rolled dice cannot be undone** (#81).
24. **Every civilian tiebreak is fully ordered** (#79) — not for elegance, but because an
    unordered tie is a lockstep desync waiting to happen.
25. **Colour is per-viewer in network play** (#93): you are always blue, the enemy is
    always red, on both screens.

---

## 24. Known Gaps & Deliberate Non-Features

- **Victory freezes the board, it does not end the session (batch 13 #9).** `Main._winning_team()`
  runs after every resolved action — local, networked or AI — and the moment only one
  team (or nobody) has a living non-drone soldier, `_match_over` latches: a *Match Over*
  window names the winner, and from then on no intent is accepted from anyone,
  `_kick_if_ai` never wakes a machine, and End Turn is inert. Saving and returning to the
  menu still work. Replays never trigger it — the recording is the authority there.
- **Replays are not recorded in network play** — the host's dice log already occupies
  that channel (§20.1). Save a game instead.
- **AI does not** throw grenades, build, dig, pilot drones, or ram with vehicles. It
  *does* demolish obstacles in its path with a miner or engineer (#90), fly shuttles and
  shoot from their seats, and fight in a borg it climbed into (batch 13).
- **Tank-cannon AI ignores the blast-shield rule.**
- **Shuttle `driver_move_ap`, `passenger_defense_bonus`, `collision_durability_threshold`**
  are data-only and unread (§16.6).
- **AI sappers** lay mines (§17.5) but do not sweep for or disarm enemy ones.
- **No commander aura** — the Commander is stats and 3 AP, nothing more.
- **Learned (RL) enemy AI — v1 pipeline is in the repo, no shipped model yet.** The lobby has
  an "AI - Learned" slot (`LearnedController`) that talks to `rl/policy_server.py` and falls
  back to AI - Hard with a combat-log line when no model is served (§12 of the RL spec).
  Training lives under `rl/` (spec `13_reinforcement_learning_ai` rev. 2): legal-intent
  enumerator (`GameActionResolver.legal_intents()`), headless env bridge, PPO trainer, and
  the §11 dashboard served at **rlm.mindcontrolfactor.com** from the training machine. The
  shipped game still plays only the three scripted levels of §17 unless a checkpoint is
  served. In-game ONNX inference (Tier 2) is not built. See `rl/README.md`.

---

## 25. Constants Quick Reference (`MCF.gd`)

### `src/sim/MCF.gd`

```gdscript
AP_PER_ACTIVATION         = 2       # Commander overrides to 3 in its .tres
FLAT_MOVE_COST            = 1
WALL_HEIGHT               = 2.0
CLIMB_COST                = { 0.5: 2, 1.0: 3, 1.5: 4 }
COVER_MOD                 = { 1.0: 2 }         # hit penalty only, no defence bonus
HEDGEHOG_JUMP_COST        = 2                  # hedgehogs are hopped, not entered

DEFAULT_SIGHT_RANGE       = 12      # legacy; sight is unlimited since batch 13 (SIGHT_UNLIMITED = 1024)
CAPTURE_CARRY_PENALTY     = 3
CORPSE_WALL_COUNT         = 5

TRENCH_DEPTH              = 2.0
DIRT_HEIGHT_PER_LEVEL     = 1.0
DIRT_MAX_LEVEL            = 2

GRENADE_RANGE             = 12
ANTI_TANK_BLAST_RADIUS    = 1
ANTI_TANK_VEHICLE_DAMAGE  = 1
DRONE_EXPLOSION_DAMAGE    = 1       # same scale as the anti-tank shell
CANNON_BLAST_RADIUS       = 2
ASSAULT_MAX_TARGETS       = 3
ASSAULT_DEFENSE_PENALTY   = 1
FLAME_JET_LENGTH          = 6

MARKSMAN_POTENTIAL        = 10
MARKSMAN_AP_COST          = 2
LASER_COST                = { … }   # per-feature potential table, §7.3
LASER_COST_KILL           = 2
LASER_COST_KILL_CORPSE    = 3       # a carried corpse shield costs one more
LASER_COST_SHIELD         = 4       # a shield absorbs 4 and stops the beam
LASER_COST_TERRAIN_WALL   = 2       # nameless terrain wall, priced as a wall
LASER_GLASS_RECHARGE_EVERY = 2      # every 2nd pane on the line hands potential back (#99)
LASER_GLASS_RECHARGE      = 1
POTENTIAL_PER_DURABILITY  = 10      # the one damage scale (§9.8)
SNIPER_AUTOHIT_RANGE      = 12
SHIELD_PUSH_DEFENSE_PENALTY = 2

FIRE_NEED_FLOOR           = 4       # plain floor catches on 4+ (per-material table FIRE_NEED_BY_FEATURE)
FIRE_NEED_GRASS           = 2       # grass on 2+
FIRE_NEED_WOOD            = 4       # wooden wall on 4+
FIRE_NEED_WALL            = 5       # wall skins on 5+
FIRE_NEED_GLASS           = 5
FIRE_NEED_COVER           = 4       # sandbags, hedgehog, RSP, 1 m dirt
FIRE_NEED_TALL_DIRT       = 5       # 2 m dirt counts as a wall
FIRE_SHOOT_PENALTY        = 1
EXTINGUISHER_RADIUS       = 2
EXTINGUISHER_SUPPRESS_TURNS = 3

DRONE_FLIGHT_RANGE        = 30      # tiles of flight bought by one action point
DRONE_LEASH               = 15      # and never further than this from its station (item 15)
DRONE_ARMOR               = 5
DPMG_RANGE                = 12      # the RSP / ДПМГ station gun
DPMG_RATE_OF_FIRE         = 8
MINES_PER_ACTION          = 5
MINE_REVEAL_RADIUS        = 15
MINE_REVEAL_TURNS         = 1
MINE_VEHICLE_DAMAGE       = 1       # personnel mine vs a hull (only the borg's)
AV_MINE_VEHICLE_DAMAGE    = 1

AIRLOCK_OPEN_RADIUS       = 1
ZEROG_SHOOTER_KNOCKBACK   = 1
ZEROG_TARGET_KNOCKBACK    = 2

LDF_WALL_LENGTH           = 6       # the BRU / ЛДФ chain
BUILD_COST_DEFAULT        = 1       # wall / glass / BRU
BUILD_COST_SANDBAGS       = 1
BUILD_COST_HEDGEHOG       = 2
BUILD_COST_DOT            = 2
BREAK_COST                = 1

POTENTIAL_PER_DURABILITY  = 10      # the unified damage scale (§9.8)
DOT_DURABILITY            = 2       # both pillbox variants

COMPONENT_DAMAGE_ANTI_TANK = 1      # modular armour (§16.2b)
COMPONENT_DAMAGE_CANNON   = 2
COMPONENT_DAMAGE_SHIELD   = 2
COMPONENT_DAMAGE_HEDGEHOG = 2
COMPONENT_AIM_BONUS       = 1
VEHICLE_COMPONENTS        = { tank: hull 8 / tower 6 / tracks_l 4 / tracks_r 4 / gun 4,
                              shuttle: hull 4, borg: hull 2 }   # the authoritative hull values

SHUTTLE_CELLS_PER_AP      = 15      # §16.7
SHUTTLE_PASSENGER_DEFENSE_BONUS = 1
BORG_AP = 3, BORG_SPEED = 9, BORG_RANGE = 12, BORG_ROF = 4, BORG_ARMOR_BONUS = 2   # §16.8
BORG_EXPLODE_MIN = 4, BORG_BUILD_BATCH = 3, BORG_DIG_TRENCHES = 6

enum Owner      { PLAYER_1 = 0, PLAYER_2 = 1, NEUTRAL = 26 }   # 2..25 are further players (lobby)
enum Status     { ALIVE, CORPSE, HELD }
enum ActionType { MOVE, SHOOT, CAPTURE, USE_ITEM }
```

### `src/resolver/GameActionResolver.gd`

```gdscript
DIG_TRENCHES_NORMAL   = 3
DIG_TRENCHES_ENGINEER = 6
GLASS_ARMOR           = 5           # glass defends at 5+, on 2 dice (#44)
WELD_AIRLOCK_AP       = 1           # engineer welds an airlock shut (#99, §9.4)
OFFBOARD              = Vector2i(-9999, -9999)
BURNS_AWAY            = [wood_wall, wall, glass, airlock]   # cleared when the cell ignites (#83)
```

### `scenes/Main.gd`

```gdscript
MENU_ANCHOR   = Vector2(16, 16)              # every action menu, top-left (#87)
MENU_CHROME_H = 70.0                         # headroom subtracted from the scroll cap
BRU_COLOR     = Color(0.05, 0.05, 0.07)      # BRU renders black (#85)
AP_DOT_DELAY  = 0.18                         # pause between draining AP pips (#99, §14.1)
ZOOM_MIN      = 0.12                         # whole board at once (#103, §18.4)
MOVE_LABEL_MIN_ZOOM = 0.45                   # below this a cell cannot hold a number (#103)
```

---

## 26. Change Log — Tasks #1 – #106

Every numbered task, verbatim from the tracker. All are **completed**. Where a task
number appears elsewhere in this document it is because the source comments cite it.

| # | Task |
|---:|---|
| 1 | Fix: leftover-move click does nothing |
| 2 | Fix: additional dig click does nothing |
| 3 | Fix: move+shoot both pending shows only shoot |
| 4 | Grenades only throwable orthogonally |
| 5 | Finish burst can retarget different unit |
| 6 | Corpses as pickable objects giving +1 defence cover |
| 7 | Anti-tank hit roll with reduced-distance miss explosion |
| 8 | Scrollable popup action menus isolated from camera |
| 9 | Camera movement during army buy phase |
| 10 | Purchase machinery in buy phase |
| 11 | Drag-to-place units in buy phase |
| 12 | Fog of war checkbox off by default |
| 13 | Drones fly over and stand on corpses/units |
| 14 | Fix carrier can't move twice while holding a unit |
| 15 | Allow shooting through ground corpses |
| 16 | Fix trench dig: dirt pile placement + multi-dig per AP |
| 17 | Explosions destroy walls/windows/airlocks/stations/RSPs |
| 18 | RTS-style multi-select and move units |
| 19 | Group action menu for multi-selected units |
| 20 | Fix clicking green move tiles selecting instead of moving |
| 21 | Multi-select toggle button gating box selection |
| 22 | Drone spawns on top of its drone station |
| 23 | Click cycles drone first then unit underneath |
| 24 | Remove emojis from the battle log |
| 25 | Grab action includes movement allowance |
| 26 | Fix additional trench digging doing nothing |
| 27 | Rework height cover rules |
| 28 | Set RSP, sandbags, hedgehog, drone station to height 1 cover |
| 29 | Engineer builds sandbags for 1 AP |
| 30 | All units can grab and drag sandbags and hedgehogs |
| 31 | Stack sandbags to height 2 and hedgehog-on-sandbags wall |
| 32 | Interleave fragmented actions freely |
| 33 | Fix grab move ignoring carry penalty |
| 34 | Drag sandbags/hedgehogs like carried soldiers |
| 35 | Fix stacked sandbag tile label and overlap |
| 36 | Let engineers build anti-tank hedgehogs |
| 37 | Free break-free from an allied holder |
| 38 | Add a Redo button next to Undo |
| 39 | Tank turning: pick direction, cost 1 AP |
| 40 | AI grabs corpses blocking paths or near enemies |
| 41 | Rework grenade blast rules |
| 42 | Give civilians their own turn |
| 43 | Allow digging trenches under other units |
| 44 | Grenades only break glass, which defends at 5+ |
| 45 | Fire spreads on its creator's turn |
| 46 | Double-speed dice animation for 1+ hit rolls |
| 47 | Vehicles block line of fire |
| 48 | AI keeps 1 cell away from fire |
| 49 | Marksman fires in a direction, laser travels forward |
| 50 | Fix: can't capture/grab sandbags |
| 51 | Fix: trench digging under units and multi-dig |
| 52 | Reduce AI turn lag; move units one after another |
| 53 | Initiative system modeled on isotope |
| 54 | Shrink gameplay side menu; split multiplayer into its own main-menu tab |
| 55 | Port texture replacement system from marble_race |
| 56 | Copy civilian system exactly from isotope |
| 57 | Build 50×50 town map with civilian zones |
| 58 | Tanks can't shoot through other units or tanks |
| 59 | Render corpses under tanks and as red 50% circles |
| 60 | Fix AI handing its turn to the player with many units |
| 61 | AI anti-tank units attack tanks and shuttles |
| 62 | Tanks fire from all 3 cells on each side |
| 63 | Remove tank lasers and reshape the explosion radius |
| 64 | Preview X-shaped blast for grenades and extinguisher |
| 65 | Fix: 1-cell move in/after a trench blocks all further actions |
| 66 | Give commanders 3 action points |
| 67 | Fix vehicles not losing durability to anti-tank fire |
| 68 | Destroyed vehicles trigger an explosion roll |
| 69 | AI only shoots shield bearers when adjacent |
| 70 | Fix tanks shooting through walls, BRUs and 2 m dirt piles |
| 71 | Show a marker on units carrying a corpse |
| 72 | Choose the tile when dropping a corpse |
| 73 | Fix button labels truncated to ~2 letters |
| 74 | Add a Return to Map button that recentres the camera |
| 75 | Lasers destroy what they hit, priced by the potential table (§7.3) |
| 76 | A carried prisoner spends no AP during the grab or the move (§8.1) |
| 77 | Deploying a drone station launches a drone with it (§13) |
| 78 | Hedgehogs cannot be stood on — they are jumped for 2 movement points (§5) |
| 79 | Civilians actually take their turns: walk to the nearest soldier and shoot (§14) |
| 80 | All BRU tiles must form one orthogonally connected chain (§9.3) |
| 81 | Shooting is un-undoable — anything that rolled dice clears the undo stack (§18.2) |
| 82 | Building, digging, or dragging onto a burning cell extinguishes it (§10) |
| 83 | Fire destroys the wall / glass / airlock on the tile it burns (§10) |
| 84 | BRU does not burn and fire cannot spread through it (§10) |
| 85 | BRU renders black (§18.6) |
| 86 | Embrasure pillbox — adjacent soldiers shoot through it, anti-tank cannot (§6.7) |
| 87 | Action menus anchored top-left and scrollable (§18.6) |
| 88 | Group move preview: green reach plus yellow placement circles on hover (§18.3) |
| 89 | Pillbox durability 2 on the unified damage scale; direct hits absorbed whole (§9.8) |
| 90 | AI miners and engineers breach obstacles instead of walking around them (§17) |
| 91 | Buy a civilian for 20 points; free placement is the default (§19) |
| 92 | LAN / Radmin VPN multiplayer over the ENet session (§22.2) |
| 93 | Networked match flow: A/B sides, private deployment, shared seed, per-viewer colours, defender rolls their own dice (§22.3) |
| 94 | Undo is limited to the current turn and offered only on your own turn (§18.2) |
| 95 | Fix crash on boarding a vehicle — a passenger no longer gets an infantry menu (§16.1) |
| 96 | Bought civilians are ordinary soldiers of their side; NPC civilians walk cell-by-cell and roll dice you defend against; bursts roll every bullet; eight-direction vehicle facing renders correctly; drones hover over walls without crossing them; anti-personnel net removed (§14, §6.4, §16.3, §13) |
| 97 | Hover previews redraw on mouse motion instead of waiting for a camera nudge; selecting a soldier clears the tank so the menu no longer reverts; a unit with nothing left to do shows no menu; blasts flatten hedgehogs and dirt piles along with walls; a corpse on the ground grants no cover; vehicles bank unspent movement and finish the drive for free; a crushed unit leaves a corpse instead of vanishing (§18.1, §18.3, §15, §6.5, §16.3) |
| 98 | Corpses stack up to 5 per tile behind one unified count, drawn as a single marker with a number; the fifth body forms a corpse wall; blowing that wall up scatters the 5 bodies onto random empty tiles from the recorded dice (§8.4) |
| 99 | A neutral zone on a map fills with civilians; the laser aim preview shows each object's potential cost and where the beam dies; new potential table (1 m cover 1, BRU 4, airlock 1, glass free and every 2nd pane refunds 1, shield 4 and stops the beam, pillbox 20 / 10 per durability, vehicles 10 per durability, corpse wall 3 and scatters); lasers fly over trenches instead of destroying them; civilians obey firing lines, cover and LOS like everyone else; engineers weld airlocks shut for 1 AP; dropping a corpse works at 0 AP; a drone's descent from a wall is free; AP dots drain visibly during enemy and civilian turns; the multiplayer host runs a full match setup — map, budget and purchase phase — once a player joins (§14, §7.3, §9.4, §8.4, §13, §14.1, §22.3) |
| 100 | The purchase phase draws the real map — floors, cover tints, feature tags and heights — instead of blank squares; airlocks are plannable terrain, so movement, carry drops, the AI's geodesic field and civilians all route straight through a closed door that will slide open (welded ones stay walls forever), and the doors are re-evaluated after every move; friendly fire — you may aim at anyone but yourself, and a shot that passes a living body is redirected into that body (marksman lasers pierce, flamethrower jets cover the line); civilians think with the AI's brain — multi-source geodesic pathing, cover-aware step scoring, and a target picked among the soldiers they can actually shoot; a soldier can be grabbed only once per round, and a captor may shift his captive to any neighbouring cell for free; a man in a trench is untouchable by lasers fired along the surface; and the AI is now a commander that plans the entire turn up front — it scores every (unit, cell) pair for firing opportunities, advance, cover, exposure and firing-lane conflicts, assigns each soldier a unique destination army-wide, and orders activations so a man standing in a promised cell moves out of the way first (§9.4, §6.6, §14, §8.1, §7.3, §17) |
| 101 | Optimization pass — no rule, number or decision changes, only the cost of computing them. Reachability, fog of war and enemy exposure are cached or precomputed instead of rebuilt from scratch; every hot line-of-sight walk stopped allocating throwaway arrays; the per-frame tile loop stopped rebuilding constant tables. Equivalence is enforced by a golden trace, not by argument (§27) |
| 102 | Large-battle pass — again no rule, number or decision changes, only the removal of costs that grew with army size. The AI scores a cell against the handful of enemies actually standing on a firing line with it instead of against every enemy alive; fog of war is kept per soldier and mended in place, so one man's step costs one comparison and a collapsed wall re-casts only the sight windows that wall stands in; airlocks are indexed instead of found by sweeping the map after every action; target lists reject a candidate by subtracting two vectors instead of running the full shot check; and the undo snapshot is taken only on a turn that can actually be undone. A 100-v-100 turn went from 3.9 s to 0.31 s (§27.8–§27.12) |
| 103 | One unit per cell is enforced by the board itself — `Grid.place` and `move_occupant` refuse to overwrite an occupant and report failure, so no two soldiers, civilians or AI units can ever share a tile (§2.2); hovering a green move tile draws the **cheapest actual route** to it out of the Dijkstra tree, and every green tile is labelled with what standing there costs out of the movement total (§18.3); a marksman's laser no longer reaches a man in a trench from a tile that is not one, at any range including adjacent (§6.6, §7.3); NPC civilians and the army are driven by **one brain** — the second, cell-at-a-time civilian AI is deleted and a civilian is now an `AIController` with the Neutral owner, so it plans, fragments its movement, fires partial bursts and hauls corpses by the army's rules (§14, §17); the AI uses fragmented movement and partial bursts — `move_credit` is a spendable budget, a step costs score, and a burst orders `ceil(1/p)` bullets instead of the whole magazine (§17.3); an anti-tank sapper cut off by a wall **blasts through it** instead of shuffling along it (§17.3, §7.1); the AI and civilians pick up bodies that block the road and **stack them aside into piles**, the fifth forming a corpse wall (§17.3, §8.4); at least 80% of an army must act each turn and **every** civilian must, enforced by a second forced pass over whoever the plan left idle (§17.2); Player 1 can be an AI too, so AI-vs-AI matches run from Setup or a mid-battle toggle (§17.4); and the camera zooms out to 0.12 so a 60×40 board fits on one screen (§18.4) |
| 104 | The map editor can be left the way it was entered: the **"To Demo Game"** button is gone, replaced by **"Main Menu"**, which clears `MapHandoff.pending` and returns to `MainMenu.tscn` instead of dumping the designer into a demo battle on the built-in roster (§19) |
| 105 | A marksman firing **from** a trench is as boxed in as a marksman firing **into** one: the laser cannot climb out of the ditch any more than it could drop into it, so from the trench floor the only reachable target is one lying in the **same continuous run** of trench, along a straight line with no gap — a bend or a break means the beam hits the earth wall. The trench is now symmetric cover against the beam instead of a firing position that ignored its own walls (§6.6, §7.3) |
| 124 | **Release 0.9.2** (issues-fix-4) — **Glass** (§16.2d): window shots are a normal burst with a chosen bullet count, and glass on the line is crossed pane by pane (hit the pane, it saves, it shatters, survivors fly on; misses are lost; armored glass counts). **Before / After** is a toggle in the battle sidebar that shows the opening board (terrain, room floors, units, vehicles) over the live one (`Main._capture_opening_view`, `BeforeLayer`); the end-of-battle comparison is gone. **Editor**: edits after the cursor preview no longer vanish from the canvas — the preview's log snapshot aliased the live packed arrays (`GridCell.logs_snapshot` copies them); the minimap shows objects on grass; New Map no longer reads freed fields after the "lose changes" confirm; Circle tool (C), Rectangle on U, + / − zoom, Esc to leave, Save As removed, R turns furniture (brush, selection, saved `feature_turn`), furniture palette by height, room-floor brushes, chunkier icons, padded panels. **Furniture**: wear removed; every blast (frag grenades too) destroys any piece; L/ring shapes keep one back and mitre their corners; sandbag/trench fields have no corner holes; new toilet, sink, console, practice target, vent fan. **Look**: Handjet font everywhere, mono status text gone (bold accent Handjet); doors and airlocks seen from the front; cracked pillbox tiles. **Maps**: stations and bunkers by department, towns by district, room floors by purpose (display-only `floor_look`), toilets, solar panels (§20.2). Tests: `tests/run_batch092.gd`, editor checks in `run_editor.gd`. |
| 123 | **Furniture doesn't re-join in battle** (§9.9) — the battle screen snapshots each furniture cell's joins, inner corners and turn when the match opens (`TerrainTiles.freeze_furniture`, `Main._furniture_look`) and draws from the snapshot: smashed, burnt or flattened cells leave their neighbours as they were (half a bed stays half a bed), a blown wall doesn't turn the furniture beside it, and a piece dragged to a new cell joins nothing. Generator, editor and deployment screen still join live. Rules unchanged. Tests: frozen-look checks in `run_furniture.gd`. |
| 122 | **Furniture and editor polish** (§9.9) — 8 new pieces (potted plant, TV stand, stove, piano, bunk bed, water cooler, washing machine, fuel tank) and colour variants (`Furniture.VARIANTS`) that keep the base piece's rules; random maps and street clutter pick a colour once per recipe step; different colours never join. Joined tiles have no seam between cells, and L-shaped pieces cut their inner corners. Editor: fixed the typed-array error that broke every tool but Brush and Eraser (R → Rectangle tool hit the same error, and the game paused in the debugger). The preview under the cursor is now drawn by `TerrainTiles` on a scratch grid (`TerrainTiles.scratch`, with `origin` for the variant hashes). That gives the brush, line, rectangle, fill, stamps and pastes exactly the tiles they will place: walls join their neighbours, doors turn with the wall, furniture joins and turns to the wall. Brush previews draw at 50 %, patterns at 75 %, and oversized pastes fall back to palette pictures. The palette has one button per piece, a *Colour* row under the brush name, and wrapped labels. The cell grid in the battle screen, deployment screen and editor is now drawn between the floor and the objects (`TerrainTiles.draw_grid`): it shows on floors and no longer cuts across walls or multi-cell furniture. A whole piece puts its headboard only on a short side and a sofa or desk back only on a long side; with no wall there, it takes the default turn instead of turning sideways to the wall. |
| 121 | **Furniture** (§9.9, §20.2) — 41 pieces as ordinary cell features in `src/data/Furniture.gd`, multi-cell beds, tables, sofas, desks, machinery (whole pieces) and counters, shelving, lockers (runs) joined by autotiling: heights 0.5/1/1.5/2 m through `cover_height` (climbed by the usual costs, 2 m is a wall), a furniture-only −3 cover at 1.5 m, carrying portable pieces (`CarryIntent`, put down free via `UseItemIntent`), dragging heavy single-cell ones through Grab (nothing that is part of a multi-cell structure can be grabbed), any soldier smashing furniture for 1–3 AP via `BreakIntent`, blasts/laser/fire/tracks by durability and material; baked into the tile chunks turned to the wall, cracked when damaged; editor palette groups; `MapData.feature_dur` for damaged pieces. Random maps gain a FURNITURE phase (`MapFurnish`): room purposes per style, recipe placement, clutter, wear, walkways kept by construction; lobby *Furniture* (Off…Very dense, default Normal, independent of *Obstacles*; furnished station/bunker rooms skip the obstacle crate piles) and *wear*. Tests: `tests/run_furniture.gd`, editor checks in `run_editor.gd`; the perf bench pins furniture Off and now compares the full board after save/load and replay. |
| 120 | Performance only, no rule changed — the general optimization audit (§27.22): a reproducible benchmark and behaviour harness `tests/bench/run_bench.gd` (small/medium/large Hard-vs-Hard MapGen matches through the net layer, save/load and replay, plus a battle-screen render mode; `run_all.sh` checks the small and medium hashes); `all_units()`/`all_vehicles()` return a cached read-only list (`remove_unit`/`remove_vehicle`); the clock rebuilds its text once a second; group membership in `_draw` is a set; `digest_hash` builds the identical string with `str()` (−20 %). The HUD grip, vehicle lookups, the "!" check, the dice queue, AI temporaries and FX RNG were measured and left unchanged. |
| 119 | Editor rework and UI audit — the map editor is rebuilt "like Paint": menu bar, icon toolbar, a palette of real tile thumbnails, minimap and status bar; the canvas draws the battle's own tile chunks; undo stores per-cell deltas; symmetry (L/R, T/B, quarters, zones handed to the matching player), select / move / copy / paste with rotate and flip, room and building stamps, eyedropper, New Map from the random generator, and Play This Map returns to the same map (§19). Map presets (Station, Town, Field, Bunker, Asteroid) set the tileset and pre-fill a new map (§20). Nothing burns in vacuum (§10). UI audit at 75/100/150 %: main-menu sub-pages, purchase panel, battle sidebar and lobby dialogs are framed in group boxes, main buttons stay on screen, the lobby puts slots and map first when its columns wrap. Tests: `run_editor` (new, 55 checks), `run_fire` (vacuum), `run_batch13` ported. |
| 118 | Playtest batch (20 items + 2) — **Unready** on the purchase screen: only the host starts the battle (`go`), a guest's unready is a request the host confirms (`unready_req` → `unready`), and a ready army is locked until unready (§19); **Fullscreen** in Settings → Display, saved in `settings.cfg`; the **Real** clock starts with the battle scene — network games used to count from app launch, so it also ran on across matches; **double-click** on a shuttle passenger selects the shuttle, and the driver's seat has a thin outline (§16.7); a **welded airlock** gets steel straps and weld beads baked into its tile; decals are no longer wiped by undo/redo or by a network resync (the restored host decals were cleared right after loading), laser marks and the new **tank track marks** travel in the decal snapshot, and the casing/laser caps rise to 8000/2000; Godot's ENet timeout is relaxed to 20–90 s so a short stall no longer hands a friend's army to the AI (§22.4); running over own/allied units and blowing a drone up next to them ask first; the **Match Over** window lists kills per unit and vehicle with run-overs (`GameState.kills`, part of the undo snapshot and `StateCodec`, not the digest); under standard fog, hidden walls get a much darker veil, corpses stay visible, and trenches, sandbags, dirt piles and hedgehogs are drawn only where seen now (§11); **Undo drawing** (button or Ctrl+Z while drawing) restores the touched raster tiles and is mirrored to every peer; bodies killed by fire, flame or laser are drawn burnt (`UnitInstance.burnt`); breached civilians are ruthless and grab every body within reach without ever dropping one (§14); the turn line and the initiative window agree — Prev/Next skip slots with nobody alive, the line follows the neutral group being played, and the window scrolls and leaves out wiped-out groups. Golden trace re-baselined: civilians now shoot instead of dodging, which shifts the dice stream. |
| 117 | Gore / trenches / AI batch — civilians' wake-up sight check indexes soldiers by firing line instead of testing every civilian against every soldier after every action (6-side MP host: 92 → 19 ms per AI action, p99 frame 90 → 17 ms, measured); AI speed adds 8×, 16× and Max, and from 8× AI dice are not animated (§18.6); the initiative window no longer keeps pointing at the last civilian group after their slots play; civilians are a random-map setting again (up to 1000), prepared maps get an on/off checkbox (§14, §20.2); your own deploy zone is outlined on the purchase screen and zone numbers sit on the lobby preview (§19); terrain tiles are 32×32 in the same brutalist style, stay textured at every zoom (8-px chunks for far zoom), town and field airlocks are drawn as doors (closed and open), the concrete wall loses its tie marks, and trenches are cut into the ground with continuous corners and junctions and units sit inside them (§21); bigger blood pools and spray, gibs and ring splatter for blast and crush kills, blood for laser/assault/push/DPMG/crush kills, and 6 tiles of fading footprints after walking through blood (§21.4). Tests: suite green; `net_host_town` uses the new checkbox. |
| 116 | Team-session batch (3 humans vs 3 AIs) — anti-tank checks an occupied target cell like any other, so Hard AI no longer fires along illegal lines or rolls hopeless 7+ checks (§7.1); marksman volley and a friendly-in-the-beam confirmation (§7.3); the civilians slider caps every map's neutrals with an even spread (§14, §20.2); team camera row, baked 64-px terrain chunks (§18.4); real tumbling dice (§18.5); host-only AI speed, resizable glass log and chat with working scrollbars, Paint-like raster drawing with a pixel eraser (§18.6); game modes removed, chat in the lobby and on the purchase screen, deploy zone drop-down with a live preview and bands that placement now honours (§19); map environments with their own tiles, the Asteroid style and per-style Space / Flammable defaults (§20.2); the "MCF: Alert!" UI kit with an accent colour and an interface-size setting, 64×64 brutalist tiles in six variants with family autotiling (§21); glass shards spread, stop at walls and stay visible to whoever saw the pane break (§21.1); chat labels built by the receiver, so LAN players are no longer all "(you)" (§22.4). Tests: `run_team_session` (new), `run_mapgen` (environment tags, Asteroid), `run_lobby_maps` (slider), `run_shuttle` (its heavy-hit shell had flown through a soldier standing on the row; he now steps aside first, and the block itself is asserted). |
| 115 | Faster boot — the main menu appears in ~0.5 s instead of ~1.2 s (headless, measured). The menu named `LearnedController` as a class, which compiled the whole resolver before the first frame; it is now `load()`ed only where the `--vs-latest` check needs it. Once the menu is on screen, the `Ui` autoload compiles the lobby and battle scenes in the background (`Ui.warm_up` — one `ResourceLoader.load_threaded_request` at a time; parallel requests raced on shared scripts), so *New Game* does not pay for it. No rule changed. |
| 114 | Group orders move the whole selection — the group planner simulates execution order (front unit first, squadmates' vacated cells free, taken cells blocked), so the middle of a blob and the tail of a corridor column are no longer dropped from the order; distance is steps round walls with straight-line ties, so far orders keep formation instead of drifting to the map edge; and a **Tactical Move** puts each unit in the best cover within 3 tiles of its plain-move spot against visible enemies (every side under fog) (§18.3) |
| 113 | Airlocks, civilians and Colossal maps — every door of every room, house and hut is an airlock whatever the Space toggle; civilians come in five magnitudes (None to Crowd) and live only in rooms sealed by airlocks, so nothing at the start of a match can wake them; a custom map size has no upper limit; mirrored placement carries the army zone to zone by the map's own symmetry (or the best-overlapping grid motion), so every side gets the same units wherever its zone is (§19, §20.2). Performance only, no rule changed: undo journals the touched cells instead of copying the board (§18.2); a zoomed-out battle screen draws the board as cached textures and the purchase screen culls to the viewport (§18.4); fog drops only the cached views a change can reach (§11); objects, mines, stations, airlocks and fire are indexed and patched from a cell log; the AI's distance field walks a cached passability mask (§27.21). A 91-action Hard-vs-Hard game on a 250×250 town: 31.2 s → 1.5 s |
| 112 | Batch 17 (the "Isotope issues fix 8" report) — boarding a shuttle or a borg is free and allowed at 0 AP, so a fresh operator has the borg's full 3 AP (§16.7, §16.8); the move budget is one function (`move_budget`, `nearest_reachable`, `can_move`) shared by the screen, the group order and the resolver, and a group mover whose target was cut off by a squadmate falls back to the nearest reachable cell inside the resolver (§18.3); the host answers a refused guest intent with `K_DENIED` so the guest sees why (§22.1), and the Laser button explains its 2-AP gate; the flame jet is one geometry (`flame_cells`) for the shot and the preview, and a splash side cut short by the wall hands its cells to the other side so the jet always burns six (§7.2); a player's bought civilian is a target but not a threat to neutrals, so they shoot it instead of fleeing its lane (§14); every vehicle leaves a wreck and an explosion scorches the floor through `_blast` (§16.5); the drone operator's "!" means "station deployed" (§9.3); drawings gain *Share with everyone*, *Hide my drawings* and *Hide all drawings*, an AI-driven side is never the viewer's own, and a leaver's strokes are dropped (§18.6); factions replace colours with faction-suffixed soldier art, corpses are the soldier's art turned 90° clockwise, walls autotile from a 4×4 sheet, and real blood decals ship (§21) |
| 111 | Performance only, no rule changed — the line-of-sight ray in `_seen_from` reads a flat per-cell "blocks sight" byte table (rebuilt with the LOS cache on every `vision_version` step) instead of fetching the `GridCell` object twice per step; the visible set is bit-identical (verified against the old routine on the town map, before and after a wall fall and a glass build), and a cold recompute of one side's view on the town map drops from ~1.0 s to ~0.45 s — the freeze at match start, on *Load Game* and on every `K_RESYNC` with fog on (§11) |
| 110 | General sweep (random-map fuzz, random-intent fuzz, lockstep twin) — six sim fixes, no rule changed: `StateCodec` restores a vehicle's **saved hull** instead of a fresh one (every load and every `K_RESYNC` used to heal damaged tanks, shuttles and borgs to full); a refused intent no longer touches the board (`dig_credits`, `dragging`, `combat_started` were cleared **before** validation, so a host-refused shot silently cost an engineer their trench series and desynced the guest); zero-g recoil and knockback skip seated passengers (§12, §16.7 — they were thrown off the hull while still "aboard"); a borg operator must climb out before boarding another vehicle, and `VehicleMove/Turn/Cannon` are refused for a borg outright (§16.8 — a round boundary gave the borg a crew-AP pool and the hull could be driven away from its operator, leaving a ghost footprint); an exploded borg clears its dead operator's `borg_id`; `Vehicle.seats` is allocated on construction; `VehicleDB.tank.durability` now reads 8 like `VEHICLE_COMPONENTS` (§16.1). Tests: `run_codec` spawns damaged vehicles, `run_shuttle` fires in zero-g, `run_borg` tries the tank from inside a borg, `run_player_actions` refuses a shot mid-dig on the host only. |
| 109 | Batch 14 (the "Isotope issues fix 2" report) — every network action carries the host's board hash and a guest that disagrees, refuses an accepted action, or has dice left over pulls the host's full state and continues (`K_RESYNC` / `K_STATE`, §22.1); the match result is declared by the host only (`K_OVER`); the dice window survives a play started on top of a waiting one (§18.5); the players' initiative order is a dice shuffle, Player A is no longer first by right (§3.2) — and a match with civilians in which both armies are dead no longer hangs the end-of-turn on an all-neutral rotation; boarding a shuttle always offers the seat choice with the driver's seat labelled, and a seat-mounted drone station takes its drone along when the shuttle moves (§16.7); the map editor has undo/redo (§19); a guest entering the lobby asks the host for the snapshot, the host caches the selected map and draws big previews at a pixel per cell (§22.4); Black and White join the palette and the colour swatch is a square; tests: a fourth two-process net pair on the town map with a deliberately corrupted guest board that must recover, and the other pairs are order-agnostic |
| 108 | Batch 13, part 2 — **the seated shuttle**: passengers sit in the hull cells, are drawn on top, shoot from their seat with their own weapon and AP and can be shot at (+1 hull cover); whoever sits in the driver's seat pays 1 of their own AP per 15 cells flown and there is no crew pool; boarding picks a seat, switching costs 1 AP, exiting is free through the seat's own side; a heavy hit kills the passenger on the landing cell, everyone else aboard rolls defence, the hull takes its damage; the hull is the shuttle's only component; a dead passenger holds the seat until pulled out; a drone station mounts in an empty seat and rides along; the AI flies and fires from seats (§16.7). **The borg**: a 100-point 1×1 vehicle played as a unit — the operator stays on the grid with 3 AP, 9 movement, −2 to their armour threshold, a 12/4 gun (abilities kept; the engineer keeps its own gun and builds in batches of three per AP), fire immunity, no trenches, AV mines hurt the hull, small arms never do; at hull 0 the operator dies and a 4+ explodes it in a 3×3, otherwise a wreck stays; a dead operator is pushed out by whoever boards next; the AI climbs into one it finds (§16.8). All unit stats are now read through `UnitInstance.speed()/armor()/fire_range()/rate_of_fire()` |
| 107 | Batch 13 — sight is unlimited in every direction and stops only at walls and closed airlocks: units, corpses and vehicle hulls never block it, and a vehicle sees through its crew from every hull cell (§11); a player who leaves the lobby, the deployment or the battle is replaced by a Hard AI, and a host left alone keeps playing (§22.4); *Save Game* is back in the side panel and the pause button just says Pause (§18.6); a corpse in an airlock holds the doors open and blocks welding (§9.4); an eraser tool on the purchase screen (§19); the map editor draws in constant time from a one-pixel-per-cell base texture with viewport culling and LOD, resizes without wiping, and is laid out as a workflow with lit toggle buttons, a brush size and confirmations (§19); a match freezes with a *Match Over* window the moment one team is left (§24); the guest is seated in a hand-reserved Player slot and can re-request the match setup if it missed it, and a typed budget survives a colour change (§22.4); mirrored placement is live — the mirror follows every change, there is no stamp step and a mirrored guest confirms automatically (§19); the vehicle component panel stands beside the action menu instead of under it (§18.6) |
| 106 | Large-scale optimization pass — as with #101 and #102, **no rule, number or decision changed**, only the cost of computing them, proved by a byte-identical golden trace over a 360-unit, 300-corpse, 6-round battle. `team_sees` answers a point query directly instead of rebuilding the entire team's fog of war for every shot; airlocks are re-evaluated from their own 3×3 neighbourhood instead of by sweeping all units; the AI's geodesic field became `GeoField` — a flat `PackedInt32Array` built by an allocation-free wave — instead of a dictionary of `Vector2i` keys; the Dijkstra frontier uses tombstones with remembered slots, in-place decrease-key and a monotone early break, all three provably picking the same cell as the old linear scan; `GridCell.burning` lets the fire check exit before touching a single neighbour; and the AI stopped rebuilding enemy lists, geodesic stamps and per-candidate dictionaries inside its hottest loops. A six-round battle at 360 units went from 31.1 s to 3.90 s (§27.14–§27.20) |

---

## 27. Performance & Caching Contract (#101, #102, #106)

The optimization pass changed **no rule, no number and no decision** — only what it
costs to compute them. Everything in this section is invariant-preserving by
construction, and the invariants below are load-bearing: break one and the game starts
playing differently while still looking correct.

### 27.1 How "no gameplay change" was proved

Not by reading the diff. A **golden trace** harness plays a fixed-seed AI-vs-AI match on
a fixed 34×26 map — 6 rounds × 3 slots, plus a civilian turn — and writes every action
line, every dice event, every death and a full board digest (per-unit coord / owner /
status / AP / move credit / captor / carried state, plus every non-empty cell's feature,
height, fire, dirt, corpses and welded flag). The trace must come back **byte-identical**
after every single change. It did, for all of them.

This matters more than it sounds, because the AI's choices are **order-sensitive** (see
27.2). A refactor can produce the same *set* of legal moves in a different *order* and
the army will silently deploy differently. Only a byte-exact trace catches that.

### 27.2 The order-sensitivity invariant (do not "improve" the Dijkstra)

`AIPlanner` resolves equal scores through a non-stable `sort_custom` over rows generated
by iterating `reach.cost.keys()`. Therefore **the key-insertion order of
`Movement.reachable`'s `cost` dictionary is gameplay-relevant.**

Consequences that must be preserved:

- The frontier pops the **first strictly minimal** element, found by linear scan.
- Neighbours are visited in `Grid.N8` order, which reproduces the original
  `dy ∈ [-1,0,1] × dx ∈ [-1,0,1]` nesting exactly.

A heap or bucket priority queue would turn the O(n²) scan into O(n log n) and yield the
same reachable cells — in a different order, and the army would stand differently. The
speed-up here is therefore purely mechanical: frontier costs are mirrored into a flat
`int` array so the min-scan stops hashing `Vector2i`, the cell is fetched once per
neighbour instead of four times, and the source cell's height is read once per pop.

#106 added three more mechanical steps, each of which provably picks the *same* element:

- **Tombstones instead of `remove_at`.** A popped entry is overwritten with a sentinel
  cost `TOMB = 1 << 30` rather than spliced out. Since every real cost is ≤ budget, a
  tombstone can never win the minimum, and the surviving entries keep their relative
  order — so "first strictly minimal" is unchanged. The point is not the avoided memmove
  but that **frontier positions never shift**, which lets a `slot` dictionary remember
  where each live cell sits. Previously every decrease-key ran `frontier.find()`, a
  linear `Vector2i` search, and that was the profile.
- **Decrease-key in place.** The old code appended a *second* entry for a cheapened cell
  and read its cost from the dictionary, so both copies reported the new cost and the
  earlier position won. Writing `fcost[at] = new_cost` reproduces that outcome without
  the redundant second pop.
- **A monotone early break.** Dijkstra's extracted costs never decrease, so the previous
  pop's cost is a valid lower bound `lo` for the next one. The scan stops the moment it
  sees a cost equal to `lo`: nothing later can be strictly smaller, and everything
  earlier was already examined and found no smaller — so the entry found is exactly the
  first strictly-minimal one a full scan would have returned.

One experiment is recorded here so it is not repeated: replacing the tombstones with a
**singly-linked list of live entries** — so the min-scan walks ~50 live slots instead of
~170 array positions — produced a byte-identical trace and **no speed-up at all**.
Pointer-chasing with an extra load per step costs what the contiguous `int` scan costs.
It was reverted.

### 27.3 `GridCell.walk_version` — the cache invalidation spine

`GridCell` carries a static `walk_version` counter. Every field that can affect
`walkable_terrain()`, `Grid.blocks_walk()` or the cost of entering a cell —
`occupant`, `vehicle_id`, `feature_id`, `dirt_level`, `cover_height`, `airlock_welded` —
is a **property with a setter** that bumps it. Fields that cannot affect passability
(`on_fire`, `fire_owner`, `floor_type`, `corpse_count`, `feature_owner`,
`feature_durability`) deliberately have no setter: spurious bumps only cost speed.

Two rules follow, and both are enforced by the smoke test:

1. **Never write these fields around the setters.** Ordinary `cell.occupant = u` is
   correct; anything that bypasses the property would leave the caches stale, which
   surfaces as units pathing through walls that no longer exist.
2. **A write of the same value must not bump the version.** Each setter returns early on
   an unchanged value. This is not a micro-optimization — `update_airlocks()` runs after
   *every* action and reassigns each airlock's height, almost always to the value it
   already had. Without the guard, every action would flush every cache and the caching
   would buy nothing. (Measured: it is the difference between a 53 ms and a 39 ms AI turn.)

`Grid._init` also bumps the counter, so a freshly built grid can never be served entries
cached for a freed grid that happened to reuse its instance id.

### 27.4 What is cached, and why it is safe

| Cache | Key | Invalidated by | Safety condition |
|---|---|---|---|
| `Movement._cache` — Dijkstra spills | grid instance + start + budget | `walk_version` change | Every consumer treats `Reachability` as **read-only** (`cost.keys()`, `cost[c]`, `can_reach()`, `path_to()`). One shared object is handed to all hits. |
| `GameActionResolver` fog of war | owner | army composition/placement + terrain that blocks sight | Both call sites only test membership. Living units do not block vision, so enemy positions are correctly absent from the signature. Reworked in #102 — see §27.9. |

If you ever need to **modify** a returned `Reachability` or fog dictionary, copy it
first — mutating it corrupts every other holder.

The fog cache is the single largest win in the whole pass, because `_draw()` asks for it
once per frame and, with fog on, computing it means a ray-cast per cell in every
soldier's sight radius: **4.06 ms every frame**, on a completely static picture.

### 27.5 Precomputation inside one AI plan

Within a single `AIPlanner.plan()` call nobody moves, so anything derived purely from
unit positions is a **constant** and is computed once instead of per candidate cell:

- **`_lane_cells`** — which friendly shooter's line of fire crosses each cell. Formerly
  `_lane_conflicts` rebuilt every ally→enemy segment for every candidate cell, twice.
  A cell stores the *set* of ally ids (not a count), which preserves the original
  `break`'s "count each ally once" semantics.
- **`_exposure`** — how many enemies can shoot each cell. Built by marching eight rays
  out of each threat. The march stops exactly where `_fire_ease` used to answer "no":
  when `hit_number` reaches 7 (it is non-decreasing in distance, so the cut is sound) or
  when a wall or vehicle hull enters the ray — including the same embrasure exemption
  `los_blocked` grants a pillbox or sandbags at distance ≤ 1. Marksmen ignore both range
  and cover, so their rays run to the map edge.

Together these took `AIPlanner.plan` from 73 ms to ~9 ms per call.

### 27.6 Allocation discipline in hot paths

GDScript allocates an Array for every array literal in a function body and for every
`range()` in a loop header. In functions called thousands of times per turn this
dominates the actual work. Accordingly:

- `Grid.N8` / `Grid.N4` are typed `const` tables, built once.
- `los_blocked`, `_wall_between`, `_fire_between`, `_fortification_between`,
  `first_unit_on_line` and `_vision_blocked` all **step the ray inline**; none of them
  builds an intermediate cell list any more. (`_ray_cells` was deleted outright — it had
  no callers left.)
- Min-scans and radius sweeps use `while` loops rather than `for i in range(...)`.
- `Main.gd`'s per-tile draw loop no longer rebuilds the 16-entry feature-tag dictionary
  per cell per frame (now `const FEATURE_TAGS`) nor formats a height string per cell
  (now `const HEIGHT_LABELS`), and reads cells through the bounds-free `cell_fast`.
- `Sprites.draw_texture_override_rect` exits before `to_lower()` when no replacement
  textures are installed at all, which is the common case.

### 27.7 Measured result

Same machine, same scenario, before → after:

| Benchmark | Before | After | Gain |
|---|---:|---:|---:|
| `Movement.reachable` ×400 | 1946 ms | 1.6 ms | cache |
| `los_blocked` ×20 000 | 90 ms | 37 ms | 2.4× |
| `Grid.neighbors` ×40 000 | 86 ms | 24 ms | 3.6× |
| `AIPlanner.plan` ×5 | 365 ms | 45 ms | 8.1× |
| **Full AI turn, 18 units** | **178 ms** | **39 ms** | **4.6×** |
| **Full civilian turn, 8 NPCs** | **92 ms** | **21 ms** | **4.4×** |
| Fog of war, per frame | 4.06 ms | 0.005 ms | cache |

The two bolded rows are what a player feels as the freeze between turns; the fog row is
what capped the frame rate while simply moving the mouse.

---

### 27.8 Scaling to 100 v 100 (#102) — what changed and what did not

#101 tuned constants. #102 attacked **growth**: work that was fine at 18 soldiers and
quadratic at 200. The proof obligation is unchanged and was met the same way — the golden
trace of §27.1 came back byte-identical (2136 lines, `digest=998142762 steps=1103`) after
every individual change, and three purpose-built harnesses (fog equivalence against a
brute-force recomputation, airlock behaviour, and a full 200-unit 13-round match) each
passed with a **negative control**: the guarded code was deliberately broken first, the
test was confirmed to fail, and only then reverted.

Four growth terms were removed. Each is described below with the invariant that makes it
safe, because in every case a plausible-looking simplification would break the game.

### 27.9 Two version counters for vision, and a change log

`GridCell` now carries **`vision_version`** alongside `walk_version`. The split rests on
one fact: **`_vision_blocked()` reads only `cover_height >= WALL_HEIGHT` and
`vehicle_id != -1`. Living units do not block sight.** So a soldier's step cannot change
what any *other* soldier sees — yet it bumps `walk_version` on every move, and the fog
cache hung off `walk_version` was therefore thrown away after every single action. At 200
soldiers that is roughly 60 000 Bresenham rays per action.

Three rules make the separate counter correct:

1. **Only two fields move it**, `cover_height` and `vehicle_id` — exactly the two the ray
   reads.
2. **Only on a threshold crossing.** A trench dug or sandbags dropped change the height
   but not the answer to "is this a wall", and a vehicle changing id without passing
   through `-1` does not change "is there a hull here". Bumping on those would discard the
   army's whole sight picture for a change the cache cannot observe.
3. **Every bump appends the changed cell's `(x, y)` to `GridCell.vision_changes`.**

The log is what allows *targeted* invalidation. A cached entry answers "what is visible
from `(x, y)` within radius `r`", and a Bresenham ray from the centre of that window to
any cell inside it **never leaves the window**. Therefore a change at `(cx, cy)` can only
invalidate entries whose window covers it: `|cx − x| ≤ r and |cy − y| ≤ r`. Everything
else survives. Without this, one demolished pillbox in a corner cost a full ~40 ms
recompute of the entire army's sight.

Two cases make targeted invalidation impossible, and both are handled by dropping the
cache wholesale: a **new grid** (`Grid._init` calls `reset_vision_log()`), and a holder
whose version predates `vision_log_base`, which happens when the log overflows
`VISION_LOG_CAP` — a whole city block collapsing at once is cheaper to recompute than to
diff.

**The team fog is now maintained by reference counting, and this part is subtle.**
`team_visible_coords` keeps, per side, a count of how many living soldiers see each cell
and — critically — **`_vis_seen`, the actual `PackedInt32Array` each soldier last
contributed**. It stores the *contribution*, not the soldier's position. The tempting
version (store positions, and on invalidation recompute "what he saw from his old cell")
is wrong: after a wall falls, recomputing from the old position yields a *different* set
than the one that was added, the counters never balance again, and the fog silently rots
for the rest of the match. Storing the contribution makes removal exactly inverse to
addition, by construction.

The payoff on an ordinary turn: 99 soldiers of 100 have not moved, their fresh sight set
is the same packed array, and the whole update for them is one comparison each.

### 27.10 `feature_version` and the airlock index

`update_airlocks()` runs after **every** action (#100) and swept all 2400 cells looking
for airlocks — usually finding none. The list is now built once and held behind a third
counter, **`GridCell.feature_version`**, bumped only when a `feature_id` actually changes.
It is a separate counter for the same reason as `vision_version`: hanging it off
`walk_version` would rebuild the index after every step. 50.1 ms → 0.4 ms over 157 actions.

### 27.11 The firing-line prefilter

`Combat.is_on_firing_line(a, b)` — same row, same column, or exact diagonal — is
**symmetric**, and it is a **necessary condition on every success path of `can_shoot()`**:
it is checked before the marksman and flamethrower exemptions, not after. That single fact
licenses two changes:

- `shootable_target_ids` / `hostile_target_ids` reject a candidate by subtracting two
  vectors instead of entering `can_shoot()` with its fog, trench and ray-tracing work.
  Nine of ten candidates fall out. `hostile_target_ids` additionally drops friendlies
  *before* the check rather than filtering the finished list — half the army was being
  fully evaluated only to be discarded. 175.9 ms → 2.8 ms over 30 calls.
- `AIPlanner` builds **`_line_targets`**, a `Vector2i → Array[UnitInstance]` map of which
  enemies stand on a firing line with each cell, by marching eight rays out of each enemy.
  `_score_cell` then scores a cell against that handful instead of against all 100 enemies.
  This was the single worst growth term in the game: 290 000 `_fire_ease` calls per plan,
  100 ms of a 122 ms plan.

**Two constraints on `_line_targets` that must not be relaxed:**

1. **The build loop must iterate `_enemies` outermost.** That is what makes each cell's
   list follow `_enemies` order, which makes `score += W_FIRE + ease * W_FIRE_EASE + …`
   accumulate in the original order. Float addition is not associative; a one-ulp
   difference flips a comparison in `rows.sort_custom` and the whole army deploys
   differently (§27.2). Building the map by iterating cells outermost would be faster and
   wrong.
2. **The rays stop at the map edge, not at a wall or at maximum range.** Range belongs to
   the *shooter*, who is not known while marching from a target, and the marksman's laser
   has no range at all. A wall cannot cut the ray either, because `los_blocked` grants an
   embrasure exemption measured from the **shooter's** end — the relation is not symmetric
   there, so the prefilter must stay permissive and let `_fire_ease` make the real call.

### 27.12 Snapshots only where undo exists

`Main._on_intent_ready` took a full `state.snapshot()` — every unit and every cell, ~3 ms
at 200 soldiers — before *every* action, then discarded it unless the acting side was
player-controlled (#94). The snapshot is now taken under that same condition, so an enemy
turn of 150 actions no longer spends half a second copying boards nobody can ever undo.

### 27.13 Measured result at 100 v 100

60×40 map, 200 soldiers, same machine:

| Benchmark | Before | After | Gain |
|---|---:|---:|---:|
| `AIPlanner.plan` ×1 | 124.5 ms | 36.9 ms | 3.4× |
| └ candidate scoring | 105 ms | 14.4 ms | 7.3× |
| Fog, 60 frames with a move each | 1040.4 ms | 40.5 ms | 25.7× |
| Fog, 60 frames idle | 2.6 ms | 0.0 ms | cache |
| `update_airlocks` ×157 | 50.1 ms | 0.4 ms | 125× |
| `hostile_target_ids` ×30 | 175.9 ms | 2.8 ms | 63× |
| Full AI turn, 157 actions | 435 ms | 260.3 ms | 1.7× |
| **AI turn as the game runs it** | **3877.2 ms** | **312.0 ms** | **12.4×** |

The bolded row is the freeze a player actually sits through between turns. A cold fog
rebuild still costs ~41 ms, but targeted invalidation reduced it from a per-action event
to a once-per-battle one.

### 27.14 Scaling to *hundreds* of everything (#106) — the harness

#101 and #102 tuned a 34×26 board and then a 200-soldier one. #106 targets the case the
game actually gets slow in: **a full 60×40 map carrying 360 units, 300 corpse piles,
30 airlocks, 90 sandbag tiles, 24 trench runs and 680 cover tiles at once**, played for
six full rounds — 3167 resolved actions.

The gate is the same as §27.1 and it is not negotiable. The harness prints two hashes: a
digest of the whole board and every unit's state at the end (`hash`, `len`), and a hash
of the ordered action trace (`trace`). Every change below was accepted only after all
three came back identical to `actions=3167 hash=471189801 len=14342`,
`trace=3548959458`, `alive p1=36 p2=37 civ=0`. Several plausible optimizations were
written, measured, and thrown away because they were slower; none was ever kept on the
strength of an argument that it "should" be equivalent.

### 27.15 `team_sees` — the single largest win of the pass

`can_shoot` → `is_visible_to_team` → `team_sees` runs on **every shot**, and it was:

```gdscript
func team_sees(owner: int, coord: Vector2i) -> bool:
    return team_visible_coords(owner).has(coord)
```

By the time a shot is checked somebody has moved, so `UnitInstance.vision_epoch` has
changed and the incremental whole-team set from §27.9 has to be rebuilt — every visible
cell for every living soldier — in order to answer **one point query**. That cost ~10 ms
per shot and was 95% of all resolver time.

`team_sees` now answers the point query directly when the team set is stale: reject by
Chebyshev range against each living friendly's sight radius, then cast the sight ray. It
is exactly the same predicate — `_seen_from()` admits a cell iff it is inside the
Chebyshev-r window *and* the Bresenham ray is unblocked, `_vision_blocked` is the
identical arithmetic, and the team set is the union over living own units, i.e. "any one
soldier sees it". The cached set is still used verbatim when it happens to be fresh.

Resolve total went **10085 ms → 306 ms**; `ShootIntent` went **9567.7 ms → 53.7 ms**.

### 27.16 `update_airlocks` — a neighbourhood, not a sweep

Airlock state is recomputed after **every** resolved action. It scanned every airlock
against every unit alive with `Combat.distance` — O(airlocks × units), which on this map
is 30 × 360 per action. It now reads the 3×3 neighbourhood of each airlock straight out
of the grid (`grid.cell_fast(x, y).occupant`), keeping the predicate exactly as it was
(`occ.is_alive() and not occ.is_drone`). Resolve total **21.0 s → 10.1 s**.

### 27.17 The AI's geodesic field: flat arrays, then `GeoField`

`_enemy_distance_field` is a multi-source BFS over the whole board, and it is the AI's
main sense of "which way is the enemy". It is cached for as long as no enemy dies
(§27.5), but on a 6-round battle it still rebuilds ~200 times, and it was costing
**5.1 ms each — 25% of the entire run.**

Two changes, in order:

1. **The wave stopped using dictionaries.** It was paying three costs per step:
   `grid.neighbors()` allocated a fresh 8-element `Array[Vector2i]` for every one of
   ~2400 cells; "have we been here?" was a `Vector2i`-keyed dictionary probe; and a
   wall's passability was recomputed *from every neighbour that touched it*, up to eight
   times. Now cell state lives in a flat `PackedByteArray` (0 untouched / 1 taken into
   the wave / 2 impassable — a wall is marked once and thereafter rejected by a byte
   compare), the queue is three `PackedInt32Array`s, neighbours are walked straight over
   `Grid.N8`, and `walkable_terrain()` is inlined. **5.1 ms → 2.9 ms.**
2. **The result stopped being a `Dictionary`.** It is now `GeoField`
   (`src/controllers/GeoField.gd`): a flat `PackedInt32Array` indexed `y * w + x`, where
   "not reached" is the sentinel `FAR = 1 << 20` — the same value the old callers passed
   as `Dictionary.get`'s default. Building it does zero dictionary insertions; reading it
   is one array index instead of hashing a vector, which matters because move scoring
   asks the field about ~170 spill cells per decision, hundreds of thousands of times per
   battle. The API is `has(coord)` / `at(coord)`, and all ~19 call sites in
   `AIController` and `AIPlanner` were converted.

   `GeoField` keeps a small side dictionary for **out-of-bounds keys**. A soldier riding
   inside a vehicle is parked off the map (`coord = OFFBOARD`), and the old dictionary
   version still stored such a key with distance 0 while never seeding a wave from it.
   That is reproduced exactly rather than "cleaned up" — it is observable through
   `has()`.

The same treatment was applied to `_vehicle_distance_field`, which shares the cache.

### 27.18 `GridCell.burning` — a counter that can only over-count

`_fire_near` is asked about **every cell of every spill** when the AI picks a move, and
it was calling `grid.neighbors()` (another 8-element allocation) each time, on a map
where nothing is usually on fire at all.

`GridCell.on_fire` is now a counted property: a static `burning` total is incremented and
decremented in the setter, which no-ops when the value does not change. `_fire_near`
returns `false` immediately while `burning == 0`, and otherwise walks the 3×3 window
directly with no allocation.

The counter is deliberately allowed to **over**-count: a discarded grid that still had
burning cells leaves the total high, which merely forfeits the early-out. It can never
*under*-count, because every transition goes through the setter — and under-counting is
the only direction that could hide a fire from the AI.

### 27.19 Allocation and rescan discipline in the AI

- `_nearest_enemy` no longer materializes `_enemies_of()`'s ~200-element array per call.
  The "hostile, alive, not an NPC civilian" filter — three function calls per unit across
  360 units — runs **once per decision**, producing an object list plus a parallel
  `PackedInt32Array` of coordinates; the search itself is then a loop over packed ints
  with Chebyshev distance inlined. The answer is additionally memoized per decision,
  because `_candidates()` asks for the nearest enemy four times from the *same* cell of
  the *same* soldier. Iteration order and the strict `<` comparison are unchanged, so
  ties still go to the first enemy in `state.all_units()` order.
  Visibility is now tested only on a candidate that would actually become the new best;
  this is equivalent because an invisible unit never updated `best_d` under the old code
  either.
- `_refresh_geo_stamp` rescans all units and all vehicles to decide whether the geodesic
  caches are stale. That is now done **once per decision** (`_decide_gen`) instead of on
  each of the four-to-five field queries a decision makes. `_decide()` is read-only, so
  the second and later answers within one decision are required to match the first.
- `_best_move`'s inner loop keeps its running best in plain locals instead of building a
  `Dictionary` per candidate cell, and hoists `_seeks_cover()`, the difficulty check and
  the straight-line target out of the loop. Tie-breaking is preserved by keeping the
  comparison strict and the iteration order untouched.
- `reach.cost.keys()` was replaced by direct dictionary iteration in `AIController`,
  `AIPlanner` and `Main.gd`. `.keys()` copies the whole key array; iterating a
  `Dictionary` walks it in the same insertion order, which §27.2 requires.

### 27.20 Measured result at 360 units

60×40 map, 360 units, 300 corpse piles, 6 rounds, 3167 actions.

**Read the caveat before the numbers.** The host machine's clock rate roughly doubled
partway through this pass — the same unchanged code measured ~10.2 s before and ~5.15 s
after. So the raw first and last wall-clock figures (31.1 s and 3.90 s) are *not*
comparable, and the ~8× they suggest is about twice the truth. Every row below is
therefore a **back-to-back pair measured on one machine state**, and the summary row is
scaled by that same measured 1.98× factor rather than quoted naïvely.

| Benchmark | Before | After | Gain |
|---|---:|---:|---:|
| `resolve` total — airlock sweep | 21.0 s | 10.1 s | 2.1× |
| `resolve` total — fog point query | 10085 ms | 306 ms | 33× |
| └ `ShootIntent` | 9567.7 ms | 53.7 ms | 178× |
| `_enemy_distance_field` ×200 | 1025.3 ms | 573.7 ms | 1.8× |
| `Movement.reachable` ×36 | 22.9 ms | 16.2 ms | 1.4× |
| AI decide (per action) | 1.06 ms | 0.71 ms | 1.5× |
| AI pass total (one machine state) | 5.16 s | 3.90 s | 1.3× |
| **Whole 6-round battle, normalized** | **31.1 s** | **~7.7 s** | **~4×** |

The end state, on the final machine: turn planning 112.6 ms per turn, AI decide 0.71 ms
per action, resolve 0.10 ms per action. What remains in `decide` is essentially one
`Movement.reachable` spill per soldier per action, which is the irreducible part — the AI
cannot choose a destination without knowing where it can walk. The next real gain would
have to come from calling the spill *less often*, not from making it cheaper; the spill
itself is now within ~1.4× of where a bucket queue could take it, and §27.2 forbids the
bucket queue.

### 27.21 Colossal maps (250×250) — the whole map is never walked per action

The Colossal preset and unlimited custom sizes made one pattern the dominant cost: code
that touched every cell of the board — 62 500 on 250×250 — once per action, per frame or
per AI decision, often in places where a 50×38 map made it invisible. The rule now is that
nothing walks the whole map after the first time; it is patched from a log.

- **Two cell logs.** Besides the vision log (§27.9), `GridCell` keeps a *look* log — every
  change of floor, height, fire, space, object, dirt or welding, as `(x, y)` pairs behind
  `look_version` / `look_log_base` — and a `corpse_version` counter. Holders remember the
  version they read up to and patch just those cells; a holder that fell behind the start
  of a log (it holds 2048 changes) rebuilds once.
- **One object index for everyone.** `GameActionResolver._feature_cells_of(grid, fid)` —
  static, because the AI builds a fresh resolver for every decision — lists the cells of
  every object in board order, and also the burning cells. It serves the known mines of
  every movement spill (`known_mine_cells` scanned the board per call: ~16 ms), trenches,
  drone stations, the airlock list and fire spread, which now visits burning cells only,
  in the same order, so the dice fall the same.
- **Airlocks — candidates, not a sweep.** `update_airlocks` runs twice per move. Only an
  airlock that was open after the last pass, stands next to a living soldier, or crossed
  the wall threshold behind the pass's back (the vision log: undo, blasts, welding) can
  change state; those are processed in list order, so civilians wake in the same order.
- **Undo journal** (§18.2), **fog precision** (§11), **far-plan textures** (§18.4).
- **The AI's distance field** walks `AIController._walk_mask` — a byte per cell of
  `walkable_terrain()`, framed by a border of walls so no bounds checks are needed, shared
  by every AI and patched from the look log — with neighbours as fixed index offsets:
  ~140 ms → ~55 ms per field.

`tests/run_incremental.gd` holds all of this to account: twin games (one incremental, one
reference) compared field by field after every action, the object and fire indexes and the
walk mask against a fresh scan, and the distance field against a plain BFS.

| 250×250 town, Hard vs Hard, 10 soldiers a side, 91 actions | Before | After |
|---|---:|---:|
| Whole run | 31.2 s | 1.5 s |
| Worst single action (the first: every cache cold) | 3.2 s | 0.18 s |
| Undo snapshot per player action | ~280 ms | ~0.2 ms + touched cells |
| Movement spill (`reachable_for`) | ~16 ms | ~0.5 ms |
| Viewer fog after an action (average) | ~45 ms | ~5 ms |
| AI decision (average) | ~48 ms | ~7 ms |
| Battle screen `_draw` at `ZOOM_MIN` | 149 ms | 0.2 ms |
| Purchase screen `_draw` | ~500 ms | 2–8 ms |

With a tank a side the same town runs 96 actions in 1.4 s and an open **Field** Colossal
98 in 2.0 s; the largest fog step left is one's own tank moving on open ground (~90 ms —
nine new viewpoints, each a real sweep), where it was ~430 ms.

### 27.22 The general performance pass (audit "MCF General Optimization Audit", 0.8.2)

An outside audit listed thirteen findings — repeated `.values()` copies, per-frame HUD and
clock work, linear group membership in `_draw`, renderer-side equipment checks, an O(n)
dice queue, AI temporaries and Callables, a per-particle RNG object, `digest_hash`
strings, and the missing harness of §27.1/§27.14. The pass followed the same gate as
#101–#106: nothing was kept on the strength of an argument; each change was measured and
the behaviour hashes had to come back identical.

**The harness (finding 13)** is `tests/bench/run_bench.gd`. Three MapGen scenes, Hard vs
Hard with fog, civilians and tanks — small (38×28, 12 a side, 6 rounds), medium (56×40, 50
a side, 3 rounds), large (80×60, 150 a side + 2 tanks, 2 rounds). The host plays through
`NetGame`; the guest receives the host's whole wire **after** the match (in a real game the
peers are separate processes, and a guest answering between host actions in the same
process would thrash the static caches that hold one grid — the object index and the
spill cache — and inflate both sides' timings); the final board then round-trips
`StateCodec` through JSON and replays from the start as a `ReplayPlayer`. The signature
— board digest, ordered action trace, survivors, cosmetic state, guest equality, resyncs,
save and replay equality — must match `tests/bench/expected.txt`; `run_all.sh` checks small
and medium. `-- render` opens the battle screen on the large board with the whole map in
view and 150 soldiers group-selected, times `_process`/`_draw`, and prices the individual
per-frame expressions on the live screen.

**Kept**

| Finding | Change | Measured |
|---|---|---|
| 1 | `all_units()` / `all_vehicles()` hand out one cached, read-only list, rebuilt lazily after `spawn_*`, `remove_unit/remove_vehicle` (the resolver's five direct `erase` calls now go through them) or `restore()`; a size check catches any edit that bypasses them. A mutating caller gets an error instead of corrupting the list; a list in hand is replaced, never edited, so loops that kill or spawn still walk a snapshot. | `values()` at 330 units: 8 µs a call, ~25 000 calls per large match |
| 3 | `_refresh_clocks` builds its strings only when the shown second or round changes. | 3.0 → 0.5 µs a frame; `_process` 19 → 12 µs |
| 5 | `_group_ids` keeps a companion set, rebuilt by its setter (it is only ever assigned, never edited in place). | group-ring check 280 → 75 µs a frame at 150 selected |
| 11 | `digest_hash` formats with `str(…)` instead of `"%d:…" % [...]`; every field is `int`, so the text — and the hash — is byte-identical. | 0.65 → 0.52 ms a call at 330 units (−20 %); called once per action on each peer |

Back-to-back, best of three, whole scene (host side / guest / replay, ms):

| Scene | Before | After |
|---|---|---|
| small | 745 / 379 / 350 | 781 / 386 / 368 |
| medium | 4494 / 1701 / 1554 | 4509 / 1755 / 1633 |
| large | 18414 / 5578 / 5029 | 18138 / 5232 / 4483 |

Whole-match totals move within noise — which is the finding of the pass: apart from the
digest, none of the audited paths was a hotspot.

**Measured and left alone**

- **2 — HUD grip:** 2 µs a frame. A cache key would need the viewport, the HUD width, the
  chat, log, menu, component panel and replay bar geometry — about what recomputing costs.
- **4 — vehicle sprite and name lookups:** 6 µs a frame for four vehicles.
- **6 — the "!" equipment check:** ~0.3 ms a frame with all 330 on screen, nearly all of it
  GDScript call overhead in `unit_missing_equipment` for the ~64 soldiers who can carry the
  mark. A per-unit cache needs an invalidation signal that does not exist — undo, resync,
  replay seek and the net layer change `held_item_id`, deaths and stations outside
  `resolve()` — and a stale mark would show on the wrong soldier. A per-type prefilter was
  tried and gained only ~0.05 ms; it was removed.
- **7 — `DiceService.pop_front()`:** the longest scripted queue in any scene was 8 rolls.
- **8, 12 — AI temporaries, `sort_custom`, Callables:** candidate dictionaries are a handful
  per decision; both sorts run once per turn; `GroupMovePlanner` serves only the player's
  cached group-move preview. The AI's time is the movement spill and target evaluation
  (§27.20), not representation.
- **9, 10 — `FxDecals`:** `apply()` totals 5–14 ms over a whole match. A fresh RNG costs
  0.4 µs more than a reused one, and sharing one is unsafe (`_blood` holds one while
  drawing another).

**Where the time actually is** (large scene, host side): the viewer's fog after each action
(`team_visible_coords`, ~6 ms at 330 units — 42 % of host time), the movement spill
(`Movement.reachable`, §27.2 forbids changing its order), the AI's per-turn plan and
`_best_shoot`. None was in the audit; they are the next pass.
