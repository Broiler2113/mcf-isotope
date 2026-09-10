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

- **Player 1 always precedes Player 2.** That is fixed.
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

Corpses do **not** block movement pathing at the Dijkstra level but occupy the cell as
an obstacle for standing.

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
- Vehicle hulls block (#47).
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

### 7.2 Flamethrower (§3.8)

Projects a **6-cell** jet, igniting each floor cell with `shooter.owner` as
`fire_owner`. On hitting a wall or a shield, the remaining length **splashes**:
`left_count = ceil(remaining / 2.0)`, the rest goes right.

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

Escaping an **allied** captor is free and needs no roll (#37). Escaping an enemy costs
1 AP and requires a **4+**.

### 8.3 Drag

`DRAGGABLE_FEATURES = [sandbags, hedgehog, dirt_pile]`, plus corpses.

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

---

## 10. Fire (§3.8)

`advance_fire(owner)` spreads to the **4 orthogonal** neighbours of every burning cell:

- Flammable floor or wooden wall: ignites on **3+**
- Any other floor: **4+**
- **Blocked entirely** by space, **BRU** (#84), and both pillbox variants — `_fire_blocked`
  refuses to ignite those cells at all, so a BRU section neither burns nor lets fire past
- An occupant of an igniting cell **dies**, unless it's a shield bearer (#50)

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
| `_unit_sees(unit, coord)` | Chebyshev radius (`sight_range`, default 12) plus a ray cast. Walls and vehicle hulls block; **living units do not**. |
| `team_sees(owner, coord)` | Visibility is **shared across the whole team**. |
| `is_visible_to_team(owner, target)` | The targeting gate used by `can_shoot`. |
| `team_visible_coords(owner)` | The set the renderer uses to draw the fog overlay. |

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
cells are skipped, and the whole pass is off when `GameConfig.civilians_enabled` is
false. Authors mark the block once instead of placing residents one spawn at a time —
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

| Vehicle | Size | Durability | Crew | Speed | Facing | Cost |
|---|:---:|:---:|:---:|:---:|:---:|---:|
| Tank | 3×3 | 6 | 3 | 16 | yes | 300 |
| Space Shuttle | 2×2 | 2 | 4 | 30 | no | 120 |

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

### 16.3 Movement

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
| Tank | 4+ | **Additionally explodes**, radius 2 |
| Shuttle | 1–2 | Explodes, radius 1 |
| Shuttle | 3+ | Destroyed outright, **no wreck** |

### 16.6 Unwired shuttle data

`driver_move_ap = 2`, `passenger_defense_bonus = 1`, and
`collision_durability_threshold = 12` exist in `VehicleDB` but are **not yet read by
the resolver**. They are documented intent, not behaviour (§24).

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
  Networked matches are unaffected: both sides there are human by construction (§22.3).

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

- **Undo restores a deep snapshot** (`GameState.snapshot()`). Restoration mutates *the
  same* objects (units / vehicles / cells) so outside references — the selected unit in
  the HUD, for instance — stay valid. Unit references inside cells are re-linked by id.
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
tints it yellow and drops a **small yellow circle on each cell the group would actually
occupy** if ordered there — `_group_move_preview` runs the same greedy allocator as the
real order (`_best_group_cell`, nearest-to-destination, cheapest path on ties), reserving
cells as it goes so two units never preview onto the same tile. The preview redraws on
mouse motion, but only while the left button is up, so it cannot fight the selection box.

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
for. `_recenter_camera` ("Return to Map") picks `min(1.0, fit)` where `fit` is the scale at
which the whole board plus margins fits the viewport — so the button never returns the
player to the same blindness he pressed it from. `_ensure_visible(coord)` (§14.1) pans
without touching zoom: the scale is the player's choice.

### 18.5 Dice presentation

Rolls play one at a time in a SteamChrome-framed **Dice Roll** window showing the
accuracy or defence prompt with every buff and debuff itemised. `FAST_ROLL_SPEED = 2.0`
speeds up long bursts.

**Who presses the button.** `_owner_is_local_human(owner)` decides whether a defence roll
waits for a click or spins by itself. In a network match it is `owner == my_owner`, so
**the defender always rolls their own dice on their own screen** (#93) while the attacker
watches the die spin automatically. This is presentation only — the outcome is already
fixed (the client's rolls are scripted), so the button is a gesture, not a source of
randomness, and it cannot desync. The AI never waits for a click — but a **civilian's
shot does**, because the one being shot at is the player (§14.1).

**Event kinds.** `_dice_steps` splits an event into one-die-at-a-time steps: `attack`
(all hit dice, then all penetration dice), `opposed`, `check`, `grenade`. `walk` is the
odd one out — it rolls nothing. `_play_dice` intercepts it and hands it to `_play_walk`,
which steps the unit's **draw position** along the path one cell per `WALK_STEP_DELAY`
(#96). It is how an off-intent mover — today, a civilian — is seen crossing the board
instead of appearing at its destination.

### 18.6 HUD

A movable, resizable side panel (`HUD_START_SIZE = (330, 430)`) with a universal base
action menu shared by all units.

**Action menus are anchored to the top-left corner (#87)**, at `MENU_ANCHOR = (16, 16)`,
not floated above the unit — over the unit they covered the board and slid off-screen
when zoomed. Every menu is a `ScrollContainer`; `_cap_scroll_height` clamps it to
`viewport.y − MENU_ANCHOR.y − MENU_CHROME_H (70)`, so a long menu scrolls instead of
running off the bottom. Pointer input over a visible menu belongs to the menu and never
pans or zooms the camera (#8).

Corpses render in `CORPSE_COLOR = Color(0.8, 0.1, 0.1, 0.5)`; BRU sections render as
solid `BRU_COLOR = Color(0.05, 0.05, 0.07)` fills (#85).

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

  **The purchase screen draws the real map (#100).** Deployment used to happen over flat
  coloured squares, so the player picked positions blind and only discovered the walls,
  trenches and sandbags once the battle started. `Placement._draw` now runs the same
  terrain pass as the battle screen: floor / space / wall sprites through
  `Sprites.draw_texture_override_rect`, cover tinted by height, and each feature labelled
  with the battle screen's own tag (`ST`, `SB`, `hdg`, `tr`, `##`, `▢`, `BRU`, `††`, `AL`,
  `drt`, `MG`, `PBX`, `WD`, `hSB`, `PBX+`) plus a `"%.1fm"` height caption, including the
  BRU black-monolith special case (§18.6). Same tags, same colours, same heights — what
  you deploy onto is what you fight on.
- **Map Editor** — camera pan (WASD / middle-or-right-drag); single, **line, rectangle,
  and fill** tools; terrain brushes for floor, wall, glass, **wooden wall**, and
  the other features; and **deployment-zone painting** for P1 / P2 / Neutral / No Zone
  as a tinted overlay (stored per cell in `MapData.zone_owner`). Maps default to
  all-space and support large sizes.

  **The editor has a way back (#104).** It leaves by two doors: **"Play"** hands the map
  to `MapHandoff.pending` and opens the battle, and **"Main Menu"** (`_on_main_menu`)
  clears that slot and returns to `MainMenu.tscn`. The second door used to read **"To Demo
  Game"** and dropped the designer straight into a match on the built-in roster — the only
  exit from the editor led somewhere he had not come from, so returning to the menu meant
  starting a demo battle he did not want and quitting out of *that*. Clearing
  `MapHandoff.pending` on the way out matters: the slot belongs to "Play", and leaving a
  half-drawn map in it would silently impose it on the next match started from the menu.
- **Quit-to-menu** — a SteamChrome overlay (dim + framed panel + title bar +
  Cancel / Main Menu), never an OS dialog.

---

## 20. Maps & Data

`MapData` stores dimensions, per-cell floor type, cover height, space flag, feature id,
and `zone_owner`. Maps serialise to disk and load in Setup. New maps start as **all
space** — the designer paints floor in.

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

---

## 21. Texture Replacement & Theme

- **Textures (#55, #57):** any map or unit primitive may be replaced by a texture drop-in;
  the vector draw remains the fallback so the game is always playable with no art.
- **Theme:** `UiTheme` (autoload `Ui`) applies the "2003 Steam" gunmetal skin to the root
  window. In-game surfaces are framed by `SteamChrome` — panel body, dark-green title
  bar, accent pip. The dice roller, deployment screen, and quit popup all use it.
- **Main-menu background (item 35):** `Starfield` replaces the flat `ColorRect` with a
  gradient sky and three star layers drifting at 5 / 13 / 28 px per second — the *speed
  difference* is the whole parallax. Each layer is one 512-px tile tiled across the
  screen with only its position animated, so a frame costs three sprites no matter how
  many stars there are, and the layers are laid out from a fixed seed so the menu looks
  the same every launch. The bundled `logo.png` finally appears, beside the title.
- **Settings (item 24) is a disabled button.** The original settings screen was never
  supplied; a guessed port would look like settings without setting anything. The slot
  is held visibly rather than silently dropped.
- All UI strings are **English**; all code comments are **Russian**.

---

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

Fog is **presentation only** — `is_visible_to_team` gates targeting, but the resolver's
outcome does not depend on it, so a `fog_enabled` mismatch between peers cannot desync.

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

**Perspective, not allegiance, drives colour.** `_side_color(side)` — present in both
Placement and Main — paints **your** army blue and the enemy red **for both players**;
`_side_label` shows "Player A (host)" / "Player B" with "(you)" appended to your own. In
hotseat there is no perspective, so the fixed P1-blue / P2-red mapping stays.

In battle each player controls only their own units, the **defender rolls their own
dice** (§18.5), and group selection is disabled.

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

- **No automated victory conditions.** The match runs until the players stop.
- **Replays are not recorded in network play** — the host's dice log already occupies
  that channel (§20.1). Save a game instead.
- **AI does not** throw grenades, build, dig, pilot drones, or ram with vehicles. It
  *does* demolish obstacles in its path with a miner or engineer (#90).
- **Tank-cannon AI ignores the blast-shield rule.**
- **Shuttle `driver_move_ap`, `passenger_defense_bonus`, `collision_durability_threshold`**
  are data-only and unread (§16.6).
- **Mines are unimplemented.**
- **No commander aura** — the Commander is stats and 3 AP, nothing more.

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

DEFAULT_SIGHT_RANGE       = 12
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

FIRE_SPREAD_FLAMMABLE     = 3       # wood/grass ignites on 3+
FIRE_SPREAD_OTHER         = 4       # other floor on 4+
FIRE_SHOOT_PENALTY        = 1

DRONE_FLIGHT_RANGE        = 30      # tiles of flight bought by one action point
DRONE_LEASH               = 15      # and never further than this from its station (item 15)
DRONE_ARMOR               = 5
RSP_RANGE                 = 12
RSP_RATE_OF_FIRE          = 8

AIRLOCK_OPEN_RADIUS       = 1
ZEROG_SHOOTER_KNOCKBACK   = 1
ZEROG_TARGET_KNOCKBACK    = 2

BRU_WALL_LENGTH           = 6
BUILD_COST_DEFAULT        = 1       # wall / glass / BRU
BUILD_COST_SANDBAGS       = 1
BUILD_COST_HEDGEHOG       = 2
BUILD_COST_DOT            = 2
BREAK_COST                = 1

POTENTIAL_PER_DURABILITY  = 10      # the unified damage scale (§9.8)
DOT_DURABILITY            = 2       # both pillbox variants

enum Owner      { PLAYER_1 = 0, PLAYER_2 = 1, NEUTRAL = 2 }
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
