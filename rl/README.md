# RL Enemy AI — v1 (Phase A / Phase B, pure policy)

Implements the v1 tier of the RL spec (`13_reinforcement_learning_ai`, revision 2,
2026-09-14). The game already had almost every piece the spec needs (StateCodec,
IntentCodec, recorded dice, ReplayRecorder, per-side fog sets, the headless harness);
the new pieces are the legal-intent enumerator, the env server, and the trainer.

```
src/resolver/LegalIntents.gd      legal_intents(side): every intent the resolver will accept   (§4.1)
rl/ObsEncoder.gd                  fog-limited observation, candidate descriptions              (§3)
rl/env_server.gd                  headless Godot env, JSON lines over stdin/stdout             (§1, §5.1)
rl/mcf_env.py                     bridge + vectorised envs                                    (§9.1)
rl/features.py                    64x64x72 grid tensor, flat vector, per-candidate rows       (§3.1, Q2)
rl/model.py                       CNN + candidate scorer + value head                         (§4, §5.2, Q6)
rl/train.py                       PPO, checkpoints, resume/fork, TensorBoard, eval, replays   (§6, §8, §9, §10)
rl/dashboard.py                   rlm.mindcontrolfactor.com — stats, controls, spreadsheet    (§11)
rl/policy_server.py               serves a checkpoint to the running game                     (§7, 10.4)
src/controllers/LearnedController.gd  "AI - Learned" lobby slot; falls back to AI - Hard      (§7, §12)
rl/tools/make_pool.gd             exports the test arena as the first pool map                (§8.2.2)
rl/tools/make_town_map.py         maps/town.json + both armies -> rl/maps/town_50x50.json     (§8.2.2)
rl/tools/check_replay.gd          plays a recorded .mcfr through ReplayPlayer                 (10.3)
tests/run_legal_intents.gd        exactness: every enumerated intent resolves OK               (13.1)
tests/run_learned_controller.gd   fallback path (always) and live path (with MCF_RL_POLICY)
rl/test_rl.py                     `~/.venvs/mcf-rl/bin/python rl/test_rl.py` — head, storage, timeouts
```

## Setup (laptop = trainer + dashboard; the site is a tunnel to it)

```
bash rl/setup.sh [<tunnel-token>]   # uv + venv (CPU/MPS torch), Godot 4.7, rl/.env, cloudflared
```

No sudo and no Homebrew needed: uv goes to `~/.local/bin`, Godot to `~/Applications`
(macOS) or `~/.local/bin` (Linux), cloudflared to `~/.local/bin`. `rl/.env` (never
committed) holds `MCF_RLM_PASSWORD` (the dashboard login, generated once), `GODOT`, `VENV`
and `TUNNEL_TOKEN`. With a tunnel token, macOS gets a user LaunchAgent
(`com.mcf.rlm-tunnel`, starts at login) that makes **rlm.mindcontrolfactor.com** reach
this machine's `:8501` for as long as it is on; on Linux `run.sh up` starts the connector.
The tunnel (`mcf-rlm`) and its DNS record live in Cloudflare; `rl/tools/cf_tunnel.sh`
recreates them from an API token.

## Running

```
bash rl/run.sh up                                        # TensorBoard :6006 + dashboard :8501 (background)
bash rl/run.sh start rl/config/laptop.yaml phaseA-1      # or press Start on the dashboard
bash rl/run.sh start rl/config/town.yaml town-1          # the company-scale town set
bash rl/run.sh logs phaseA-1                             # tail the trainer log
bash rl/run.sh status
bash rl/run.sh down                                      # everything off; trainers checkpoint first
bash rl/run.sh pause phaseA-1                            # checkpoint and hold; the Godot envs stay up
bash rl/run.sh continue phaseA-1                         # back to training in a couple of seconds
bash rl/run.sh stop phaseA-1                             # checkpoint after this update, exit
bash rl/run.sh resume phaseA-1 [new-config.yaml]         # continue; new config = graduation
bash rl/run.sh restart phaseA-1 new-config.yaml          # stop → wait for checkpoint → resume
bash rl/run.sh fork phaseA-1/ckpt_000100000.pt experiment-1
python rl/train.py eval rl/runs/phaseA-1/latest.pt --games 20 --record /tmp/ev   # vs HARD
python rl/train.py play rl/runs/phaseA-1/latest.pt       # real game, checkpoint in the AI slot
python rl/train.py export rl/runs/phaseA-1/latest.pt policy.onnx
```

The dashboard (`rl/dashboard.py`, Streamlit, spec §11) is the one place for everything:
live curves (§11.2), an **Evaluations** page that breaks every test out per opponent and
per game (outcome mix, stall rate, value diff, drill-down to the individual games),
start/pause/continue/stop and config edits applied by stop→resume (§11.3),
the checkpoint spreadsheet with fork lineage and CSV export (§11.4), the Phase B graduation
button (§11.5), "play vs checkpoint" which opens the real game (§11.6), the replay gallery
with outstanding tags and "open in the game" (§11.7), per-map trends (§11.8). It shells out to
`rl/run.sh`, so anything it does you can also do from the terminal. TensorBoard stays on
**127.0.0.1:6006** as the raw view.

SIGTERM / SIGHUP / the `STOP` flag file all finish the current update, save a checkpoint,
and terminate every Godot process (they run in their own process group). The `PAUSE` flag
file (`run.sh pause`, or the dashboard button) is the softer one: the run checkpoints and
holds with its envs still up, so **Continue** is back to training in seconds instead of the
minute a stop→resume costs.

## Reading the panel

Colours come from the dataviz reference palette's dark steps on its own dark surface
(`#1a1a19`), taken unchanged because that exact pairing is the validated one; the theme
in `rl/.streamlit/config.toml` and the chart colours have to move together. Categorical
hues are assigned per entity in fixed order and never cycled, so filtering a series out
never repaints the rest. Status colours (good/warning/serious/critical) are reserved and
always ship with the word beside them — a colour never carries a state on its own.

**"What the policy is doing"** on the branch page is the chart to look at first. It is a
share-of-actions trend by intent kind, and it exists because of a real miss: `town-1` spent
five hours converging on `move_held` — 75% of its actions, `end` at 0.4%, two completed
matches — while every score curve merely looked flat. One band swallowing that plot means a
collapsed policy whatever the losses say, and the panel now says so in words.

## Staying alive: memory, disk, crashes

A branch is expected to run for weeks unattended, so nothing is allowed to grow without a
bound, and nothing is allowed to die without saying why.

**Memory.** A rollout step used to hold a dense `72×64×64` grid (590 KB) plus dense
candidate rows; at 512×6 steps that is gigabytes of mostly zeros, and on a company map it
is enough to get the trainer OOM-killed. `features.Sparse` keeps both tensors as
(index, value) pairs — under a tenth the size — and `collate()` rebuilds one dense
minibatch at a time. The frozen Phase B opponents are an LRU capped at `pool_size + 1`.
`mem_limit_mb` is the backstop: the trainer checkpoints and exits *before* the OOM killer
gets it, so there is a reason on the dashboard rather than a silent disappearance.
`rollout_budget_mb` cuts a rollout short instead of letting one expensive map blow the
budget. The heartbeat carries the trainer's RSS, its Godot children's, and what the
machine has left.

**Disk.** `keep_checkpoints` (4 MB apiece, a few hundred MB a day otherwise) keeps the
newest N — never fewer than the Phase B pool draws from — plus every `milestone_every`
step as a permanent lineage record; `keep_replay_sets` does the same for recorded games.
`run.sh` rotates `runs/<name>.log` past `LOG_MAX_MB` (64 by default).

**Crashes.** An exception inside `train()` writes `state: crashed` with the message and
traceback into `status.json`, after a final checkpoint; the dashboard prints both. A
process the kernel killed writes nothing, so the dashboard reads the *last heartbeat*
instead and says so, with the memory figures from that moment. Godot reads are bounded by
`MCF_RL_ENV_TIMEOUT` (900 s) — an env that stops replying is killed and rebuilt rather
than hanging the trainer forever — and `VecEnv.rebuild()` retries with backoff. A failed
evaluation no longer takes the run down with it.

## Speed

Measured on the VPS (2 vCPU) against the lockstep code, same config and seeds; a machine with
more cores loses more to lockstep.

- **Envs run at their own pace.** The rollout decides for whichever envs have replied (one
  batched forward on the CPU copy of the policy) and sends straight back while the others keep
  computing; evaluation starts an env's next game the moment it finishes one. Lockstep waited
  on the slowest env every step — an end-turn, where the scripted opponent plays, takes ~130 ms
  against ~16 ms for an own action. Rollout throughput: 27.5 → 39.7 steps/s at 2 envs, 23.2 →
  44.1 at 4. The rollout ends at `rollout_steps x n_envs` trainee steps in total.
- **The candidate head scores only real candidates** (a minibatch pads every state to its
  widest, ~4x the real count on the arena and far more on town maps) and computes the state
  embedding's share of its first layer once per state. Same weights, same function
  (`test_packed_head_is_the_same_function`), so old checkpoints load as they are. A 64-step
  arena minibatch: 3.6 s → 2.2 s on the VPS.
- **`device` is where the PPO update runs; rollouts always decide on the CPU** (a copy synced
  after each update). On a CPU the update's conv backward is ~60% of a minibatch. `device: auto`
  puts the update on the Mac's GPU after a startup self-check against the CPU, and falls back
  to `cpu` — with a log line — if it fails. Not set in any config yet: try it on one branch and
  compare `speed/update_secs`.
- **Threads:** rollout forwards get the cores the Godot envs leave free; the update gets all of
  them (`torch_threads` caps both).
- **Replies travel over a local socket, not stdout,** so the per-env Godot logs under
  `envlogs/` hold only Godot's own messages instead of every observation twice (~1.1 GB/hr at
  six envs); `trim_logs()` stays as the backstop.
- **Phase B credit:** rewards that arrive over a pool opponent's moves now go to the trainee
  decision that preceded them, not the one after.

## What is where

- `rl/runs/<branch>/ckpt_<step>.pt`, `latest.pt` — full resume state: weights, optimizer,
  config, phase, stage, map rotation, match counters, RNG, parent checkpoint (fork lineage).
  `ckpt_<step>.pt.json` — the same minus weights, what the dashboard's table reads.
- `rl/runs/<branch>/status.json` — heartbeat, written every update and every few seconds
  inside a rollout: state (`running` | `paused` | `stopped` | `crashed`), pid, step,
  activity and progress, the latest evaluation, memory (trainer / envs / free), disk, and
  on a crash the error and traceback.
- `rl/runs/<branch>/STOP`, `PAUSE` — flag files; `run.sh stop` / `pause` write them.
- `rl/runs/<branch>/tb/` — TensorBoard: `ppo/*`, `train/winrate_vs_ai`, `train/winrate_vs_pool`,
  `train/drawrate`, `train/match_rounds`, `train/value_diff_end`, `train/illegal_per_match`,
  `usage/unit_*`, `usage/kind_*`, `map/<map>_winrate`, `eval/winrate_hard`,
  `speed/*` (including `speed/env_legal_ms`), `mem/*`.
- `rl/runs/<branch>/replays/checkpoint_<step>/vs_hard_<k>_<result>.mcfr` — the sampled
  evaluation games; open them from the game's replay screen or check with
  `godot --headless --script res://rl/tools/check_replay.gd -- <file>`.
- `rl/runs/<branch>/eval_log.jsonl` — the clean win-rate series, one line per evaluation
  with `*_<opponent>` columns (win/loss/draw/stall rates, value diff, rounds, and the
  outcome counts), against HARD. Each recorded replay has a `.mcfr.json` sidecar (branch, step,
  opponent, result, value diff, rounds, map) for the gallery. A branch evaluates every
  `eval_every` updates **and** whenever this file is still empty, so the dashboard's win
  rates are never blank for long.
- `rl/runs/<branch>/eval_games.jsonl` — one line per evaluation **game**: result, value
  diff, rounds, steps, illegal count, seed, side, map. What the Evaluations page drills
  into; an aggregate hides whether a 0% win rate was honest losses or stalls.

## Only HARD

The scripted opponent is AIController **HARD**, always: in Phase A training, in the scripted
share of Phase B (`pool_ai_fraction`), and in every evaluation. The owner retired NORMAL and
EASY from the RL pipeline, so there is no setting that selects them — `opponent:` and
`eval_opponents:` are gone, and a branch whose saved config still has them simply loses them
on its next resume (its eval_log keeps any old `*_normal` columns as history; the dashboard
shows HARD only). The game itself keeps all three difficulties for human matches.

NORMAL was also measuring very nearly the same thing: six arena games came back identical to
their HARD counterparts step for step, because `AIController` separates the two in exactly one
line — a shot-scoring tiebreak, `score += ease` — while everything else keyed off difficulty is
EASY-only.

## Maps in the pool

| map | size | per side | notes |
| --- | --- | --- | --- |
| `arena_34x26.json` | 34×26 | 10 infantry | the smoke/reference map; ~465 candidates, 95 env steps/s |
| `town_50x50.json` | 50×50 | 176 | company scale; needs `max_actors` / `max_candidates` |

`town_50x50.json` is built from the shipped `maps/town.json` by
`python rl/tools/make_town_map.py` — same terrain and the same twelve civilians, with both
armies placed in the map's own deployment bands and mirrored across the horizontal axis, so
neither side gets the better half of the town. Per side: 1 tank, 1 borg, 1 shuttle, 50 light
infantry, 35 heavy infantry, 15 shield bearers, 20 machinegunners, 15 snipers, 10 anti-tank,
4 marksmen, 1 flamethrower, 10 engineers, 8 sappers, 5 drone operators. Light infantry hold
the front row, support and vehicles the back. `--scale` produces a smaller cut of the same
composition for a faster first signal. Deployment zones are stripped: the env server spawns
straight from `spawns`, and a neutral zone left in the file would materialise 144 extra
civilians on load.

## Decisions baked in (change = retrain)

- Canvas 64×64, maps larger than that are not admitted to the pool (Q2).
- `max_actors` / `max_candidates` (both 0 = off, and off on the arena). They live in
  `rl/IntentBudget.gd` because **both** sides of the wire must apply them identically: the
  env server caps the list before showing it to the policy, and `LearnedController` has to
  cap it the same way or a real game hands the network 8000 candidates where it learned on
  512. `train.py play` passes the checkpoint's own caps through as environment variables. Company-scale maps
  need them: on `town_50x50` the opening has 8366 legal intents and the enumerator alone
  costs ~148 ms of a ~195 ms step. `max_actors` draws a fresh random subset of the side's
  units each decision point (those with AP left first), so the enumerator only looks at a
  few — over a turn the policy still reaches everybody. `max_candidates` then trims what
  survives, round-robin over (actor, intent kind) buckets so every rare kind and every
  actor keeps a slot. Together: 5.1 → 14.7 env steps/s, and a rollout that fits in RAM.
- Round cap 10 per training episode; the cap is a draw with a small negative reward (Q4, owner's number).
- Stage 1: civilians off, random events off (Q5). Turn them on in the config for later stages.
- Action space: all 37 intent kinds minus Undo/Redo (C6), minus GroupMove (a client-side
  bundle of moves) and BuildWall (6-cell LDF chain; v1 skips it), shots only at hostiles,
  vehicle component aim left to the resolver. See the header of `LegalIntents.gd`.
- Action head: the policy scores the enumerated legal candidates (actor cell + target cell
  gathered from the CNN map) instead of sampling unit→kind→target in three steps. It is the
  same factorisation read off the map, and illegal actions are structurally impossible.
- Reward (§6.1): Δ(own army value − enemy army value) per response, normalised by half the
  starting total; +1/−1 terminal; −0.1 draw. Plus, added after `town-1`:
  - **Penalties are scale-free.** They are fractions of a typical kill (`TURNS_PER_KILL`,
    `STEPS_PER_KILL`), not constants. They used to be constants, and because the kill
    reward is normalised by army value while the penalties were not, a kill was worth
    8.74 end-turns on the arena and **0.41** on town — ending your turn cost more than
    killing someone gained. A scripted "always shoot" policy measured −0.00062 mean
    reward per shot: the policy was correctly learning that fighting loses.
  - **Explicit combat reward.** A kill pays the victim's cost (`R_KILL`), unconditionally
    and separately from the differential, so a trade that kills *and* loses still reads as
    good. Destroyed vehicles pay their buy cost. Small bonuses for taking a shot
    (`R_SHOT`) and for operating a vehicle (`R_VEHICLE`).
  - **Combo multiplier** (`R_COMBO`, capped at `COMBO_MAX`): several kills from one action
    are worth more than the sum — 2 kills ×1.5, 3 ×2.0. Computed on summed cost, so
    catching expensive targets pays. This is what a marksman's laser, an anti-tank blast,
    a drone detonation and a flamethrower are *for*.
  - The action bonuses are capped at `SHAPING_PER_TURN` and sit an order of magnitude
    below a kill. Rewarding an action rather than an outcome is exactly the shape that
    produced the `move_held` collapse; kills themselves are uncapped.

  Measured before → after on town, same harness: mean reward per shooting step
  −0.00062 → **+0.00104**, shooting steps that paid 68/302 → **138/302**.
- A unit may take at most `FREE_ACTIONS_PER_UNIT` (6) actions per turn that spend no AP;
  past that, those *kinds* stop being offered to that unit for the rest of the turn.
  Structural, not reward shaping: shuffling a prisoner or a corpse is a legal move, just not
  an unlimited one. "Free" is detected by AP not decreasing, so the rule needs no hardcoded
  list of kinds and survives changes to the game's rules.
- oneDNN is disabled on CPU (`rl/torch_compat.py`) — its conv kernel SIGFPEs on the VPS's
  EPYC. `MCF_RL_MKLDNN=1` re-enables it.

## Not in this pass

- In-game ONNX inference (§12, Tier 2). `train.py export` produces the model with both
  heads; `LearnedController` talks to `policy_server.py` for now, and the onnxruntime
  GDExtension build against 4.7 is still the gating item. A missing model falls back to
  AI - Hard with a combat-log message, as specified.
- Search, neutral RL. The dashboard (§11) is in; not in it: pausing a branch while you play
  it (§11.6 — the run keeps training), folding a live match back into training, the
  come-from-behind outstanding rule (needs a per-turn diff trace the eval doesn't record).
