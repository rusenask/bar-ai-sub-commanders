#!/usr/bin/env python3
"""A sequential A/B (or A/B/C...) test on the Lightning sandboxes: a baseline against one or more
challengers, in rounds of paired games, stopping each challenger as soon as its score verdict is decided.
Fewer games per decision than fixed 24-pair batches, and several versions at once.

Each challenger plays its own interleaved batch against the baseline (testenv/sandbox/batch.py
--widgets A --widgets-b B); round k fills in games of that batch (--only, --into), the sandboxes split
between the challengers still running. After each round the paired score verdict
(gamereport -compare) at the round's level decides: better or worse stops the challenger; otherwise it
plays on, up to --max-rounds. Interim rounds use a 99% interval, the last one 95%: looking several times
at a 95% interval would call too many changes better by chance (with 4 looks the overall false-positive
rate stays near 6%).

usage: uvx --with lightning-sdk python scripts/seqtest.py --label fb-v5 --baseline /tmp/arm-a/Widgets \\
         --arms /tmp/arm-b/Widgets [/tmp/arm-c/Widgets ...] [--side Legion --enemy-side Armada --opponent medium]
         [--round-pairs 8] [--max-rounds 4] [--sandboxes 12]
"""
import argparse
import json
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCORE = "score"


def verdict(batch, level):
    """The paired score verdict of a challenger's batch at an interval level: (verdict, diff, lo, hi, pairs)."""
    a, b = f"{batch}-A", f"{batch}-B"
    if not Path(a).is_dir() or not Path(b).is_dir():
        return "no games", 0, 0, 0, 0
    gr = [str(ROOT / "bin/gamereport")] if (ROOT / "bin/gamereport").exists() else ["go", "run", "./cmd/gamereport"]
    out = subprocess.run(gr + ["-json", "-compare", "-confidence", str(level), a, b], cwd=ROOT, capture_output=True, text=True)
    try:
        rows = next(iter(json.loads(out.stdout)["verdicts"].values()))
    except Exception:
        return "no verdict", 0, 0, 0, 0
    for r in rows:
        if r["metric"].startswith(SCORE):
            return r["verdict"], r["arm"] - r["base"], r["lo"], r["hi"], min(r["nBase"], r["nArm"])
    return "no verdict", 0, 0, 0, 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--baseline", required=True, help="arm A's Widgets dir")
    ap.add_argument("--arms", nargs="+", required=True, help="challengers' Widgets dirs")
    ap.add_argument("--side", default="Legion")
    ap.add_argument("--enemy-side", default="Armada")
    ap.add_argument("--opponent", default="medium")
    ap.add_argument("--round-pairs", type=int, default=8)
    ap.add_argument("--max-rounds", type=int, default=4)
    ap.add_argument("--sandboxes", type=int, default=12)
    ap.add_argument("--instance", default="cpu-16")
    ap.add_argument("--interim", type=float, default=0.99)
    ap.add_argument("--final", type=float, default=0.95)
    args = ap.parse_args()
    total = 2 * args.round_pairs * args.max_rounds
    names = [chr(ord("b") + i) for i in range(len(args.arms))]
    state = {n: {"widgets": w, "batch": None, "done": False, "result": None} for n, w in zip(names, args.arms)}
    for rnd in range(1, args.max_rounds + 1):
        active = [n for n in names if not state[n]["done"]]
        if not active:
            break
        level = args.final if rnd == args.max_rounds else args.interim
        lo, hi = 2 * args.round_pairs * (rnd - 1) + 1, 2 * args.round_pairs * rnd
        per = max(1, args.sandboxes // len(active))
        print(f"round {rnd}/{args.max_rounds}: games {lo}-{hi} for {', '.join(active)} ({per} sandboxes each), "
              f"verdicts at {level:.0%}", flush=True)

        def run(n):
            s = state[n]
            cmd = ["uvx", "--with", "lightning-sdk", "python", "testenv/sandbox/batch.py", str(total), "--only", f"{lo}-{hi}",
                   "--side", args.side, "--enemy-side", args.enemy_side, "--opponent", args.opponent,
                   "--sandboxes", str(min(per, args.round_pairs)), "--instance", args.instance,
                   "--parallel", str(max(1, 2 * args.round_pairs // min(per, args.round_pairs))),
                   "--widgets", args.baseline, "--widgets-b", s["widgets"], "--label", f"seq-{args.label}-{n}"]
            if s["batch"]:
                cmd += ["--into", s["batch"]]
            p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env={**__import__("os").environ, "BAR_TRACK": "0"})
            m = re.search(r"report: (\S+)/report\.md", p.stdout)
            if m and not s["batch"]:
                s["batch"] = m.group(1)
            if p.returncode != 0 and not m:
                print(f"  {n}: batch failed: {(p.stderr or p.stdout)[-400:]}", flush=True)

        threads = [threading.Thread(target=run, args=(n,)) for n in active]
        for t in threads:
            t.start()
            time.sleep(5)
        for t in threads:
            t.join()
        for n in active:
            s = state[n]
            if not s["batch"]:
                continue
            v, d, l, h, pairs = verdict(s["batch"], level)
            s["result"] = (v, d, l, h, pairs, level)
            print(f"  {n} ({s['widgets']}): {pairs} pairs, score {d:+.3f} [{l:+.3f}, {h:+.3f}] at {level:.0%}: {v}", flush=True)
            if v in ("better", "worse"):
                s["done"] = True
    print("\nresult:")
    for n in names:
        s = state[n]
        r = s["result"]
        if r:
            v, d, l, h, pairs, level = r
            print(f"  {n} {s['widgets']}: {v} after {pairs} pairs: {d:+.3f} [{l:+.3f}, {h:+.3f}] ({level:.0%}); batch {s['batch']}")
        if s["batch"]:
            subprocess.run(["uv", "run", "--quiet", "--with", "litlogger", "python", "scripts/track.py", s["batch"],
                            "--name", f"bar-seq-{args.label}-{n}"], cwd=ROOT)


if __name__ == "__main__":
    sys.exit(main())
