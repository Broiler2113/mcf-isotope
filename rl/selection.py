"""Promotion uses independent map/seed PAIRS, not correlated individual games."""
import math
from collections import defaultdict


def promotion_decision(rows, max_stall=0.05, confidence=0.95):
    pairs = defaultdict(list)
    for row in rows:
        key = (row["map"], row["seed"])
        pairs[key].append(row)
    complete = []
    for group in pairs.values():
        if len(group) != 2 or {r["side"] for r in group} != {0, 1}:
            return dict(promote=False, reason="incomplete side pairs")
        complete.append(sum(1 if r["result"] == "win" else 0 if r["result"] == "loss" else .5
                            for r in group) / 2)
    n = len(complete)
    if n < 20:
        return dict(promote=False, reason="at least 20 independent side pairs required", pairs=n)
    score = sum(complete) / n
    # Hoeffding bound allows draws and correlation WITHIN each paired scenario.
    # It is intentionally conservative: a small noisy test cannot publish a model.
    radius = math.sqrt(math.log(1 / (1 - confidence)) / (2 * n))
    lower = max(0.0, score - radius)
    stalls = sum(r["result"] == "draw_steps" for r in rows) / len(rows)
    illegal = sum(r.get("illegal") or 0 for r in rows)
    passed = lower > .5 and stalls <= max_stall and illegal == 0
    return dict(promote=passed, score=score, lower_bound=lower, confidence=confidence,
                pairs=n, games=len(rows), stall_rate=stalls, illegal=illegal,
                reason="passed" if passed else "strength, stalled-game, or legality gate failed")
