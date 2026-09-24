#!/usr/bin/env python
"""Fill in the fields the replay gallery filters on, for replays recorded before it did.

    python rl/tools/backfill_replay_meta.py [--runs rl/runs] [--apply]

Every replay carries a `.mcfr.json` sidecar, and the dashboard reads `result` from it to
put a replay in the win / draw / loss bucket. Sidecars written before this tool existed
have `result` but not `by` — whether the game ended by rout or on the head count at the
round cap — and not `update` or `game`. Those three are all recoverable: `eval_games.jsonl`
carries one row per evaluated game with exactly that information, and the replay's own
step + opponent + game number identify its row.

Runs a dry pass by default and prints what it would change; `--apply` writes. A sidecar
that already has a field keeps it — this only adds what is missing, so re-running is
harmless and it will never contradict what the trainer recorded at the time.
"""
from __future__ import annotations

import argparse
import glob
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.join(os.path.dirname(HERE), "runs")

# Fields worth recovering, in the order a reader would want them.
WANTED = ("result", "by", "update", "game", "value_diff", "rounds")


def eval_rows(branch_dir: str) -> dict[tuple[int, str, int], dict]:
    """(step, opponent, game) -> the row that evaluation wrote for it."""
    out: dict[tuple[int, str, int], dict] = {}
    path = os.path.join(branch_dir, "eval_games.jsonl")
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue      # a row half-written when a run was killed
                out[(int(r.get("step", -1)), str(r.get("opponent", "")),
                     int(r.get("game", -1)))] = r
    except OSError:
        pass
    return out


def parse_name(path: str) -> tuple[str, int, str]:
    """(opponent, game, result) out of `[<step>_]vs_<opp>_<game>_<result>.mcfr`."""
    parts = os.path.basename(path)[: -len(".mcfr")].split("_")
    if "vs" in parts:
        parts = parts[parts.index("vs"):]          # drop the step prefix wins carry
    opponent = parts[1] if len(parts) > 1 else ""
    try:
        game = int(parts[2])
    except (IndexError, ValueError):
        game = -1
    result = "_".join(parts[3:]) if len(parts) > 3 else ""
    return opponent, game, result


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--runs", default=RUNS)
    p.add_argument("--apply", action="store_true", help="write; otherwise only report")
    a = p.parse_args()

    changed = missing = total = 0
    per_branch: dict[str, dict[str, int]] = {}
    for path in sorted(glob.glob(os.path.join(a.runs, "*", "replays", "*", "*.mcfr"))):
        total += 1
        branch_dir = os.path.dirname(os.path.dirname(os.path.dirname(path)))
        branch = os.path.basename(branch_dir)
        rows = per_branch.setdefault(branch, {})
        if "_rows" not in rows:
            rows["_rows"] = eval_rows(branch_dir)          # read each jsonl once
        table = rows["_rows"]

        side = path + ".json"
        try:
            with open(side) as f:
                meta = json.load(f)
        except (OSError, json.JSONDecodeError):
            meta = {}

        opponent, game, name_result = parse_name(path)
        meta.setdefault("branch", branch)
        meta.setdefault("opponent", opponent)
        meta.setdefault("game", game)
        if name_result:
            meta.setdefault("result", name_result)

        row = table.get((int(meta.get("step", -1)), str(meta.get("opponent", "")),
                         int(meta.get("game", -1))))
        before = dict(meta)
        if row:
            for k in WANTED:
                if k in row and meta.get(k) in (None, ""):
                    meta[k] = row[k]
        else:
            missing += 1

        # `by` is the one field with no fallback: it only ever existed in eval_games.jsonl.
        # Leave it absent rather than guessing, so the column reads blank instead of wrong.
        if meta != before:
            changed += 1
            note = "" if row else "   (no eval_games row; filled from the file name only)"
            print(f"{'write' if a.apply else 'would write'} {os.path.relpath(path, a.runs)}"
                  f"  result={meta.get('result')} by={meta.get('by', '-') or '-'}{note}")
            if a.apply:
                with open(side, "w") as f:
                    json.dump(meta, f)

    print(f"\n{total} replays, {changed} sidecars {'updated' if a.apply else 'to update'}, "
          f"{missing} with no matching eval_games row")
    if not a.apply and changed:
        print("re-run with --apply to write")


if __name__ == "__main__":
    main()
