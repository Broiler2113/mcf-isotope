# Regression harness

Two headless runs, no engine window, no assets required.

```
bash tests/run_all.sh            # verify
bash tests/run_all.sh --update   # re-baseline after a deliberate rule change
```

**`check_scripts.gd`** loads every `.gd` in the project and fails on any that will
not parse. It exists because `godot --check-only --script X.gd` cannot see the
`Ui` autoload, so every scene script "fails" under it for no reason; here the
project is actually running, so autoloads and global classes are present.

**`run_headless.gd`** plays a fixed-seed AI-vs-AI match on the fixed map in
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

**`run_lockstep.gd`** builds two independent matches from the same map and seed,
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

**`run_codec.gd`** builds one of every `Intent` subclass with distinctive values,
round-trips it through `IntentCodec`, and compares *every* script property. It
also fails if a subclass on disk has no sample, so a new intent cannot be added
without noticing the codec. This exact class of bug has now shipped twice —
`MoveIntent.carry_drop` (#100) and `DigIntent.dirt_a/dirt_b` (`AUDIT.md` §2.2) —
and neither compiles wrong nor shows up in an AI match, because the AI never
chooses the field by hand.

**`run_player_actions.gd`** lockstep-checks the things a *player* does and an AI
never does: digging with hand-picked dirt cells, a group move order, undo/redo,
and refusing an end-turn or undo from a side that is not acting. Same
host/client protocol as `run_lockstep.gd`, with per-action board comparison.

## Scope

Neither run is evidence that the game *plays* correctly. They are evidence that
it does not crash, does not deadlock the AI, and does not desync. Play the real
game as well.
