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
rl/features.py                    variable-size training grid, flat vector, per-candidate rows     (§3.1, Q2)
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

## Training toward stronger human play

`config/league.yaml` is the Mac development profile. Fork an existing checkpoint;
keep `config/tactical.yaml` as the previous experiment. This is a measured development
path, not evidence that the current model is superhuman. The live audit on 2026-10-09
still showed tactical-4 near 15M decisions, good results on the small fixed HARD test,
and no representative human-match rating. Training-step counts cannot establish strength.

The profile changes the learning problem in these ways:

- **Round clock:** `discount_unit: round`, `gamma: 0.97`, `lam: 0.95`. Actions within
  one round use discount and trace factors of 1. A learner transition crossing a round
  uses gamma and gamma*lambda once, including an entire frozen opponent response.
  Position/hazard potential rewards use the identical discount. A 200-unit turn no
  longer shrinks the strategic horizon simply because it needs more actions. Rollout
  boundaries still bootstrap from the value head; they are not terminal states.
- **Longer games and broader boards:** 40-round training, 60-round held-out tests,
  24,000-action safety cap, generated Giant boards up to 149x119 and armies of
  120–200 soldiers per side. Encoding expands in 16-tile
  buckets and PPO/inference group equal canvas sizes so padding cannot change a
  position's policy between training and serving. The network compresses boards
  above 96 to a 96×96 feature grid before its costly convolutions; candidate
  coordinates still address the correct position. Existing 64x64 checkpoints load.
- **Curriculum and league:** all five environments, small/medium/Giant armies,
  every tactical drill, 50% fog, 35% hazard games; 70% historical-policy opponents and
  30% HARD styles. Training losses against HARD increase that scenario's sampling
  weight, with a nonzero floor for practiced skills. Forks preserve up to three
  source checkpoints as permanent opponents in addition to the source baseline.
- **Human demonstrations:** authenticated dashboard uploads under Replays, validated
  through the real resolver and recorded dice. Online matches now record on the host,
  sharing the network dice stream. The importer constructs player-visible observations
  before each action, including each side's last-seen memory, and matches demonstrated
  actions against the legal enumerator. Unsupported actions are counted/skipped; any
  replay/dice divergence rejects the whole import. No future dice enter model inputs.
  Imitation uses a small separate cross-entropy loss (`demonstration_coef: 0.02`),
  rather than pretending historical human moves are on-policy PPO samples.
- **Model selection:** `best.pt` starts as the preserved parent. Every 1,000 updates,
  the challenger plays 160 games against it: fresh map seeds, mirrored starting sides,
  five environments, including Giant armies, fog on/off, and hazards on/off. A one-sided
  Hoeffding lower bound on the mean paired score must exceed 50%, with no illegal
  actions and at most 5% action-cap stalls. Alpha spending across attempts limits
  repeated-test false promotions; the counter/seed allocation survives restart.
  The bound is conservative and may need more games to detect modest improvements.
  These are tests against a model, not a human skill certificate. Per-game records,
  seeds, results and reasons are saved under `eval_promotion_games.jsonl`,
  `promotion_log.jsonl`, and `promotion.json`.
- **Compute and memory:** two PPO epochs, smaller minibatches on the Mac, fewer
  frequent fixed-map evaluations, sparse replay shards with a one-shard memory cache,
  and one importer worker at a time. Existing resource monitoring, checkpoint
  retention, and supervisor recycling stay in effect. `config/league_gpu.yaml`
  provides an optional CUDA/8-worker profile; benchmark the actual remote machine
  before choosing its worker count. No remote machine is provisioned by these scripts.
- **Vehicle defense:** visible enemy tanks now produce a drive-lane danger layer for
  the policy, movement candidates, and position reward. Anti-tank soldiers near a
  visible vehicle are offered before idle infantry. On armies of at least 64 soldiers,
  End Turn stays unavailable while more than half their on-board AP remains and a
  move or attack is legal. A clean track shot at a visible tank receives a small
  priority; shots with friendly infantry near the blast receive no such priority.
  These safeguards also apply when serving older checkpoints;
  they reduce premature passes, while the new weights still need training to learn
  good counterattacks and spacing.
- **Positioning on Giant boards:** candidate moves expose progress toward visible
  enemies (or the map center before contact) and local friendly crowding. A small
  fixed movement prior favors closing distance and leaving dense clumps, and a
  stronger fixed penalty avoids entering a visible tank lane. The policy can override
  these priors through its learned scores; they are used identically in PPO and play.
  Generated Huge/Giant scenarios requesting tanks now always place at least one per
  side, so armor defense is practiced instead of disappearing in a random zero roll.

Changing the discount clock changes the value target. On such a fork/load, policy
weights are preserved but the value head and optimizer are reset deliberately. The
first updates must relearn value calibration. Resuming that new run does not reset
them again. The baseline file retains the complete original model for comparisons.

The following upgrades the Mac checkout, preserves a checkpoint, stops the old branch,
preflights the new maps, forks training, and starts the supervisor/dashboard:

```bash
cd /Users/28azverev/mcf-isotope
git fetch origin
git show origin/main:rl/tools/deploy_rlm.sh > /tmp/isotope-rlm-learning-update.sh
if [ -f rl/runs/tactical-5/latest.pt ]; then
  bash /tmp/isotope-rlm-learning-update.sh tactical-5 tactical-6 rl/config/league.yaml
else
  bash /tmp/isotope-rlm-learning-update.sh tactical-4 tactical-5 rl/config/league.yaml
fi
```

Use the actual source branch if it has changed. The script refuses to overwrite an
existing destination or tracked local edits. It prints success only after learning
advances beyond the preserved checkpoint. A GitHub release tag is not required: the
trainer and Play launch from source. Both online players need updated game code to
use the network recording changes consistently.

For a checkout already at this code revision:

```bash
bash rl/run.sh fork tactical-4/latest.pt tactical-5 rl/config/league.yaml
bash rl/run.sh supervise tactical-5
```

Run one main trainer on the Mac. The second example does not stop an existing trainer;
use the upgrade script or stop it first. **Play vs latest** remains the experimental
checkpoint. **Play vs selected model** uses `best.pt`, initially the original baseline
and subsequently only models that passed selection.

### Human replay data

Use **Replays → Teach RLM from human games → Validate and add replays**, or:

```bash
~/.venvs/mcf-rl/bin/python rl/demonstrations.py import /path/to/match.mcfr --dataset rl/demonstrations
```

Use good players' varied matches; a winner's every action is not necessarily good.
Completed and partial human games can supply action labels. There is intentionally
no outcome-based value label for an abandoned match. AI training replays are rejected.
The content hash deduplicates uploads and assigns entire matches to train (90%) or
holdout (10%); a one-match upload may consequently be held out. Only training matches
enter optimizer updates; full evaluations report held-out action agreement and loss.
Long matches are sampled throughout both players' decisions, while every replay
action is still validated. Each import caps intermediate data at 128 MB and requires
at least 1.5 GB of free space. Imports are atomic, size/time bounded, and serialized across
browser sessions. Sparse shards use NumPy with `allow_pickle=False`. Corrupt or
incompatible replays remain outside the training set with an explicit rejection reason.
Manifests preserve the importing code revision and feature dimensions; after game-rule
changes, revalidate original replays before reusing a historical dataset.

### How to judge whether the rebuild helps

Compare the preserved policy and new fork on the same paired scenarios, and track
results per environment, army size, fog and hazard setting. Distinguish annihilation
wins from material advantages at the round cap. Track illegal intents, stalled games,
unit participation, and hazard exposure alongside win rate. The frequent fixed HARD
chart remains a historical diagnostic; it no longer chooses the new profile's best model.

`rl/benchmark.py` compares throughput and PPO stability from identical checkpoints:

```bash
~/.venvs/mcf-rl/bin/python rl/benchmark.py rl/config/league.yaml \
  --checkpoint rl/runs/tactical-5/latest.pt --updates 5 \
  --variant '{"n_envs":2}' --variant '{"n_envs":4}' \
  --output /tmp/rlm-throughput.json
```

A standalone comparison can run on the Mac or a remote worker without changing either
checkpoint or promoting anything:

```bash
~/.venvs/mcf-rl/bin/python rl/train.py compare \
  rl/runs/tactical-5/latest.pt rl/runs/tactical-5/best.pt \
  --config rl/config/league.yaml --games 160 --seed 510001234 \
  --output /tmp/rlm-comparison.json
```

Use fresh seeds for subsequent development comparisons. The same seed is useful for
reproducing a report, not a new independent test. Avoid competing with the main Mac
trainer for CPU/memory when running a long comparison.

Throughput tests do not measure playing strength. Promotion tests likewise do not
replace a human evaluation: collect a varied human opponent pool and at least a few
hundred side-balanced matches across intended game settings before making a claim
about reliably beating people. Hold out players/matches when measuring imitation;
action agreement alone is not a win-rate estimate.

The playing controller remains a policy with tactical features and enemy memory.
Spending the allowed minute per turn on search is a separate strength experiment:
first calibrate the longer-horizon value head, then compare a bounded planner against
this policy on the same tests. Fog requires beliefs about hidden positions, and dice
must be sampled independently of the real match RNG. Enabling an unvalidated planner
by default would not establish a faster route to strong play. A recurrent/belief model
and hierarchical whole-army planning remain possible research upgrades if measured
failures justify their extra training cost.

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
python rl/train.py play rl/runs/phaseA-1/latest.pt       # real game: opens the lobby with this checkpoint as the AI - Learned opponent
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

The resource monitor checks every ten seconds, including during collection and
evaluation. With less than 1024 MiB of available RAM, or more than 1024 MiB of GPU
cache/framework allocations, it runs garbage collection and releases unused Metal
allocator memory. Models, Adam state and opponents serving ongoing games stay intact.
`mem/gpu_live_mb`, `mem/gpu_driver_mb` and `mem/gpu_cache_mb` expose allocations that
ordinary process RSS does not capture; these figures overlap and must not be added.
If available RAM stays below 1024 MiB and the trainer plus environments exceed
`mem_limit_mb` after cleanup, the same checkpointed recycle releases their memory too.

Some Metal framework/compiled-graph allocations survive `empty_cache()`. If the driver
still holds 6144 MiB, the trainer schedules a process recycle: it finishes an active PPO
epoch, saves the model/optimizer/counters/RNG checkpoint, and exits with reason `memory`.
The supervisor resumes that same branch after ten seconds, with increasing backoff for
repeated resource failures. Unapplied rollouts or an evaluation may be interrupted;
training resumes from the last completed update. No manual model restart is needed.
`memory_cleanup_free_mb`, `gpu_cache_max_mb` and `gpu_memory_restart_mb` set these limits.

Disk space is a separate limit. At 1024 MiB free, diagnostic logs are trimmed to their
last 64 KiB; ordinary maintenance caps each at 64 MiB. Only known RLM/Godot/tunnel logs
are eligible. Checkpoints, evaluation histories, replays and unrelated Mac files are
preserved. Sparse holes are excluded from reclaimed-space measurements, and active
appenders keep their file handles. If the volume remains below `disk_floor_mb` because
other applications consumed it, training still checkpoints and stops safely. This
cannot reclaim 15 GiB of disk from an RLM directory containing only hundreds of MiB.
macOS manages swap files; releasing memory reduces pressure without deleting OS files.

To install a resource-only update while retaining the same training branch and config,
run on the training Mac from its checkout:

```bash
git fetch origin main
git show origin/main:rl/tools/deploy_rlm.sh > /tmp/isotope-deploy-rlm.sh
bash /tmp/isotope-deploy-rlm.sh tactical-3 --resume
```

The helper preserves a backup, stops the old supervisor, resumes the checkpoint with
the new runtime, starts the updated supervisor and verifies training advances.

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
  activity and progress, completed training win/loss/draw counts, the current evaluation's
  partial counts, the latest completed main evaluation, memory (trainer / envs / free),
  disk, and on a crash the error and traceback. Training outcome counts start at zero on
  a new fork or when an older checkpoint is first resumed; older match results cannot be
  recovered from a total match count.
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
  `eval_every` updates **and** whenever this file is still empty. The dashboard shows each
  evaluation game's partial win/loss/draw count while the suite runs, then the main HARD
  result as soon as those games finish; the full suite can take much longer on Giant maps.
  It can derive partial counts from `eval_games.jsonl` even for a trainer that started
  before live tally support was added, so refreshing only the dashboard does not disturb
  an evaluation already in progress.
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

Since the tactical env (2026-10-02, owner's decision) the TRAINING side may also face HARD in
four play styles (`opponent_styles`: standard / rush / turtle / flank — `AIController.Style`)
and its own past checkpoints (phase `league`). Evaluation is unchanged: standard HARD only.

## Tactical environment (`config/tactical.yaml`)

The environment that teaches play rather than a win rate against one bot. Fork the best run
onto it — `python rl/train.py fork rl/runs/<branch>/latest.pt --branch tactical-1 --config
rl/config/tactical.yaml`; new inputs start with zero weights, preserving the parent's
logits. Live play and evaluation use the stopping rule described below.

| piece | where | what it does |
| --- | --- | --- |
| fire map | `GameActionResolver.fire_cover` | expected hits per cell from visible enemies (and from our own fire); 8 firing lines, walls stop them, same hit ladder as `can_shoot` |
| new inputs | `ObsEncoder`, `features.py` | 2 grid layers (threat, own fire) + 5 candidate columns (threat / own fire / cover at the target, AP cost, multi-AP flag) |
| deeper net | `model.py` | dilated residual trunk (2/4/8/16), receptive field ~67 cells; starts as identity |
| long moves | `LegalIntents` | moves into the orange zone (2 AP) in one order; far cells thinned to a 2×2 lattice plus cover and wall-side cells |
| smart cap | `IntentBudget._tactical_order` | each unit's kept moves: best by cover / out of fire / approach, interleaved with random ones |
| rewards | `env_server` | per-action bonuses decay to 0 (`shaping_decay_*`); potential-based position term (`potential_coef`): our fire on visible enemies minus theirs on us |
| maps | `maps/drill_*.json`, `gen:` | six skill drills (`tools/make_drills.gd`), fresh MapGen maps every episode with mirrored random armies (`ArmyBuilder.gd`), type shuffles on fixed maps (`army_shuffle`) |
| fog mix | `train.py` (`fog_off_share`) | fog of war in only 30% of training games; fog-off eval (`eval_nofog_games`); every drill played in fog and without |
| enemy forecast | `GameActionResolver.enemy_forecast`, `EnemyMemory.gd` | 3 grid layers + 2 candidate columns: where visible enemies can walk and shoot NEXT turn, and where hidden ones were last seen; the position reward counts next-turn fire at half weight |
| opponents | `train.py` | phase `league`: HARD styles + past checkpoints, prioritised toward those that beat it (PFSP) |
| measuring | dashboard **Tactics** page | drill win rates vs HARD, per unit type: action share, hit rate, kills, losses; exposure at end of turn; 2-3 AP moves |

A generated map is written `gen:<style|any>:<size index>:<units>:<tanks>` in `maps:`; units and tanks may be ranges (`60-200`), drawn per episode. The map must fit the configured `canvas_size`, including its border. `tactical.yaml` retains its old small canvas; `league.yaml` uses 160 so Giant maps keep their full 125×95 playable core and 12-cell border. No tiles are cropped from an observation.
Cost: an env step on the company-scale town map is ~1.5× the pre-tactical one (threat maps,
the larger move list, the ordering) — fewer samples per hour, each one far more informative.

## Training reliability and measurement

Live play and evaluation first choose **stop or continue** by the policy's combined
probability, then take the highest-scoring action in the chosen branch. Ending a turn
requires at least 50% stopping probability, or no other legal action. Flat argmax used
to pass at under 2% stopping probability when hundreds of individually similar moves
split the remaining mass. PPO and league opponents still sample the original policy;
its training likelihoods are unchanged. Evaluation games record
`decoding: stop_continue_mass_v1`; compare results across decoding versions cautiously.
Reserved vehicles/drones/borg pilots no longer consume infantry sampling seats.

The tactical preset enables artillery/gas in 35% of training episodes
(`random_events`, `random_event_share`). Every six player handoffs, normal game dice
give a 2/3 chance of an announcement, followed by the game's full warning period.
Independent armies stay disabled in the two-player training environment. Public
artillery warnings, pending gas and active gas are separate grid channels and six
actor/destination candidate inputs, visible under fog just like the game's warnings.
The move cap retains safe escape destinations alongside random alternatives.

`hazard_coef` rewards reducing own army value at risk, using
`hazard_coef * (gamma * Phi(next) - Phi(now))` once per learner transition, including
opponent replies. Phi is negative expected loss in public danger zones; terminal Phi
is zero. Leaving danger pays and re-entry costs. This avoids a repeatable per-move
escape bonus. Sealed vehicles/crew ignore gas, and artillery risk checks the whole
vehicle footprint. This is training credit; older checkpoints need further training
to use the new hazard inputs.

The main HARD evaluation keeps events off (`eval_random_events: false`). A separate
six-game fixed-seed event suite runs at full evaluations (`event_eval_games`), saved
in `eval_events_games.jsonl`. The Tactics page shows event win rate and end-turn
danger exposure. New event settings require the updated config: fork with
`bash /tmp/isotope-deploy-rlm.sh tactical-3 tactical-4` to retain tactical-3 as a
baseline, or resume with an explicitly edited branch config.

On the machine that runs training, deploy a published update from inside its checkout:

```bash
git fetch origin main
git show origin/main:rl/tools/deploy_rlm.sh > /tmp/isotope-deploy-rlm.sh
bash /tmp/isotope-deploy-rlm.sh tactical-2 tactical-3
```

The helper checks for local conflicts, gracefully checkpoints and stops the old run,
preserves a separate checkpoint backup, fast-forwards the checkout, checks every map,
forks into the new branch, verifies that training advances, starts its supervisor and
restarts the dashboard. It keeps the source branch and checkpoints. If a check fails,
it stops with the reason; it does not delete training data or force a Git reset.

Each stored transition runs from one learner decision to the next, including all
intervening pool-opponent actions. Collection drains those responses before PPO, even
when the rollout memory limit is reached. The value bootstrap always comes from the
next learner state. Position shaping uses `potential_coef * (gamma * Phi(next) - Phi(now))`
at that same boundary, with zero potential at terminal states. A frozen self opponent is
copied once per rollout. The new component identity, component health/presence, vehicle
crew and AP inputs are appended; loading an older checkpoint zero-initializes their
weights and expands Adam state, retaining its original outputs on identical inputs.

Run the compatibility check before a migration (it also runs automatically at startup):

```bash
python rl/train.py preflight rl/config/tactical.yaml
python rl/test_rl.py
python rl/test_training_fixes.py
python rl/test_army_events.py
```

Preflight resets every configured map and every generated style at the upper configured
army size, then encodes its opening. It checks actual game rules, candidate generation
and policy dimensions together. Training writes the checked dimensions to `preflight.json`.
This sampling does not prove every possible procedural seed will succeed.

The tactical preset checks the main benchmark every 25 updates and runs the additional
fog, drill and held-out suites every 100 updates, plus the first evaluation of a branch.
`eval_seed` stays fixed across checkpoints; each map/seed is played from both sides.
Held-out generated scenarios use separate seeds and a 40-round cap. Main game rows stay
in `eval_games.jsonl`; other suites have `eval_<suite>_games.jsonl`, so dashboard main
win rates remain comparable. `eval/rout_winrate_hard` separates annihilation wins from
`eval/value_winrate_hard`. Longer games still have the configured `max_steps` limit.

The league retains recent checkpoints, a spread of older milestones and the best
measured main-benchmark policy. Champion selection requires at least ten games and
uses win rate, then value difference; a small fixed benchmark can overfit, so inspect
the separate held-out results. Milestones keep the first saved checkpoint in each
crossed step interval; saving at an exact multiple is unnecessary.

`speed/*` records collection, update, evaluation, encoding, inference, socket wait,
receive/JSON, legal-enumeration and observation costs. Wait time overlaps work in other
environment processes; these values are diagnostics, not additive CPU timings.
`actions/<map>/<kind>_{offered,chosen,accepted}` distinguishes candidate availability,
policy selection and resolver acceptance. Accepted attacks need not hit: use the
existing per-map hit-rate and tactical counters for combat effectiveness.

Compare performance settings in isolated temporary runs:

```bash
python rl/benchmark.py rl/config/tactical.yaml --checkpoint rl/runs/<branch>/latest.pt \
  --variant '{"epochs":2,"lr":0.00004}' \
  --variant '{"epochs":3,"lr":0.00004}' --output /tmp/rl-benchmark.json
```

Variants accept config overrides such as `torch_threads`, `minibatch`, `n_envs` and
`gamma`. Weights and initial seeds are held equal, but asynchronous scheduling can
change the sample sequence. The temporary pool uses the current policy; it does not
copy the source branch's opponent archive. The report measures collection plus PPO,
excluding evaluations. It cannot establish long-term playing strength. Compare longer
forks on the same evaluation suites for learning per hour. The updated tactical preset
tries three epochs, learning rate 0.00004 and more tank/sniper practice; these are
starting hypotheses, not measured quality gains. Gamma remains 0.99; a higher discount
is an explicit experiment rather than an untested default change.
The action-bonus decay starts at update zero, so a mature fork does not receive fresh
bonuses for shooting or driving after those bonuses have already decayed away.

For a rules upgrade, fork the saved model into a new branch and retain the old branch
for comparison. Checkpoint compatibility preserves weights, not identical behavior
under changed game rules or reward definitions. Editing these files does not update an
already running trainer; use the new code when starting the intended fork.

“Play vs latest” serves the checkpoint using policy code from the same checkout as the
launched game. Torch inference accepts larger boards through the fully convolutional
trunk and adaptive pooling, while candidate indices use the matching canvas stride.
This avoids the former connection closure on maps wider than 64; large-board playing
strength still depends on training coverage. Server errors are returned explicitly to
the game instead of closing the socket without an explanation. The socket regression
also drives the real Godot learned controller on a 74×62 board without fallback.

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
  units each decision point (those with AP left first, and among them those with a visible
  enemy in reach on a firing line first), so the enumerator only looks at a few — over a
  turn the policy still reaches everybody. The contact-first order exists because a plain
  draw of 16 from ~46 showed a sniper's legal shot in 46% of the points where it had one,
  an anti-tank shot at a vehicle in 41% (tactical-1 eval, 2026-10-03). `max_candidates` then trims what
  survives, round-robin over (actor, intent kind) buckets so every rare kind and every
  actor keeps a slot. Together: 5.1 → 14.7 env steps/s, and a rollout that fits in RAM.
- Round cap per training episode (`round_cap`, 20 in `tactical.yaml`). Wiping the enemy army
  out ends the game at once and pays ±1. At the cap the remaining ARMY VALUE decides and pays
  ±0.5; a lead under one typical unit is `draw_cap` (−0.1). Owner's call, 2026-10-03: the cap
  went by head count before, and tactical-1 won a quarter of those games from behind on
  value — an early drone strike, then hiding cheap units until the bell. `info.by` is
  `rout` or `value` (`count` in older eval logs).
- Stage 1: civilians off, random events off (Q5). Turn them on in the config for later stages.
- Action space: all 37 intent kinds minus Undo/Redo (C6), minus GroupMove (a client-side
  bundle of moves) and BuildWall (6-cell LDF chain; v1 skips it), shots only at hostiles,
  vehicle component aim left to the resolver. See the header of `LegalIntents.gd`.
- Action head: the policy scores the enumerated legal candidates (actor cell + target cell
  gathered from the CNN map) instead of sampling unit→kind→target in three steps. It is the
  same factorisation read off the map, and illegal actions are structurally impossible.
- Reward (§6.1): Δ(own army value − enemy army value) per response, normalised by half the
  starting total; terminal ±1 for a rout, ±0.5 at the cap, −0.1 draw. A vehicle's value is
  its price × the share of ALL its component points left (it used to be the hull alone, so
  18 of a tank's 26 points — gun, turret, tracks — paid nothing until it died, and
  tactical-1 never fired an anti-tank shot at one). Plus, added after `town-1`:
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
