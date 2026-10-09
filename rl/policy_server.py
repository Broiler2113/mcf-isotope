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
import threading
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import torch_compat  # noqa: F401,E402
import torch  # noqa: E402

from model import PolicyNet, load_compat  # noqa: E402
from train import choose, encode  # noqa: E402
from features import CANVAS  # noqa: E402


def answer(net, req: dict, sample: bool = False) -> dict:
    if req.get("cmd") == "ping":
        return {"ok": True, "protocol": 2}
    if not req.get("legal"):
        raise ValueError("policy request contains no legal actions")
    # Adaptive pooling makes the torch network spatially flexible. Keep every tile
    # and use the SAME stride for grid and candidate indices. Training stays 64x64.
    obs = req["obs"]
    canvas = max(CANVAS, int(obs["w"]), int(obs["h"]))
    enc = [encode(req, canvas=canvas)]
    act, _, val = choose(net, enc, "cpu", greedy=not sample)
    return {"action": int(act[0]), "value": float(val[0])}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("checkpoint")
    p.add_argument("--port", type=int, default=7791)
    p.add_argument("--sample", action="store_true")
    a = p.parse_args()
    ck = torch.load(a.checkpoint, map_location="cpu", weights_only=False)
    net = PolicyNet()
    load_compat(net, ck["model"])
    net.eval()
    torch.set_num_threads(max(1, min(4, (os.cpu_count() or 2) // 2)))
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", a.port))
    srv.listen(8)
    print(f"[policy] {a.checkpoint} (step {ck.get('global_step')}) on 127.0.0.1:{a.port}", flush=True)

    lock = threading.Lock()

    def serve(conn):
        """One client. Threaded because the server used to handle connections strictly one
        at a time: a second learned slot — two learned AI sides, or a reconnect while the
        old socket was still open — sat in the accept backlog and was never read. From the
        game's side that is a 30-second silence followed by a quiet fallback to the
        scripted AI, with nothing to say why. The net itself is shared, so inference is
        serialised under a lock; only the waiting is concurrent."""
        f = conn.makefile("rwb")
        try:
            for raw in f:
                try:
                    req = json.loads(raw)
                    with lock:
                        reply = answer(net, req, a.sample)
                except Exception as e:
                    traceback.print_exc()
                    reply = {"error": f"{type(e).__name__}: {e}"}
                f.write((json.dumps(reply) + "\n").encode())
                f.flush()
        except (ConnectionError, ValueError, KeyError) as e:
            print(f"[policy] connection ended: {e}", flush=True)
        finally:
            f.close()
            conn.close()

    while True:
        conn, _ = srv.accept()
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
