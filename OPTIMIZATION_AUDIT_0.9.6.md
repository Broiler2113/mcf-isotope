# MCF Isotope — optimization assessment for 0.9.6

Base: published `v0.9.5`, commit `2dd511735ab140cb7ef167863d64d3e7be21a2fe`.
Engine: Godot 4.7, GL Compatibility. Assessment date: 2026-10-09.

## Scope and preservation

The review began with a repository-wide inventory and dependency scan of all 1,275
tracked files, GDScript compilation checks, Python AST parsing, JSON validation and
content hashes. Direct review covered the simulation/AI/cache contracts, scene flow,
rendering, networking, recording/playback and regression harness. The RL bridge,
training pipeline, data resources and asset tools were included in the inventory.

Implementation and validation used separate checkouts based on the published commit.
The original checkout's extra local commit and pre-existing uncommitted files were
excluded. Their HEAD, status, binary diff and file hashes were recorded for comparison.

This release changes computation and ownership in presentation/recording code. Maps,
unit statistics, vehicles, factions, fonts, texture atlases, particle amounts and
limits, game rules, map generation and RL action ordering are preserved. No tracked
file is deleted. The existing gameplay golden traces are checked without rebaselining.

## Assessment

| Area | Finding and decision |
| --- | --- |
| Simulation and movement | Already use versioned caches and incremental cell journals. `Movement.reachable` insertion order and `Grid.N8` order affect AI choices; replacing its frontier with a heap would violate GAME_SPEC §27.2. Preserve these contracts. |
| Fog and AI planning | Remain the main simulation costs. The current large reference benchmark spends about 9.7 s in viewer fog and 6.1 s in AI across 1,554 actions. These measurements identify priorities, not an overall speedup claim. Further changes need the ray/sweep, incremental-fog, AI and ordered-trace reference gates. |
| Terrain and effects | Chunked terrain and baked settled decals already avoid per-frame drawing of every particle. The far-map update still walked the entire settled list whenever one new particle arrived. Optimize that traversal, preserving its exact indexing and blend order. |
| Replay seeking | Frame selection scanned every preceding action, although only the last preceding keyframe matters. Search backwards from the target without introducing a cache or changing file formats. |
| Resource ownership | ReplayRecorder and GameActionResolver formed a reference cycle. LearnedController's fallback lambda formed another. Both retained finished match objects. Replace the recorder's return link with a weak reference and the fallback lambda with a method Callable. |
| Scene preloading | Background menu preload jobs could outlive shutdown, producing a baseline scene parse error. Retain completed warm resources, finish active requests on exit and avoid visible-scene preloading in headless runs. |
| Data, networking and save formats | Intent/state codecs and deterministic recorded dice have extensive reference tests. No serialization or protocol changes are warranted for these optimizations. |
| RL and asset generation | Candidate ordering is part of the trained policy's action interface; generation and furnishing also determine content. Preserve both. Python RL tests and existing learned-controller fallback tests check the unchanged paths. |

## Measured changes

Both focused benchmarks run the original reference and current implementation in
the same process. Times depend on the machine; they are informational and are not
test thresholds or claims about overall frame rate.

| Operation | Original reference | Optimized |
| --- | ---: | ---: |
| Nearest-frame lookup near action 60,000, keyframes every 1,000 actions | about 8.5 ms | about 0.11 ms |
| Apply one new decal after 68,000 settled particles | about 6 ms | about 0.004 ms |
| Owners retained after eight recorded/fallback matches end | recorder/resolver/state and fallback controllers retained | all observed owners destroyed; recordings still replay |

Reproduce the focused comparisons with:

```sh
godot --headless --script res://tests/run_replay_seek.gd -- --bench
godot --headless --script res://tests/run_decal_sync.gd -- --bench
godot --headless --script res://tests/run_match_lifetime.gd
```

`run_replay_seek` checks frame boundaries, legacy data, mutable recordings and actual
forward/backward match reconstruction. `run_decal_sync` checks exact image bytes,
simulation hashes and unchanged particle data through additions, resets and eviction.
`run_match_lifetime` checks destruction through weak references and replays a recorded
AI battle with identical board and dice consumption.
The multiplayer performance fixture also uses method forwarding for its loopback
guest, preventing its two simulated peers from retaining each other after assertions.

## Release validation

The full `tests/run_all.sh` suite passed, including all five two-process ENet match
scenarios. Small/medium/large benchmark signatures remained unchanged, Python
`rl/test_rl.py` passed, and all 175 GDScript files parsed cleanly. Battle/menu
interaction tests passed under the real Compatibility renderer in Xvfb.
The original checkout and all unmodified tracked content are checked again before
publication. Graphify's source graph is rebuilt after the source changes.

Validation is on Linux/Godot 4.7. A live trained policy checkpoint was not supplied;
tests requiring `MCF_RL_POLICY` report their normal skips, while fallback, toy-server
and Python model/bridge tests run. Native Windows/macOS execution and exhaustive
manual gameplay are outside this automated validation; passing tests are not proof
that every possible match is flawless.

The lobby-only `run_play_vs_learned` test also emits its pre-existing Godot shutdown
diagnostic for four compiler objects and the MCF/Roster script resources. This was
reproduced on the unchanged baseline and is separate from retained match instances.
The optimized menu and rendered battle tests exit without their former scene-load
and match-resource errors.

The individual headless ENet guest logs also report renderer/font allocation leaks
on shutdown, which the network runner's summary does not display. The same
allocation types were reproduced on the unchanged 0.9.5 baseline; all host and guest
assertions pass. These existing shutdown diagnostics remain outside the ownership
cycles fixed here and are not a claim of error-free engine teardown.
