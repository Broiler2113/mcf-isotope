# Embedded learned policy

`MCFPolicy` is a Godot GDExtension using the ONNX Runtime CPU C API (through its
header-only C++ RAII wrappers). Players need neither Python nor a policy server.
The game uses the bundled model first, then `MCF_RL_POLICY`, then the existing
permanent HARD fallback and `fallback_engaged` combat-log signal. Online matches
retain their existing controller restrictions; this adds no lockstep guarantees.

Build on Linux x86_64, Windows x86_64 (Visual Studio 2022), macOS arm64 or macOS
x86_64 with Python 3.12+, CMake 3.22+, git and a C++17 compiler:

```sh
python native/policy/build.py
godot --headless --editor --path . --import --quit
godot --headless --path . --script res://tests/run_native_policy.gd -- --require-native
```

The build downloads checksum-pinned ONNX Runtime 1.22.0 and nlohmann/json 3.11.3,
and verifies godot-cpp's pinned commit. The 4.5 bindings use only the stable
RefCounted/FileAccess API and load in the target Godot 4.7. `dependencies.json`
records the pins. Dependencies/build output live under ignored `.cache/`;
`addons/mcf_policy/bin/<platform>-<architecture>/` holds the extension, runtime,
and required license notices. Windows also stages app-local MSVC runtime DLLs.
An unsupported or absent native build leaves the socket/HARD path available.

Use `--godot-cpp`, `--ort-root`, and `--json-include` to reuse local dependencies.
The `--cache`, `--build-dir`, and `--jobs` options control build storage and load.
Do not enable fast-math: tensor layout, scaling and overwrite order are the
training ABI. `src/layout.hpp` mirrors `rl/features.py`; the parity harness checks
every integer layout constant and each ordered feature-name list.

## Model and selection

The bundled model is `assets/policy/baseline.onnx`. Its checkpoint label, source
SHA-256, round cap and candidate/actor budgets are embedded as ONNX metadata.
To update it, use the existing export command (the output is a positional argument):

```sh
python rl/train.py export rl/runs/<run>/latest.pt assets/policy/baseline.onnx
```

`MCF_RL_MODEL=/absolute/path/policy.onnx` selects a local override. An invalid
explicit override reports failure and tries the socket; it does not silently use
bundled weights. `MCF_RL_MODEL_LABEL` overrides the displayed label. Otherwise the
lobby uses the selected model's metadata label. Existing `MCF_RL_ROUND_CAP`,
`MCF_RL_MAX_ACTORS`, and `MCF_RL_MAX_CANDIDATES` override the model's metadata.
Models without metadata retain the controller's legacy defaults.

`MCF_RL_BACKEND=socket` explicitly selects the Python server. `train.py play` sets
this so the bundled checkpoint never intercepts a trainer's freshly started
server. Without this setting a healthy embedded policy takes priority even when
`MCF_RL_POLICY` is set. Replay analysis uses the same selected backend with its own
client/socket and the checkpoint's observation budgets.

The model receives float32 `grid[1,99,H,W]`, `flat[1,28]`, `cand[1,N,122]` and
int64 `cells[1,N,2]`; it returns float32 `logits[N]` and scalar `value`.
Square canvases are bucketed by 16, at least 64 and at most 256. Export supports
dynamic spatial/candidate dimensions and the same 96-cell convolution cap as
training. The graph rounds grid/candidate features through float16 to match
`train.encode`/`Sparse` storage; the encoder itself matches `features.py` float32.
Action selection matches `model.greedy_action`: compare stop/continue policy mass,
then take the first maximum within the winning branch. Flat argmax is different.

## Verification and release

```sh
python rl/test_native_policy.py --probe .cache/native-policy/mcf_policy_probe \
  --checkpoint rl/runs/<run>/latest.pt --extension --report .cache/policy-parity.json
godot --headless --path . --script res://tests/bench/run_native_policy.gd
python native/policy/package.py
```

On Windows the probe is `.cache/native-policy/Release/mcf_policy_probe.exe`.
The parity harness needs the trainer's dependencies (including ONNX/ONNX Runtime).
It records real resolver observations at 34×26, 74×62 and 160×100, including 240
soldiers, and adds complete feature/optional-field cases and canvases up to 256.
It compares every tensor, ONNX logits/value/action, optionally the original PyTorch
checkpoint, and the actual Godot Dictionary/native boundary. It also creates a
different local ONNX policy and checks its label, value and selected action.
The report includes native encoding/inference and Godot call timings; those do
not include resolver/ObsEncoder work and are measurements, not timing assertions.

`tests/run_native_policy.gd` tests malformed replies, native/socket priority,
permanent HARD fallback, corrupt/missing model files, checkpoint settings and
accepted live resolver decisions. Existing socket regressions select their backend
explicitly. `tests/run_all.sh` includes the native controller checks, which also
work without a compiled extension unless `--require-native` is passed.

`.github/workflows/native-policy.yml` builds and tests all four desktop targets,
installs Godot 4.7 plus export templates, verifies parity, exports each game with
the `.onnx` and native dependencies, runs the exported game headlessly to verify
model loading from the pack, and uploads per-platform game ZIPs and parity reports.
`package.py` uses an isolated export project and keeps Python/training runs out of
the game. The workflow does not publish a release. macOS distribution signing and
notarization can be applied by the release owner to the resulting app.
