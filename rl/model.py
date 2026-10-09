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

from features import (CAND_DIM, CANVAS, FLAT_DIM, N_CHANNELS, F_KIND,
                      F_VEH_CRUSH, F_ADVANCE, F_SPACING, F_COUNTER_TANK, KIND_INDEX)

FMAP = 32
EMB = 256
RES_DILATIONS = (2, 4, 8, 16)
SPATIAL_LIMIT = 96  # keep Giant-board convolutions affordable on the Mac


def greedy_action(logits, cand, mask):
    """Choose stop/continue by policy mass, then the best action in that branch.

    A single end-turn competes with hundreds of individually similar moves. Flat
    argmax can end a turn at 1% stop probability; sampling during PPO would keep
    acting 99% of the time. Preserve deliberate passes when stopping has >=50%
    of the mass, including the case where no other legal action exists.
    """
    stop = mask & (cand[..., F_KIND + KIND_INDEX["end"]] > .5)
    act = mask & ~stop
    stop_scores = logits.masked_fill(~stop, -torch.inf)
    act_scores = logits.masked_fill(~act, -torch.inf)
    ending = torch.logsumexp(stop_scores, 1) >= torch.logsumexp(act_scores, 1)
    return torch.where(ending, stop_scores.argmax(1), act_scores.argmax(1))


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
        # Dilated residual trunk (tactical env). Three 3x3 convs see a 7x7 window, which is
        # one rifle's reach at best: whether a cell is flanked, covered or cut off depends on
        # what stands 20 cells away. Dilations 2/4/8/16 widen the field to ~67 cells. Each
        # block's last conv starts at zero, so a block is the identity until it learns
        # something — an older checkpoint loads and plays exactly as it did.
        # Registered LAST so the old parameters keep their optimizer indices.
        self.res = nn.ModuleList()
        for d in RES_DILATIONS:
            blk = nn.Sequential(nn.Conv2d(fmap, fmap, 3, padding=d, dilation=d), nn.ReLU(),
                                nn.Conv2d(fmap, fmap, 3, padding=d, dilation=d))
            nn.init.zeros_(blk[2].weight)
            nn.init.zeros_(blk[2].bias)
            self.res.append(blk)

    def embed(self, grid: torch.Tensor, flat: torch.Tensor):
        if max(grid.shape[-2:]) > SPATIAL_LIMIT:
            grid = F.interpolate(grid, size=(SPATIAL_LIMIT, SPATIAL_LIMIT),
                                 mode="bilinear", align_corners=False)
        fm = self.conv(grid)
        for blk in self.res:
            fm = F.relu(fm + blk(fm))
        pooled = self.pool(fm).flatten(1)                      # B, F*16
        s = self.state(torch.cat([pooled, self.flat(flat)], dim=1))
        return fm, s

    def scores(self, fm, s, cand, cells, mask, source_width=None):
        """cand: B,N,CAND_DIM; cells: B,N,2 (canvas index or -1); mask: B,N bool.

        Each candidate is scored from cat([its row, fm at the actor, fm at the target,
        the state embedding]). Two things keep that cheap without changing it: only the
        mask's real candidates go through the MLP (a minibatch pads every state to its
        widest one, ~4x the real count), and the state's share of the first layer is
        computed once per state, not copied into every candidate row."""
        B, N, _ = cand.shape
        b, k = mask.nonzero(as_tuple=True)                     # K real candidates
        c = cells[b, k]                                        # K, 2
        if source_width is not None and source_width != fm.shape[-1]:
            # Candidate indices refer to the full observation. Gather from the
            # corresponding cell after the large-map feature grid is compressed.
            valid = c >= 0
            x = (c.clamp(min=0) % source_width) * fm.shape[-1] // source_width
            y = (c.clamp(min=0) // source_width) * fm.shape[-2] // source_width
            c = (y * fm.shape[-1] + x).masked_fill(~valid, -1)
        flat_fm = fm.flatten(2).transpose(1, 2)                # B, 4096, F
        a = flat_fm[b, c[:, 0].clamp(min=0)] * (c[:, 0:1] >= 0)
        t = flat_fm[b, c[:, 1].clamp(min=0)] * (c[:, 1:2] >= 0)
        first = self.cand[0]
        d = cand.shape[2] + 2 * self.fmap                      # columns of the per-candidate part
        h = torch.cat([cand[b, k], a, t], dim=1) @ first.weight[:, :d].T
        h = h + (s @ first.weight[:, d:].T + first.bias)[b]
        out = self.cand[1:](h).squeeze(-1)
        # Fixed tactical priors remain active for older checkpoints whose newly
        # appended input weights are zero. The safety term sees visible vehicle
        # lanes; progress and spacing terms apply to Giant boards. PPO and live
        # play use these same logits.
        if cand.shape[2] >= F_VEH_CRUSH + 2:
            move = cand[b, k, F_KIND + KIND_INDEX["move"]] > .5
            risk_here = cand[b, k, F_VEH_CRUSH]
            risk_there = cand[b, k, F_VEH_CRUSH + 1]
            out = out + move.to(out.dtype) * (2.0 * (risk_here - risk_there) - 3.0 * risk_there)
            if cand.shape[2] >= F_SPACING + 1:
                # Large-board progress and dispersion start useful even with a
                # checkpoint that has only ever seen platoon-sized maps.
                out = out + move.to(out.dtype) * (cand[b, k, F_ADVANCE] +
                                                  .5 * cand[b, k, F_SPACING])
            if cand.shape[2] >= F_COUNTER_TANK + 1:
                # Give a clean shot at a visible tank a chance against hundreds
                # of near-identical movement candidates. A shot whose blast is
                # close to friendly infantry gets no fixed boost.
                out = out + 2.0 * cand[b, k, F_COUNTER_TANK]
        return torch.full((B, N), -1e9, dtype=out.dtype, device=out.device).index_put((b, k), out)

    def forward(self, grid, flat, cand, cells, mask):
        fm, s = self.embed(grid, flat)
        return self.scores(fm, s, cand, cells, mask, grid.shape[-1]), self.value(s).squeeze(-1)

    @torch.no_grad()
    def act(self, grid, flat, cand, cells, mask, greedy: bool = False):
        logits, value = self.forward(grid, flat, cand, cells, mask)
        logp = F.log_softmax(logits, dim=1)
        if greedy:
            action = greedy_action(logits, cand, mask)
        else:
            action = torch.multinomial(logp.exp(), 1).squeeze(1)
        return action, logp.gather(1, action.unsqueeze(1)).squeeze(1), value


def _grow_cand(w: torch.Tensor, want_in: int) -> torch.Tensor:
    """cand.0.weight (or its Adam moment) from a checkpoint with fewer candidate features:
    zero columns go at the END of the candidate-row block, before the feature-map and
    state columns, so old behaviour is unchanged and the new features start at no effect."""
    old_cand = CAND_DIM - (want_in - w.shape[1])
    pad = torch.zeros(w.shape[0], want_in - w.shape[1], dtype=w.dtype, device=w.device)
    return torch.cat([w[:, :old_cand], pad, w[:, old_cand:]], dim=1)


def _grow_in(w: torch.Tensor, want_in: int) -> torch.Tensor:
    """conv.0.weight (or its Adam moment) from a checkpoint with fewer grid channels: the
    new channels are appended, so their zero columns go at the end."""
    pad = torch.zeros(w.shape[0], want_in - w.shape[1], *w.shape[2:], dtype=w.dtype, device=w.device)
    return torch.cat([w, pad], dim=1)


GROWERS = {"cand.0.weight": _grow_cand, "conv.0.weight": _grow_in}


def load_compat(net: "PolicyNet", sd: dict, opt: torch.optim.Optimizer | None = None,
                opt_sd: dict | None = None) -> None:
    """load_state_dict that accepts checkpoints from before the network grew:
    - fewer candidate features (drone, tactical columns) -> zero columns in cand.0;
    - fewer grid channels (threat / fire-cover layers) -> zero columns in conv.0;
    - no residual trunk -> the freshly built blocks stay at identity.
    Training resumes from such a checkpoint instead of starting over; Adam's moments
    are grown the same way and the new parameters start with no optimizer state."""
    want_sd = net.state_dict()
    sd = dict(sd)
    grown = []
    for key, grow in GROWERS.items():
        if key in sd and sd[key].shape != want_sd[key].shape:
            sd[key] = grow(sd[key], want_sd[key].shape[1])
            grown.append(key)
    missing = [k for k in want_sd if k not in sd]
    unexpected = [k for k in sd if k not in want_sd]
    bad = [k for k in missing if not k.startswith("res.")] + unexpected
    if bad:
        raise RuntimeError(f"checkpoint does not fit this network: {bad[:6]}")
    for k in missing:
        sd[k] = want_sd[k]
    net.load_state_dict(sd)
    if opt is None or opt_sd is None:
        return
    names = [n for n, _ in net.named_parameters()]
    opt_sd = {"state": dict(opt_sd["state"]),
              "param_groups": [dict(g) for g in opt_sd["param_groups"]]}
    for key in grown:
        idx = names.index(key)
        st = opt_sd["state"].get(idx)
        if st is not None:
            st = dict(st)
            for m in ("exp_avg", "exp_avg_sq"):
                if m in st and st[m].shape != want_sd[key].shape:
                    st[m] = GROWERS[key](st[m], want_sd[key].shape[1])
            opt_sd["state"][idx] = st
    have = sum(len(g["params"]) for g in opt_sd["param_groups"])
    if have < len(names):
        # New parameters (the residual trunk) are registered last: give them the next
        # indices in the last group, with no Adam state yet.
        opt_sd["param_groups"][-1]["params"] = list(opt_sd["param_groups"][-1]["params"]) \
            + list(range(have, len(names)))
    opt.load_state_dict(opt_sd)


class OnnxWrapper(nn.Module):
    """Export shape: one state, N candidates -> (logits[N], value[]). Both heads (5.2)."""

    def __init__(self, net: PolicyNet):
        super().__init__()
        self.net = net

    def forward(self, grid, flat, cand, cells):
        mask = torch.ones(cand.shape[:2], dtype=torch.bool, device=cand.device)
        logits, value = self.net(grid, flat, cand, cells, mask)
        return logits[0], value[0]
