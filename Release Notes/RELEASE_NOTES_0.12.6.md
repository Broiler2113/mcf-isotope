# Isotope 0.12.6

- **Learned AI runs locally.** Desktop builds include an ONNX Runtime extension and a trained baseline policy, so AI - Learned needs no Python installation or policy-server process. Local `.onnx` overrides and model labels are supported. If native inference is unavailable, the existing socket backend and HARD fallback remain available.
- **Battlefield sound effects.** Dice, weapons, projectile launches and impacts, explosions, construction, mines, furniture, vehicles and UI actions now have sound. Positioned effects respect the viewer's fog of war. A prioritized 12-voice pool merges nearby duplicate effects and keeps large battles within a fixed voice budget.
- **SAM announcements.** 56 pre-baked robotic voice lines cover random events, player turns, outcomes, game modes, connections and Learned-AI fallback. All lines accompany existing visible information.
- **Audio settings.** The new Audio tab provides Master, Sound effects and Voice volume, mute, and an optional turn-announcement toggle. Settings persist alongside the existing interface and keybind settings.
- **Training reliability.** RLM training resumes with verified process IDs, guarded storage cleanup and Mac sleep prevention while the trainer is running.
- Multiplayer remains on protocol **16**. Learned opponents retain their existing local-play scope.
- Desktop downloads bundle the native extension, ONNX Runtime, model and audio assets. macOS builds use ad-hoc signing; Apple notarization is not configured.

## Validation

- All 249 scripts parse. The audio harness passes 519 checks covering timing, asymmetric fog, priority/caps, settings, dice, component damage, outcomes and recorded/replayed cue order.
- The Giant-board audio stress case runs 100 HARD AI decisions with 240 soldiers on a 149×119 board; 341 sound requests stay within the 12-voice ceiling without changing game state or dice.
- Native feature/inference parity checks cover real observations, optional fields, large boards, the Godot/native boundary and local model overrides.
- Direct and relay multiplayer, spectators, kicking, report-server checks, and existing small/medium battle signatures pass.
- The complete regression run retains the known `run_outer_grass.gd` failure in four Town border cases, reproduced on the untouched baseline and already documented in 0.12.5.
- Desktop builds validate the complete catalog of 34 effects and 56 SAM assets before export, and the exported-game smoke test loads the bundled model and every audio asset.

**Full changelog:** https://github.com/Broiler2113/mcf-isotope/compare/v0.12.5...v0.12.6
