#!/usr/bin/env python
"""Serve a checkpoint's policy to the running game (train.py play, LearnedController.gd).

JSON lines over TCP on 127.0.0.1: request {"obs": ..., "legal": [...]} -> {"action": k}.
One request at a time; greedy by default (`--sample` draws from the policy instead).
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import torch_compat  # noqa: F401,E402
import torch  # noqa: E402

from model import PolicyNet  # noqa: E402
from train import choose, encode  # noqa: E402


def main():
    p = argparse.ArgumentParser()
    p.add_argument("checkpoint")
    p.add_argument("--port", type=int, default=7791)
    p.add_argument("--sample", action="store_true")
    a = p.parse_args()
    ck = torch.load(a.checkpoint, map_location="cpu", weights_only=False)
    net = PolicyNet()
    net.load_state_dict(ck["model"])
    net.eval()
    torch.set_num_threads(max(1, os.cpu_count() // 2))
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", a.port))
    srv.listen(1)
    print(f"[policy] {a.checkpoint} (step {ck.get('global_step')}) on 127.0.0.1:{a.port}", flush=True)
    while True:
        conn, _ = srv.accept()
        f = conn.makefile("rwb")
        try:
            for raw in f:
                req = json.loads(raw)
                enc = [encode({"obs": req["obs"], "legal": req["legal"]})]
                act, _, val = choose(net, enc, "cpu", greedy=not a.sample)
                f.write((json.dumps({"action": int(act[0]), "value": float(val[0])}) + "\n").encode())
                f.flush()
        except (ConnectionError, ValueError, KeyError) as e:
            print(f"[policy] connection ended: {e}", flush=True)
        finally:
            conn.close()


if __name__ == "__main__":
    main()
