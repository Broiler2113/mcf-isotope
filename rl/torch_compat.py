"""Import before building any model.

torch 2.14 CPU wheels route Conv2d through oneDNN, whose JIT kernel dies with SIGFPE on
the AMD EPYC 7C13 this repo lives on (verified 2026-09-14: 72->32 conv at 64x64, any
thread count). The fallback im2col/GEMM path is correct and fast enough for smoke runs.
Set MCF_RL_MKLDNN=1 to keep oneDNN on (GPU workstation, or a CPU where it works).
"""
import os

import torch

if os.environ.get("MCF_RL_MKLDNN", "0") != "1":
    torch.backends.mkldnn.enabled = False
