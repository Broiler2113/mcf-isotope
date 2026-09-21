"""Policy/value network (spec Section 3, 4, 5.2, Q6).

Structured action head: the game enumerates the legal intents (rl/LegalIntents.gd), the
network scores each candidate and samples from a softmax over them. Legality is
therefore structural - an illegal action is never in the list - which is what Section 4
asks masking to achieve. Each candidate is scored from its own feature row, the CNN
feature map gathered at the actor's and the target's cell (the "which unit, which
target" factors of a hierarchical head, read off the map), and the global state
embedding. The value head (kept for v2 search, 5.2) reads the state embedding.
"""
from __future__ import annotations

import torch_compat  # noqa: F401  (must precede any conv)
import torch
import torch.nn as nn
import torch.nn.functional as F

from features import CAND_DIM, CANVAS, FLAT_DIM, N_CHANNELS

FMAP = 32
EMB = 256


class PolicyNet(nn.Module):
    def __init__(self, fmap: int = FMAP, emb: int = EMB):
        super().__init__()
        self.fmap = fmap
        self.conv = nn.Sequential(
            nn.Conv2d(N_CHANNELS, fmap, 3, padding=1), nn.ReLU(),
            nn.Conv2d(fmap, fmap, 3, padding=1), nn.ReLU(),
            nn.Conv2d(fmap, fmap, 3, padding=1), nn.ReLU(),
        )
        self.pool = nn.AdaptiveAvgPool2d(4)
        self.flat = nn.Sequential(nn.Linear(FLAT_DIM, 64), nn.ReLU())
        self.state = nn.Sequential(nn.Linear(fmap * 16 + 64, emb), nn.ReLU())
        self.cand = nn.Sequential(
            nn.Linear(CAND_DIM + 2 * fmap + emb, 256), nn.ReLU(),
            nn.Linear(256, 128), nn.ReLU(),
            nn.Linear(128, 1),
        )
        self.value = nn.Sequential(nn.Linear(emb, 128), nn.ReLU(), nn.Linear(128, 1))

    def embed(self, grid: torch.Tensor, flat: torch.Tensor):
        fm = self.conv(grid)                                   # B, F, 64, 64
        pooled = self.pool(fm).flatten(1)                      # B, F*16
        s = self.state(torch.cat([pooled, self.flat(flat)], dim=1))
        return fm, s

    def scores(self, fm, s, cand, cells, mask):
        """cand: B,N,CAND_DIM; cells: B,N,2 (canvas index or -1); mask: B,N bool."""
        B, N, _ = cand.shape
        flat_fm = fm.flatten(2).transpose(1, 2)                # B, 4096, F
        idx = cells.clamp(min=0)
        a = torch.gather(flat_fm, 1, idx[..., 0:1].expand(B, N, self.fmap))
        t = torch.gather(flat_fm, 1, idx[..., 1:2].expand(B, N, self.fmap))
        a = a * (cells[..., 0:1] >= 0).float()
        t = t * (cells[..., 1:2] >= 0).float()
        x = torch.cat([cand, a, t, s.unsqueeze(1).expand(B, N, s.shape[1])], dim=2)
        logits = self.cand(x).squeeze(-1)
        return logits.masked_fill(~mask, -1e9)

    def forward(self, grid, flat, cand, cells, mask):
        fm, s = self.embed(grid, flat)
        return self.scores(fm, s, cand, cells, mask), self.value(s).squeeze(-1)

    @torch.no_grad()
    def act(self, grid, flat, cand, cells, mask, greedy: bool = False):
        logits, value = self.forward(grid, flat, cand, cells, mask)
        logp = F.log_softmax(logits, dim=1)
        if greedy:
            action = logits.argmax(dim=1)
        else:
            action = torch.multinomial(logp.exp(), 1).squeeze(1)
        return action, logp.gather(1, action.unsqueeze(1)).squeeze(1), value


class OnnxWrapper(nn.Module):
    """Export shape: one state, N candidates -> (logits[N], value[]). Both heads (5.2)."""

    def __init__(self, net: PolicyNet):
        super().__init__()
        self.net = net

    def forward(self, grid, flat, cand, cells):
        mask = torch.ones(cand.shape[:2], dtype=torch.bool, device=cand.device)
        logits, value = self.net(grid, flat, cand, cells, mask)
        return logits[0], value[0]
