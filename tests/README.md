# Regression harness

Headless runs, no engine window (the lobby check builds its scene without
rendering it), no assets required.

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

**`run_lobby_maps.gd`** builds the real lobby scene and asserts that every map on
disk — shipped in `res://maps` and saved by the editor in `user://maps` — is a row
in its dropdown, that each row points at a file that still reads back as a map, and
that rescanning the folders neither loses maps nor doubles them. It exists because
"my saved maps are not in the list" has now been reported twice: the first cause
(the app rename moved `user://`) was fixed in code nothing checked.

**`run_combat_safety.gd`** covers three rules that only show up in play:
a line of fire that starts or ends *off the board* (a soldier riding inside a
vehicle sits at −9999, and every walker along a ray used to march off the grid
from there — "Out of bounds get index '-509898'"); the AI anti-tank refusing a
charge whose blast — on any of the six die rolls, shortfall included — would
catch himself or a squadmate; and the shot cosmetics: one casing per round fired,
a second burst from the same cell landing in its *own* spots, and one
"who shot whom" lane per attack.

**`run_ui_assets.gd`** asserts every texture the interface skin is built from
comes back as an *imported* resource rather than a raw disk read. The skin used
to be loaded with `Image.load`, which the engine warns "will not work on
export" — it survived only because `file_exists()` answers "no" inside a `.pck`
and the code fell through to a backup branch. The run also pins the promise in
`HOW_TO_REPLACE_INTERFACE_TEXTURES.txt` §4: a PNG dropped in on top of an
imported one is still read straight off disk, so reskinning from source needs no
re-import.

**`run_ai_conduct.gd`** watches how the AI *behaves*, not what it computes. It asserts
the AI never spends an action point on a shot it cannot land (cover can push the
required roll to 7, which a d6 never shows — range alone used to be the only thing
checked); never drives a tank over its own infantry; never walks a unit back to
where it stood a turn ago; and that an idle vehicle is picked up by the forced pass
and given a real order, even when the infantry has already met its activity quota.

`run_ai_conduct.gd` also covers the planner keeping soldiers out of a friendly tank's
driving lane, and the anti-tank opening on armour rather than on a closer, softer
infantry target. `run_combat_safety.gd` also covers a tank's tracks reporting the
tiles they flatten, boarding not refunding a vehicle's spent AP, and a civilian's
fire producing the same who-shot-whom lane as anyone else's.

**`run_mirror_stamp.gd`** builds the real placement scene, stages one of every kind
in the host's zone and stamps the mirrored formation, asserting that infantry *and
every vehicle* cross over and land fully inside the guest's deployment zone. It
exists because the mirror mapped a footprint's top-left corner to where its
bottom-right belongs: harmless for 1×1 infantry, fatal for a 3×3 tank, and a coin
toss for a 2×2 shuttle — which is exactly the "tanks don't transfer, and shuttles
too sometimes" the report described.

**`run_modular_tank.gd`** covers the modular armour milestone end to end: the four
independent pools and their starting values, each zero taking away exactly one
capability, the aimed roll's +1 (an aimed Hull shot cannot miss), the cascade skipping
destroyed components and never returning "nothing hit", overkill carrying into the Hull,
the fixed-target sources (mines, miner, personnel mines no longer touching vehicles),
crew being risked only by Hull hits, Engineer repair with its cap and ownership rules,
capture preserving component state, and finally a live anti-tank gunner wearing a tank
down through the real resolver.

`run_modular_tank.gd` also covers the left/right track split (driving needs both,
turning needs either), the flank rule deciding which track a shooter can reach and the
gun being hidden from behind where it points, and the two armoured materials — a wall
that shrugs off eight blasts beside it but dies to one on top, and glass that holds on
4+.

## Scope

None of these runs is evidence that the game *plays* correctly. They are evidence
that it does not crash, does not deadlock the AI, and does not desync. Play the
real game as well.
