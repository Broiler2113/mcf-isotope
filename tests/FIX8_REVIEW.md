# Fix-8 PDF review

Reviewed on 2026-10-22 against the owner's [13-page issue PDF](https://drive.google.com/file/d/1zzL3IJs1ZnthXhom3_rvS_f0h0-tEbvP/view),
the current source at `0a56e3e`, and the inherited uncommitted changes. The latest
first-person model/light-map rebuild was already in that commit; this work retains it
and completes the remaining features and corrections for the 0.13.1 source release.

## Requirement comparison

| PDF item | Result in the current project | Evidence |
| --- | --- | --- |
| 1. Botany rooms | Station research/service recipes include botany bays, planter beds, hydroponic racks and potting tables. | `MapFurnish.gd`; `mapgen/run_winter.gd` generates a large station with botany furniture. |
| 2. Outdoor plants | The outdoor furnishing pass includes bushes, grass, flower beds, hedges and trees, with matching 2D art and 3D models. | `Furniture.gd`, `MapFurnish.gd`, `tools/art/furniture.py`; greenery-variety assertion in `mapgen/run_winter.gd`. |
| 3. Cosmetic winter | Town/field winter persists through maps, battles and replays. The random-map checkbox sits beside Obstacles. Editor Map → Winter is undoable; its decoration palette includes snowmen and drifts. Snowfall has a Display setting. | `mapgen/run_winter.gd` compares summer/winter gameplay data for the same seeds, verifies deterministic snow and save round trips. `editor/run_winter_walk.gd` checks the editor toggle, undo, walkthrough and live snowfall setting. `ui/run_drawing_sharing.gd` also checks distant winter terrain colors. |
| 4. Empty initiative slots | No living soldiers means no turn; flying drones do not preserve an otherwise empty slot. | `TurnManager.gd`; `events/run_empty_raiders.gd`. |
| 5. Ruler and sidebar | Persistent rulers use drawing scope/history. Multi-select and heightmap remain hotkeys; their sidebar buttons are removed. | `MainAnnotations.gd`, `MainHud.gd`; `editor/run_soil_rulers.gd`, `ui/run_screens_walkthrough.gd`. |
| 6. Share earlier drawings | Changing sharing scope replays the author's existing strokes, erasures and rulers. Replaying also retains the undo history; duplicate strokes are removed in the correct order. | `ui/run_drawing_sharing.gd` exercises share, erase, duplicate entries, undo and old rulers. |
| 7. Furniture fragments | Destruction emits fragments cut from the furniture art instead of floor rubble. First-person fragments use the furniture's wood, fabric, metal or plastic material. | `ResolverFurnitureAndFire.gd`, `FxDecals.gd`, `FirstPersonBoard.gd`; `combat/run_furniture.gd`, effects and multiplayer decal suites. |
| 8. Welds, barricades, hedgehogs | Metal doors have weld seams and heat marks; wooden doors have nailed boards. Hedgehogs have new 2D sprites and crossed steel-beam models. | `tools/art/build_fix8.py`, `TerrainTiles.gd`, `FirstPersonModels.gd`; inspected outdoor render. |
| 9. Drone detonation undo | Detonation can be undone only when it kills nobody. Undo restores the drone, affected terrain and wounds; lethal detonations remain committed. | `vehicles/run_drone_undo.gd` tests nonlethal and lethal cases, undo/redo and two independently resolved peers using wire-encoded intents and recorded dice. |
| 10. Holdout swatch | Enemies left uses the wave side's color. | `_refresh_objective` in `MainDrawing.gd`; wave ownership/color tests in `events/run_wave_initiative.gd`. |
| 11. Missing raiders | A landing searches along the edge if its announced band is entirely vacuum. A few surviving stragglers no longer block the next army. | `ResolverEvents.gd`; `events/run_empty_raiders.gd`, existing random-event and initiative suites. |
| 12. Drone light | Live airborne drones add small lights; scouts have greater radius and intensity. Unseen enemy drones are excluded under fog. Both views use the same light inputs. | `MainBoardView.drone_lights`, `FirstPerson._update_light`; lighting/fog regression suites. |
| 13. Wall blood | Directional spatters, streaks and drips replace plain patches. 2D and 3D select the same procedural variant for an entry. | `FxDecals.spatter_image`, `MainDrawing._draw_wall_blood`, `FirstPersonBoard._wall_spatter`; inspected wall spatters in the furniture render. |
| 14. Borg demolition | An engineer/miner operating a borg demolishes three wall, glass or airlock cells per AP; remaining credits work at zero AP and expire with the round. | `ResolverWorks.gd`; `combat/run_engineer_demolition.gd`, existing borg suite. |
| 15. Unweld | The engineer action toggles welding/cutting. Borg weld credits work at zero AP, and cutting immediately refreshes automatic door opening. | `GridCell.gd`, `ResolverWorks.gd`, `MainOrders.gd`; `combat/run_engineer_demolition.gd`. |
| 16. Borg corpses | Body piles render after idle hulls and occupied borg operators. Shuttle bodies retain their existing behavior. | `MainDrawing.gd`; `ui/run_first_person_damage.gd`, `vehicles/run_vehicle_rules.gd`. |
| 17. Editor walkthrough | View → Walk in First Person, then select a walkable cell. An invalid click allows retry. Esc returns to the editor. Placed civilians and corpse piles are retained, independent of lobby limits. | `FirstPersonHost.gd`, `MapEditor.gd`; `editor/run_winter_walk.gd` checks entry/exit and unchanged map data. |
| 18. Live accent stripe | The existing sidebar grip repaints on the accent-change signal. | `UiTheme.gd`, `MainHud.gd`; `ui/run_screens_walkthrough.gd` changes the accent and checks the existing stripe. |
| 19. Physical small objects | Small items use meshes on furniture tops and on the floor. The rifle has connected receiver, handguard, grip and magazine geometry. | `FirstPersonModels.item`, `FirstPersonBoard._items`; inspected furniture render with monitor, keyboard, mug and floor rifle. |
| 20. Furniture connections | The current model rebuild supplies connected frames, legs, shelves and table tops. Partial destruction clips the original model instead of shrinking it into the surviving cells. | `FirstPersonModels.gd`, `FirstPersonBoard._piece`; furniture and damaged-bed renders. |
| 21. Door flicker | Door leaves sit in the opening with separated frame/leaf surfaces; adjacent wall faces do not overlap the leaf. | Door construction in `FirstPersonBoard.gd`; town/station walkthrough and mesh-winding checks in `ui/run_first_person.gd`. |
| 22. Texture scale and DPMG | Materials and surfaces share 32 texels/metre. The DPMG is a gun, receiver and tripod model; tables have structural frames. | `FirstPersonArt.gd`, `FirstPersonModels.gd`; inspected furniture/outdoor renders. All 32 baked material/ground images compare exactly with their procedural sources. |
| 23. Vehicle lettering | Handjet labels are fixed to both hull flanks, rotated with the vehicle and sized to fit its body. | `FirstPerson._vehicle_node`; vehicle rendering scene. |
| 24. Destroyed beds | Surviving sections retain the original bed size, orientation and location. The original footprint is recovered when a battle is loaded, without restoring destroyed gameplay cells. | `ui/run_first_person_damage.gd` checks clipping at all four rotations and saved-battle restoration; inspected damaged-bed render. |
| 25. Matching lighting | First person samples the same `LightManager` lighting used by the board, including ambient settings, fixtures, fire and drones. The shared light map replaces many independently flickering 3D lights. | `FirstPerson._update_light`, `LightManager.gd`; lighting regression suites and Compatibility rendering. |
| 26. Walking performance | Cached models, merged streamed chunks and limited rebuilds from the latest commit are retained. Baked material/ground images remove the cold-entry pixel-generation pause. | Reproducible `bench/run_first_person_bench.gd` with 200 soldiers; `-- --procedural` compares the original generation path. See validation below. |
| 27. Purchase zoom | Minimum zoom adapts to map dimensions and the viewport width left by the sidebar. | `Placement._zoom_min`; `ui/run_screens_walkthrough.gd` fits a 500×200 map beside the panel. |
| 28. Black LDF | The LDF model is black and does not inherit wall accent bands. | `FirstPersonModels.gd`; `ui/run_ldf_accent.gd`, inspected outdoor render. |
| 29. Unclear rectangular model | The current model set uses object-specific silhouettes, screens, frames and materials instead of generic extruded images. | Inspected furniture render; model rebuild in `FirstPersonModels.gd`. |
| 30. Unclear furniture model | Connected furniture geometry and consistent texture density address the screenshot's disconnected shapes. | Inspected furniture render, mesh winding checks. |
| 31. Sandbags | Rounded bags with pinched ends form offset courses; the previous stepped rectangular stacks are replaced. | `FirstPersonModels._bag_row`; inspected outdoor render. |
| 32. Fortification screenshot | Sandbag/hedgehog combinations use rounded fabric bags and crossed steel beams with distinct materials. | Inspected outdoor render. |
| 33. Workbench/bathroom screenshots and overall polish | Object-specific table, workbench, sanitary fixture and storage models are retained from the current rebuild; small props, damaged pieces and sandbag shapes received the additional corrections above. | Inspected furniture, damaged-bed, outdoor and winter renders from `render_first_person.gd`. |

## Validation

Godot 4.7 stable, GL Compatibility. Final results:

- All 313 project scripts parse cleanly.
- The full runner completed 97 GDScript suites, including the 733-line unchanged
  gameplay trace, undo/redo consistency, wire codecs, maps, editor/UI behavior,
  saves/replays, lighting, AI and audio. Its only failed assertion searched source
  text for the old `shuttle_bodies` variable. That test now checks the generalized
  `vehicle_bodies` draw order and a real shuttle seat; the complete vehicle-rules
  suite passed on rerun. The original runner therefore reports failure, while the
  corrected suite and all other suites pass. There were no GDScript runtime errors.
- Small and medium deterministic benchmarks match their existing expected behavior;
  no gameplay baselines were replaced.
- Local multiplayer passed asymmetric/mirrored matches, leaving, town maps,
  readiness, both reconnection variants, spectators and kicking. Relay self-tests
  and relay match/reconnection cases also passed. Python bug-report, timing and
  native-policy manifest checks passed.
- All 32 baked first-person images exactly match their procedural sources.
- On the 124×104 winter-town fixture with 200 soldiers, measured cold entry was
  **1,039.7 ms with baked textures versus 3,066.2 ms with procedural generation**.
  Selected CPU update phases averaged 1.802 ms/frame and 1.771 ms/frame respectively,
  with 108 resident chunks. These single-run timings depend on host load; the change
  targets the cold-entry pause and leaves steady-state behavior intact.
- The project knowledge graph was rebuilt and `git diff --check` passed.

Some existing suites emit Godot resource/object cleanup warnings at process exit;
these are distinct from test assertions and runtime script errors.

The manual renderer writes five images to `/tmp/isotope-first-person-*.png`, waits for
streamed content, moves the camera for 60 frames per scene and verifies that walking
never changes the encoded simulation. Furniture, damaged bed, outdoor, winter and
vehicle scenes rendered successfully without shader errors and were visually inspected.
The furniture scene also includes wall spatters. Archived logs and screenshots from
this review are in the ignored `.cache/fix8-review/` directory.

The cloud host renders with Mesa llvmpipe (software OpenGL). Its rendered frame times
are not evidence of gaming-GPU frame rates. The headless benchmark separately measures
entry time and selected CPU update phases; it does not measure the complete rendered
frame. Hardware playtesting remains necessary to establish frame rates across GPUs.

## Reproduction

```sh
bash tests/run_all.sh
godot --headless --script res://tools/art/build_first_person.gd -- --verify
godot --headless --script res://tests/bench/run_first_person_bench.gd
godot --headless --script res://tests/bench/run_first_person_bench.gd -- --procedural
xvfb-run -a godot --path . --script res://tests/render_first_person.gd
```

Use `MCF_DATA_DIR`, `XDG_DATA_HOME` and `XDG_CONFIG_HOME` to isolate test data. The full
suite needs permission to bind local TCP/UDP sockets. On a desktop, omit `xvfb-run -a`
to view the rendering scenes directly.
