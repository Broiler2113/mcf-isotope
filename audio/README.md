# Sound effects and SAM announcements

Audio is client presentation. `GameAudio` owns the Master/SFX/Voice buses, UI
one-shots and a bounded single-speaker announcement queue. `BattleAudio` owns a
12-player world pool, one fire loop and one non-positional ambience bed per environment. It receives
`FxDecals.sound_requested` lifecycle signals and gates each source against the
same viewer/pre-impact visibility used by the screen. Moving vehicles and playing
tails are checked again when visibility changes. Camera pan/zoom transforms the
world players; UI, ambience and SAM remain unpositioned.

Muzzle sounds launch with firing lanes and follow the weapon: the lane carries the
shooter's unit type (or `dpmg`/`borg` for mounted guns), so riflemen, snipers,
shotguns, machine guns and heavy MGs each sound like themselves. Bullet impacts
follow tracer removal and read the settled cell: a body, a Shield Bearer's plate, a
hull, else the wall or floor material (glass, wood, masonry, plating, earth).
Rockets, shells and grenades have separate launch and arrival sounds. A projectile's
explosion flash adds no second bang. Non-projectile blasts, glass, structural debris,
fire and corpses use their cosmetic application phase. Construction, digging, mine
work, welding, shield strikes and grabs use the accepted action's log/dice events.
Vehicle component destruction uses a local `visual_hold` health snapshot and is
announced at impact, once per result. Walk animations add a footstep per cell on
that floor and open/shut airlocks as soldiers pass; drones carry a rotor loop.
No audio field is written into `GameState`, intent/network messages, replay
recordings or saved FX snapshots; no audio code uses the game's random number generator.

`BattleAudio.world` reads the live state for the map environment: each environment
(station, bunker, asteroid, town, field) has its own ambience bed and World-bus room
reverb, cells in vacuum play through a muffled Vacuum bus (the other side's sounds
quieter still), and visible burning cells share one crackling loop placed among them.
Announcements are keyed over a field radio: a handset click before a SAM line, the
end-of-transmission tone after the last one, and a telephone-band Voice bus.

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

Every sound effect is cut from CC0 / public-domain recordings: The Free Firearm
Sound Library (96 kHz field recordings of 22 firearms), public-domain US military
recordings and other CC0 field recordings on Freesound, and Kenney's CC0 foley/UI
packs. `catalog.json` pins each source by URL and sha256 and lists every take as an
explicit time slice; `CREDITS.md` (generated) names them all.

One mastering chain makes them a single family: mono 44.1 kHz, 30 Hz–16 kHz,
trimmed to the event with the same fades, levelled per category (gun, heavy,
impact, debris, foley, event, radio, ui, engine, fire, ambience), peak-limited to
-2 dBFS and written as Ogg Vorbis; loops get a crossfaded seam. At runtime each play
picks another take and varies pitch/level slightly by category, and
`GameAudio.CATEGORY_DB` sets one mix level per category. There is no music and no
runtime synthesizer. SAM lines are unchanged (mono 22,050 Hz WAV), rendered with
Stefan Macke's C port pinned to `a7b36efac730957b59471a42a45fd779f94d77dd`
(speed 84 / pitch 60 / mouth 128 / throat 128); provenance in the
[SAM README](https://github.com/s-macke/SAM#readme).

```sh
# SFX need the offline venv (asset authors only; the game needs none of it):
uv venv .cache/audio/venv
VIRTUAL_ENV=.cache/audio/venv uv pip install numpy scipy soundfile py7zr
.cache/audio/venv/bin/python tools/audio/bake_audio.py --sfx-only
# SAM lines (git and a C compiler):
.cache/audio/venv/bin/python tools/audio/bake_audio.py --fetch-sam
# Verification needs only the standard library:
python3 tools/audio/bake_audio.py --check
python3 tools/audio/test_catalog.py
```

Sources download once into `.cache/audio/raw` and must match their pinned hash.
A bake rewrites the Ogg takes, the generated `src/audio/AudioCatalog.gd`,
`CREDITS.md` and `manifest.json` checksums; run `godot --headless --import` and
commit the outputs (with their `.import` files) together with catalog changes. The
validator also checks the game's event registry and player letters, and rejects
missing, modified or stray assets. `native/policy/package.py` runs this build gate
before export.

## Tests and stress case

```sh
godot --headless --path . --script res://tests/audio/run_audio.gd
godot --headless --path . --script res://tests/bench/run_audio_bench.gd
```

The focused harness checks imported assets, fast/slow launch-arrival timing,
asymmetric real-resolver fog, camera transforms, duplicate collapsing, voice
priority/caps, component damage, automatic/remote dice, saved settings, independent
Voice mute, public-message narration and recorded/replayed weapon cue order.
It is included in `tests/run_all.sh`. Fault-injection tests reject a missing take,
modified or stray asset and stale catalog. The Giant-board stress case uses 240 soldiers
on 149×119 and 100 real HARD AI decisions, verifying the pool limit and that FX
playback leaves state/dice unchanged. Timing is informational.
