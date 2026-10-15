# Baseline policy

`baseline.onnx` was exported from the latest locally available trained checkpoint:
`rl/runs/soak-1/latest.pt`, update 253, global step 129,538. It uses round cap 10
and no actor/candidate cap. This is a trained baseline, not a claim about playing
strength on every map or game mode.

The ONNX metadata includes the exact source checkpoint SHA-256 and the label
`soak-1 · update 253 · step 129,538`. The checkpoint remains in the ignored training
run directory; the self-contained ONNX model is the release asset.

Build, model override, parity and desktop packaging instructions are in
[native/policy/README.md](../../native/policy/README.md).
