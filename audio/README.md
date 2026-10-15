# Sound effects and SAM announcements

Audio is client presentation. `GameAudio` owns the Master/SFX/Voice buses, UI
one-shots and a bounded single-speaker announcement queue. `BattleAudio` owns a
12-player world pool and one quiet non-positional ambience loop. It receives
`FxDecals.sound_requested` lifecycle signals and gates each source against the
same viewer/pre-impact visibility used by the screen. Moving vehicles and playing
tails are checked again when visibility changes. Camera pan/zoom transforms the
world players; UI, ambience and SAM remain unpositioned.

Rifle/burst/laser/flame sounds launch with firing lanes. Bullet impacts follow
tracer removal; rockets, shells and grenades have separate launch and arrival
sounds. A projectile's explosion flash adds no second bang. Non-projectile blasts,
glass, structural debris, fire and corpses use their cosmetic application phase.
Construction, mine work and welding use the accepted action's existing log text.
Vehicle component destruction uses a local `visual_hold` health snapshot and is
announced at impact, once per result. No audio field is written into `GameState`,
intent/network messages, replay recordings or saved FX snapshots; no audio code
uses the game's random number generator.

The world pool merges matching nearby cues within 40 ms, with at most 3 dB of
extra gain. Higher-priority own-unit sounds replace lower-priority visible sounds;
ties replace the oldest voice. Lower-priority requests are dropped when every
playing voice outranks them. Players are reused, so a burst never allocates an
unbounded number of audio nodes. Master has a limiter, UI has four players and
SAM has one speaker plus at most six queued lines. Turn lines yield to warnings
and victory replaces stale queued announcements.

Random-event/wave/zone/fallback announcements are derived from messages actually
shown in the battle log. Zone updates announce public scoring changes, rather
than inspecting hidden occupants between scoring moments. Turn handoffs narrate
the HUD; victory/defeat/draw narrate the outcome. Lobby connection lines follow
the existing connection status updates. Replay playback uses the same FX hooks;
seeking and undo clear active audio and suppress reconstructed history.

Settings → Audio provides Master, Sound effects and Voice (SAM) volume, Mute,
and an optional turn-announcement toggle. Changes apply immediately and merge
into the existing `user://settings.cfg`, preserving other settings sections.

## Offline assets

`catalog.json` contains SFX recipes and a flat list of `(id, text)` SAM lines.
The checked-in assets are mono 22,050 Hz, 16-bit PCM WAV: 34 effects and 56 lines
(20 random-event lines, 26 player letters and 10 status/connection/mode lines).
There is no music, runtime synthesizer, Python process or extra native dependency.

The effects are synthesized from deterministic noise, filtered impulses and short
tones by the repository's generator; they contain no third-party recordings.
SAM lines were rendered with Stefan Macke's C port, pinned to commit
`a7b36efac730957b59471a42a45fd779f94d77dd`, at speed 84 / pitch 60 / mouth 128 /
throat 128. The synthesizer is a cached build tool and is not shipped. Upstream
provenance and licensing notes are in the [SAM README](https://github.com/s-macke/SAM#readme).

```sh
# Python standard library plus git and a C compiler, only for asset authors:
python3 tools/audio/bake_audio.py --fetch-sam
# Or reuse an already built standalone SAM executable:
python3 tools/audio/bake_audio.py --sam /path/to/sam
# Verification needs no compiler, SAM checkout or third-party Python packages:
python3 tools/audio/bake_audio.py --check
python3 tools/audio/test_catalog.py
```

Unchanged voice text/settings are reused. A bake updates WAVs, the generated
`src/audio/AudioCatalog.gd` lookup and `manifest.json` checksums. Commit those
outputs together with catalog changes. The validator also checks the game's
event registry and player letters, so adding a trigger without a corresponding
line cannot silently pass. `native/policy/package.py` runs this build gate before
export and includes the audio assets. The desktop workflow checks the gate and
runtime behavior on all four configured desktop targets; its exported smoke test
loads every SFX and SAM asset from the actual pack.

## Tests and stress case

```sh
godot --headless --path . --script res://tests/run_audio.gd
godot --headless --path . --script res://tests/bench/run_audio_bench.gd
```

The focused harness checks imported assets, fast/slow launch-arrival timing,
asymmetric real-resolver fog, camera transforms, duplicate collapsing, voice
priority/caps, component damage, automatic/remote dice, saved settings, independent
Voice mute, public-message narration and recorded/replayed weapon cue order.
It is included in `tests/run_all.sh`. Fault-injection tests reject a missing WAV,
modified asset and stale catalog. The Giant-board stress case uses 240 soldiers
on 149×119 and 100 real HARD AI decisions, verifying the pool limit and that FX
playback leaves state/dice unchanged. Timing is informational.
