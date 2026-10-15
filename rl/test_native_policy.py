"""Native encoder / ONNX parity on real Godot requests and full feature edge cases.

python rl/test_native_policy.py --probe .cache/native-policy/mcf_policy_probe
Only test/development tools need Python. Players use the GDExtension directly.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

import numpy as np
import onnxruntime as ort
import torch

import features as f
from model import PolicyNet, greedy_action, load_compat

ROOT = Path(__file__).resolve().parent.parent


def enriched(source):
    """Exercise every appended channel, component, action kind and optional field."""
    r = copy.deepcopy(source)
    o = r["obs"]
    size = o["w"] * o["h"]
    rng = np.random.default_rng(123)
    for key, limit in (("floor", 5), ("feat", 23), ("feat_own", 5), ("cover", 9),
                       ("fire", 2), ("corpse", 8), ("dirt", 4), ("fog", 3), ("veh", 2),
                       ("gas", 2), ("gas_warning", 2), ("artillery_warning", 2),
                       ("vcrush", 9), ("smoke", 2), ("wave_warning", 2), ("zone", 4),
                       ("threat", 80), ("fcover", 80), ("dthreat", 9), ("fnext", 80),
                       ("ereach", 80), ("lastseen", 101)):
        o[key] = rng.integers(0, limit, size).tolist()
    o.update(mode=2, pts=5, pts_enemy=11, pts_target=12, wave=6,
             waves_total=0, wave_pending=1, wave_left=17)
    unit = copy.deepcopy(o["units"][0])
    o["units"] = []
    for typ in range(f.N_UNIT_TYPES):
        u = unit | dict(type=typ, own=typ % 3, x=typ % o["w"], y=typ // o["w"],
                        max_ap=0 if typ == 0 else 3, ap=typ % 5, item=typ % 2,
                        held=typ % 2, corpses=typ % 3, civ=typ % 2,
                        pending=typ, mc=typ * 2, aboard=0)
        o["units"].append(u)
    o["units"].append(unit | dict(x=-9999, y=-9999, aboard=1))
    # Overlapping and partly off-board hulls preserve Python's overwrite order.
    o["vehicles"] = [dict(id=100 + k, x=7 + k, y=8, w=3, h=3, own=k,
        type=k, fx=-1, fy=0, wrecked=k % 2, alive=1, crew=2, cap=0, ap=19,
        comps={comp: [j, 0 if j == 0 else 7] for j, comp in enumerate(f.VEH_COMPONENTS)
               if k != 2 or j % 2}) for k in range(3)]
    o["vehicles"].append(o["vehicles"][0] | dict(id=103, x=-1, y=-1))
    candidates = []
    for k, kind in enumerate(f.INTENT_KINDS):
        candidates.append(dict(i=dict(t=kind, s=(-1, 1, 3)[k % 3], av=k % 2,
                cm=f.VEH_COMPONENTS[k % 5], v=101, f=f.BUILD_FEATURES[k % 9]),
            at=k % f.N_ACTOR_TYPES, tt=k % f.N_UNIT_TYPES, ax=k % 7, ay=k % 5,
            tx=8, ty=9, lf=.123, vh=15, th=8.5, fc=2.75, cv=3, tn=11, er=2,
            rh=.75, hazard=[0, .1, 1, .2, -.5, 3], vc=[.125, .5], apc=k % 4))
    candidates += [dict(i=dict(t="unknown"), at=None, tt=None, ax=-1, ay=-1, tx=-1, ty=-1),
                   dict(i=dict(t="shoot", cm="tracks_l", v=101), ax=2, ay=2,
                        tx=9, ty=9), dict(i=dict(t="end"), ax=-1, ay=-1, tx=-1, ty=-1)]
    r["legal"] = candidates
    return r


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--probe", type=Path, required=True)
    p.add_argument("--model", type=Path, default=ROOT / "assets/policy/baseline.onnx")
    p.add_argument("--checkpoint", type=Path)
    p.add_argument("--godot", default="godot")
    p.add_argument("--requests", type=Path, help="Reuse JSONL snapshots instead of recording them")
    p.add_argument("--report", type=Path)
    p.add_argument("--extension", action="store_true", help="Also verify the real Godot native boundary")
    a = p.parse_args()
    torch.set_num_threads(2)
    # Catch layout drift even if the representative fixtures leave a column zero.
    header = (ROOT / "native/policy/src/layout.hpp").read_text()
    for name, value in vars(f).items():
        if name.isupper() and isinstance(value, int):
            assert re.search(rf"\b{name} = {value};", header), f"native ABI drift: {name}"
    for name in ("INTENT_KINDS", "VEH_COMPONENTS", "BUILD_FEATURES"):
        actual = re.search(rf"\b{name} = \{{(.*?)\}};", header).group(1)
        assert json.loads("[" + actual + "]") == getattr(f, name), name
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    session = ort.InferenceSession(str(a.model), options, providers=["CPUExecutionProvider"])
    net = None
    if a.checkpoint:
        ck = torch.load(a.checkpoint, map_location="cpu", weights_only=False)
        net = PolicyNet()
        load_compat(net, ck["model"])
        net.eval()
    with tempfile.TemporaryDirectory(prefix="mcf-policy-parity-") as tmp:
        tmp = Path(tmp)
        records = a.requests or tmp / "requests.jsonl"
        if not a.requests:
            env = os.environ | {"XDG_DATA_HOME": str(tmp), "XDG_CONFIG_HOME": str(tmp)}
            subprocess.run([a.godot, "--headless", "--path", str(ROOT), "--script",
                            "res://tests/record_policy_requests.gd", "--", str(records)],
                           env=env, check=True, timeout=180)
        real = [json.loads(line) for line in records.read_text().splitlines()]
        assert real and any(r["obs"]["w"] >= 100 for r in real)
        requests = real + [enriched(real[0]), enriched(next(r for r in real if r["obs"]["w"] >= 100))]
        minimal = copy.deepcopy(real[0])
        for key in ("threat", "fcover", "fnext", "ereach", "lastseen", "dthreat", "zone",
                    "gas", "gas_warning", "artillery_warning", "vcrush", "smoke", "wave_warning"):
            minimal["obs"].pop(key, None)
        minimal["legal"] = [dict(i=dict(t="end"), ax=-1, ay=-1, tx=-1, ty=-1)]
        requests.append(minimal)
        # Every spatial branch, including boards above the convolution cap.
        for side in (64, 80, 96, 112, 256):
            req = copy.deepcopy(minimal)
            old_size = req["obs"]["w"] * req["obs"]["h"]
            for key, value in list(req["obs"].items()):
                if isinstance(value, list) and len(value) == old_size:
                    req["obs"][key] = [0] * (side * side)
            req["obs"].update(w=side, h=side, units=[], vehicles=[])
            requests.append(req)
        for i, req in enumerate(requests):
            req["dump"] = str(tmp / str(i))
        proc = subprocess.run([str(a.probe.resolve()), str(a.model.resolve())],
                              input="".join(json.dumps(r) + "\n" for r in requests),
                              capture_output=True, text=True, check=True, timeout=180)
        answers = [json.loads(line) for line in proc.stdout.splitlines()]
        assert len(answers) == len(requests), proc.stderr
        benchmarks = []
        for i, (req, answer) in enumerate(zip(requests, answers)):
            assert "error" not in answer, answer
            o = req["obs"]
            canvas = max(64, ((max(o["w"], o["h"]) + 15) // 16) * 16)
            grid = f.grid_tensor(o, canvas)
            flat = f.flat_vector(o)
            cand, cells = f.candidate_rows(o, req["legal"], canvas)
            expected = dict(grid=grid[None], flat=flat[None], cand=cand[None], cells=cells[None])
            native = {}
            for key, value in expected.items():
                actual = np.fromfile(tmp / f"{i}.{key}", dtype=value.dtype).reshape(value.shape)
                # All one-hots/indices are exact; fractional features allow float32 rounding.
                if key == "cells":
                    np.testing.assert_array_equal(actual, value)
                else:
                    binary = (value == 0) | (value == 1)
                    np.testing.assert_array_equal(actual[binary], value[binary])
                np.testing.assert_allclose(actual, value, rtol=1e-7, atol=1e-7,
                                           err_msg=f"request {i}: {key}")
                native[key] = actual
            logits, value = session.run(None, expected)
            native_logits, native_value = session.run(None, native)
            np.testing.assert_array_equal(logits, native_logits)
            np.testing.assert_array_equal(value, native_value)
            np.testing.assert_allclose(answer["logits"], logits, atol=2e-5, rtol=2e-5)
            np.testing.assert_allclose(answer["value"], value, atol=2e-5, rtol=2e-5)
            action = greedy_action(torch.from_numpy(logits[None]), torch.from_numpy(cand[None]),
                                   torch.ones((1, len(cand)), dtype=torch.bool)).item()
            assert answer["action"] == action, (i, answer["action"], action)
            if net is not None:
                # train.encode stores grid/candidate values as Sparse float16.
                trained = {key: (z.astype(np.float16).astype(np.float32)
                                 if key in ("grid", "cand") else z)
                           for key, z in expected.items()}
                with torch.no_grad():
                    py_logits, py_value = net(*(torch.from_numpy(z) for z in trained.values()),
                                             torch.ones((1, len(cand)), dtype=torch.bool))
                np.testing.assert_allclose(py_logits.numpy()[0], logits, atol=2e-5, rtol=2e-5)
                np.testing.assert_allclose(py_value.numpy()[0], value, atol=2e-5, rtol=2e-5)
            benchmarks.append(dict(width=o["w"], height=o["h"], units=len(o["units"]),
                                   candidates=len(cand), encode_ms=answer["encode_ms"],
                                   infer_ms=answer["infer_ms"]))
        if a.extension:
            boundary_requests = tmp / "boundary.jsonl"
            boundary_answers = tmp / "boundary-answers.jsonl"
            boundary_requests.write_text("".join(json.dumps(r) + "\n" for r in requests))
            subprocess.run([a.godot, "--headless", "--path", str(ROOT), "--script",
                            "res://tests/run_native_policy_requests.gd", "--", str(a.model.resolve()),
                            str(boundary_requests), str(boundary_answers)],
                           env=os.environ | {"XDG_DATA_HOME": str(tmp)}, check=True, timeout=180)
            boundary = [json.loads(line) for line in boundary_answers.read_text().splitlines()]
            assert len(boundary) == len(answers)
            for i, (actual, expected_answer) in enumerate(zip(boundary, answers)):
                assert "error" not in actual, actual
                assert actual["action"] == expected_answer["action"], (i, actual, expected_answer)
                np.testing.assert_allclose(actual["value"], expected_answer["value"], atol=2e-5, rtol=2e-5)
                benchmarks[i]["godot_total_ms"] = actual["total_ms"]
            # A real local ONNX override with deliberately different policy/value
            # proves selection reaches the played model, as well as the lobby label.
            import onnx
            from onnx import TensorProto as T, helper as H
            override = tmp / "override.onnx"
            inputs = [H.make_tensor_value_info("grid", T.FLOAT, [1, f.N_CHANNELS, "h", "w"]),
                      H.make_tensor_value_info("flat", T.FLOAT, [1, f.FLAT_DIM]),
                      H.make_tensor_value_info("cand", T.FLOAT, [1, "n", f.CAND_DIM]),
                      H.make_tensor_value_info("cells", T.INT64, [1, "n", 2])]
            nodes = [H.make_node("Shape", ["cand"], ["shape"]),
                     H.make_node("Gather", ["shape", "one"], ["n"], axis=0),
                     H.make_node("ConstantOfShape", ["n"], ["zeros"], value=H.make_tensor("", T.FLOAT, [1], [-10.])),
                     H.make_node("ScatterElements", ["zeros", "zero", "score"], ["logits"], axis=0),
                     H.make_node("Identity", ["v"], ["value"])]
            constants = [H.make_tensor("one", T.INT64, [1], [1]), H.make_tensor("zero", T.INT64, [1], [0]),
                         H.make_tensor("score", T.FLOAT, [1], [100.]), H.make_tensor("v", T.FLOAT, [], [12.5])]
            graph = H.make_graph(nodes, "override", inputs,
                [H.make_tensor_value_info("logits", T.FLOAT, ["n"]), H.make_tensor_value_info("value", T.FLOAT, [])], constants)
            alternate = H.make_model(graph, opset_imports=[H.make_opsetid("", 17)], ir_version=9)
            label = "local override · update 999 · step 123"
            H.set_model_props(alternate, {"mcf.label": label, "mcf.round_cap": "27",
                                         "mcf.max_actors": "3", "mcf.max_candidates": "64"})
            onnx.save(alternate, override)
            subprocess.run([a.godot, "--headless", "--path", str(ROOT), "--script",
                            "res://tests/run_native_policy.gd", "--", "--require-native", "--expected-label=" + label],
                           env=os.environ | {"XDG_DATA_HOME": str(tmp), "MCF_RL_MODEL": str(override),
                                             "MCF_RL_MODEL_LABEL": ""}, check=True, timeout=90)
            subprocess.run([a.godot, "--headless", "--path", str(ROOT), "--script",
                            "res://tests/run_native_policy_requests.gd", "--", str(override),
                            str(boundary_requests), str(boundary_answers)],
                           env=os.environ | {"XDG_DATA_HOME": str(tmp)}, check=True, timeout=90)
            for line in boundary_answers.read_text().splitlines():
                answer = json.loads(line)
                assert answer["action"] == 0 and answer["value"] == 12.5, answer
        # A high individual stop logit loses to the sum of many continue logits.
        req = copy.deepcopy(minimal)
        req["legal"] += [dict(i=dict(t="move"), ax=0, ay=0, tx=1, ty=1)] * 20
        cases = []
        for scores, expected_action in (([1.] + [0.] * 20, 1), ([10.] + [0.] * 20, 0),
                                        ([0.] + [-1000.] * 20, 0), ([0.] * 21, 1)):
            cases.append(req | {"test_logits": scores})
        proc = subprocess.run([str(a.probe.resolve())], input="".join(json.dumps(r) + "\n" for r in cases),
                              capture_output=True, text=True, check=True, timeout=30)
        assert [json.loads(s)["test_action"] for s in proc.stdout.splitlines()] == [1, 0, 0, 1]
        report = dict(requests=len(requests), real_requests=len(real), tensor_parity=True,
                      onnx_parity=True, pytorch_parity=net is not None,
                      godot_boundary_parity=a.extension, benchmarks=benchmarks)
        if a.report:
            a.report.write_text(json.dumps(report, indent=2) + "\n")
        print(f"native policy: {len(requests)} requests, tensor/logit/value/action parity passed")
        for row in benchmarks:
            if row["units"] >= 100:
                print("giant:", json.dumps(row))


if __name__ == "__main__":
    main()
