#!/usr/bin/env python3
"""Non-gating timing comparison. Only compare matching machines and workloads.

Usage: python3 tests/bench/compare_timings.py BASELINE.json CURRENT.json
Exit 0 includes timing warnings; exit 2 means the reports cannot be compared.
"""
import argparse
import json
import statistics


def compare(before, after, ratio=1.5, floor_ms=20.0):
    if before["machine"] != after["machine"]:
        raise ValueError("Different machine, Godot version or renderer; collect a fresh local baseline.")
    warnings = []
    common = before["scenes"].keys() & after["scenes"].keys()
    if not common:
        raise ValueError("No shared scenes.")
    for name in sorted(common):
        old, new = before["scenes"][name], after["scenes"][name]
        if old["config"] != new["config"]:
            raise ValueError(f"{name}: scene configuration differs.")
        signatures = {run["sig"] for report in (old, new) for run in report["runs"]}
        if len(signatures) != 1:
            raise ValueError(f"{name}: behavior differs; timings are not the same workload.")
        for metric in sorted(old["runs"][0]):
            if not metric.startswith("t_"):
                continue
            a = statistics.median(run[metric] for run in old["runs"])
            b = statistics.median(run[metric] for run in new["runs"])
            if b - a >= floor_ms and b > a * ratio:
                warnings.append(f"{name} {metric}: {a:.1f} -> {b:.1f} ms ({b / a:.2f}x)" if a else
                                f"{name} {metric}: 0 -> {b:.1f} ms")
    return warnings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline")
    parser.add_argument("current")
    parser.add_argument("--ratio", type=float, default=1.5)
    parser.add_argument("--floor-ms", type=float, default=20)
    args = parser.parse_args()
    try:
        with open(args.baseline) as f:
            before = json.load(f)
        with open(args.current) as f:
            after = json.load(f)
        warnings = compare(before, after, args.ratio, args.floor_ms)
    except (ValueError, KeyError, OSError) as exc:
        parser.exit(2, f"Cannot compare: {exc}\n")
    for warning in warnings:
        print("TIMING WARNING: " + warning)
    print(f"{len(warnings)} timing warning(s); informational, not a pass/fail gate.")


if __name__ == "__main__":
    main()
