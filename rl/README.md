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
rl/tools/check_replay.gd          plays a recorded .mcfr through ReplayPlayer                 (10.3)
tests/run_legal_intents.gd        exactness: every enumerated intent resolves OK               (13.1)
tests/run_learned_controller.gd   fallback path (always) and live path (with MCF_RL_POLICY)
```

## Setup (laptop = trainer + dashboard; the site is a tunnel to it)

```
bash rl/setup.sh [<tunnel-token>]   # venv (CPU/MPS torch), tmux, cloudflared, rl/.env, Godot import
```

`rl/.env` (never committed) holds `MCF_RLM_PASSWORD` (the dashboard login, generated once),
`GODOT` (binary path) and `VENV`. Godot 4.7 must be installed; on macOS setup finds
`/Applications/Godot.app`. With a tunnel token the script also runs
`cloudflared service install`, which makes **rlm.mindcontrolfactor.com** reach this machine's
`:8501` from anywhere, at boot, for as long as the machine is on. The tunnel (`mcf-rlm`) and
its DNS record live in Cloudflare; `rl/tools/cf_tunnel.sh` recreates them from an API token.

## Running

```
bash rl/run.sh up                                        # tmux: TensorBoard :6006 + dashboard :8501
bash rl/run.sh start rl/config/laptop.yaml phaseA-1      # or press Start on the dashboard
bash rl/run.sh attach                                    # watch; Ctrl-b d to detach
bash rl/run.sh status
bash rl/run.sh stop phaseA-1                             # checkpoint after this update, exit
bash rl/run.sh resume phaseA-1 [new-config.yaml]         # continue; new config = graduation
bash rl/run.sh restart phaseA-1 new-config.yaml          # stop → wait for checkpoint → resume
bash rl/run.sh fork phaseA-1/ckpt_000100000.pt experiment-1
python rl/train.py eval rl/runs/phaseA-1/latest.pt --games 20 --opponent hard --record /tmp/ev
python rl/train.py play rl/runs/phaseA-1/latest.pt       # real game, checkpoint in the AI slot
python rl/train.py export rl/runs/phaseA-1/latest.pt policy.onnx
```

The dashboard (`rl/dashboard.py`, Streamlit, spec §11) is the one place for everything:
live curves (§11.2), start/stop/resume and config edits applied by stop→resume (§11.3),
the checkpoint spreadsheet with fork lineage and CSV export (§11.4), the Phase B graduation
button (§11.5), "play vs checkpoint" which opens the real game (§11.6), the replay gallery
with outstanding tags and "open in the game" (§11.7), per-map trends (§11.8). It shells out to
`rl/run.sh`, so anything it does you can also do from the terminal. TensorBoard stays on
**127.0.0.1:6006** as the raw view.

Ctrl-C / SIGTERM / the `STOP` flag file all finish the current update, save a checkpoint,
and terminate every Godot process (they run in their own process group).

## What is where

- `rl/runs/<branch>/ckpt_<step>.pt`, `latest.pt` — full resume state: weights, optimizer,
  config, phase, stage, map rotation, match counters, RNG, parent checkpoint (fork lineage).
  `ckpt_<step>.pt.json` — the same minus weights, what the dashboard's table reads.
- `rl/runs/<branch>/status.json` — heartbeat (state, pid, step) written every update.
- `rl/runs/<branch>/tb/` — TensorBoard: `ppo/*`, `train/winrate_vs_ai`, `train/winrate_vs_pool`,
  `train/drawrate`, `train/match_rounds`, `train/value_diff_end`, `train/illegal_per_match`,
  `usage/unit_*`, `usage/kind_*`, `map/<map>_winrate`, `eval/winrate_{normal,hard}`, `speed/*`.
- `rl/runs/<branch>/replays/checkpoint_<step>/vs_{normal,hard}_<k>_<result>.mcfr` — the sampled
  evaluation games; open them from the game's replay screen or check with
  `godot --headless --script res://rl/tools/check_replay.gd -- <file>`.
- `rl/runs/<branch>/eval_log.jsonl` — the clean win-rate series, one line per evaluation
  with `*_normal` and `*_hard` columns. Each recorded replay has a `.mcfr.json` sidecar
  (branch, step, opponent, result, value diff, rounds, map) for the gallery.

## Decisions baked in (change = retrain)

- Canvas 64×64, maps larger than that are not admitted to the pool (Q2).
- Round cap 10 per training episode; the cap is a draw with a small negative reward (Q4, owner's number).
- Stage 1: civilians off, random events off (Q5). Turn them on in the config for later stages.
- Action space: all 37 intent kinds minus Undo/Redo (C6), minus GroupMove (a client-side
  bundle of moves) and BuildWall (6-cell LDF chain; v1 skips it), shots only at hostiles,
  vehicle component aim left to the resolver. See the header of `LegalIntents.gd`.
- Action head: the policy scores the enumerated legal candidates (actor cell + target cell
  gathered from the CNN map) instead of sampling unit→kind→target in three steps. It is the
  same factorisation read off the map, and illegal actions are structurally impossible.
- Reward (§6.1): Δ(own army value − enemy army value) per response, normalised by half the
  starting total; −0.01 per own end-turn; +1/−1 terminal; −0.1 draw.
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
