#!/usr/bin/env python3
"""Tune doctrine numbers with Optuna on the Lightning sandboxes: a study over some of the rules the doctrine
marks tunable (D.tunable, `go run ./cmd/learn params`), one rule set per game. Each generation asks Optuna
for --games trials, writes them as overlays (g<i>.json, the format testenv/sandbox/run_games.sh applies),
plays them in one sandbox batch (batch.py --overlays), scores each game like internal/learn (win most,
earlier more; alive half; a loss by the time survived; the damage trade nudges each) and tells Optuna.
The study persists (~/bar-sim/optuna.db), so a run can be resumed or extended; the first generation also
plays the doctrine's defaults as a reference. Progress goes to Lightning's experiment tracker.

Optuna picks the values; which rules matter is still our call (--params: a handful, not all 27).
The best set is a candidate, not a verdict: bake it into an arm and A/B it (scripts/seqtest.py).

usage: uvx --with optuna --with lightning-sdk --with litlogger python scripts/tune.py --key fb-legion \\
         --params firebase_step,firebase_spacing --games 24 --generations 4 \\
         [--side Legion --enemy-side Armada --opponent medium] [--sampler tpe|cmaes] [--widgets /tmp/arm/Widgets]
"""
import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import optuna

ROOT = Path(__file__).resolve().parent.parent
STORE = os.path.expanduser(os.environ.get("BAR_OPTUNA_DB", "~/bar-sim/optuna.db"))


def score(result, minutes, dealt_taken, limit=60.0):
    """internal/learn.Score."""
    clamp = lambda v, lo, hi: max(lo, min(hi, v))
    trade = clamp(math.log2(dealt_taken), -1, 1) if dealt_taken and dealt_taken > 0 else 0.0
    if result == "WIN":
        return 1 + 0.2 * clamp(1 - minutes / limit, 0, 1)
    if result == "TIMEOUT":
        return 0.5 + 0.15 * trade
    return 0.3 * clamp(minutes / limit, 0, 1) + 0.05 * trade


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", required=True, help="the study's name (a matchup and what's tuned)")
    ap.add_argument("--params", required=True, help="comma-separated tunable rules to search")
    ap.add_argument("--games", type=int, default=24)
    ap.add_argument("--generations", type=int, default=4)
    ap.add_argument("--side", default="Legion")
    ap.add_argument("--enemy-side", default="Armada")
    ap.add_argument("--opponent", default="medium")
    ap.add_argument("--minutes", type=int, default=60)
    ap.add_argument("--sampler", default="tpe", choices=["tpe", "cmaes"])
    ap.add_argument("--widgets", default="", help="the widgets the trials play with (default: the working tree)")
    ap.add_argument("--sandboxes", type=int, default=12)
    args = ap.parse_args()

    allp = {p["name"]: p for p in json.loads(subprocess.run(["go", "run", "./cmd/learn", "params"], cwd=ROOT, capture_output=True,
                                                                text=True, check=True).stdout)}
    names = [n.strip() for n in args.params.split(",") if n.strip()]
    missing = [n for n in names if n not in allp]
    if missing:
        sys.exit(f"not tunable: {missing}; tunable: {', '.join(sorted(allp))}")
    defaults = {n: p["default"] for n, p in allp.items()}

    os.makedirs(os.path.dirname(STORE), exist_ok=True)
    sampler = (optuna.samplers.TPESampler(multivariate=True, constant_liar=True, seed=7) if args.sampler == "tpe"
               else optuna.samplers.CmaEsSampler(seed=7, x0={n: defaults[n] for n in names}))
    study = optuna.create_study(study_name=args.key, storage=f"sqlite:///{STORE}", direction="maximize", sampler=sampler, load_if_exists=True)
    if not study.trials:
        study.enqueue_trial({n: defaults[n] for n in names})  # the doctrine as it is: the reference

    import litlogger
    exp = litlogger.init(name=f"bar-tune-{args.key}", teamspace=os.environ.get("BAR_TEAMSPACE", "lightning-ai/agents-teamspace"),
                         metadata={"params": ",".join(names), "side": args.side, "enemy": args.enemy_side, "opponent": args.opponent,
                                   "sampler": args.sampler, "widgets": args.widgets or "working tree"}, print_url=True, verbose=False)
    start_gen = len({t.user_attrs.get("generation") for t in study.trials if "generation" in t.user_attrs})
    for gen in range(start_gen + 1, start_gen + args.generations + 1):
        trials = [study.ask() for _ in range(args.games)]
        odir = Path(tempfile.mkdtemp(prefix=f"tune-{args.key}-g{gen}-"))
        for i, t in enumerate(trials, 1):
            rules = dict(defaults)
            for n in names:
                p = allp[n]
                rules[n] = t.suggest_int(n, int(p["min"]), int(p["max"])) if p.get("int") else t.suggest_float(n, p["min"], p["max"])
            t.set_user_attr("generation", gen)
            (odir / f"g{i}.json").write_text(json.dumps({"key": args.key, "generation": gen, "rules": rules}))
        cmd = ["uvx", "--with", "lightning-sdk", "python", "testenv/sandbox/batch.py", str(args.games), "--side", args.side,
               "--enemy-side", args.enemy_side, "--opponent", args.opponent, "--minutes", str(args.minutes),
               "--sandboxes", str(args.sandboxes), "--instance", "cpu-16", "--parallel", str(max(1, -(-args.games // args.sandboxes))),
               "--overlays", str(odir), "--label", f"tune-{args.key}-g{gen}"]
        if args.widgets:
            cmd += ["--widgets", args.widgets]
        p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env={**os.environ, "BAR_TRACK": "0"})
        m = re.search(r"report: (\S+)/report\.md", p.stdout)
        if not m:
            print(p.stdout[-2000:], p.stderr[-2000:])
            for t in trials:
                study.tell(t, state=optuna.trial.TrialState.FAIL)
            continue
        batch = m.group(1)
        gr = [str(ROOT / "bin/gamereport")] if (ROOT / "bin/gamereport").exists() else ["go", "run", "./cmd/gamereport"]
        games = {str(g["game"]): g for g in json.loads(subprocess.run(gr + ["-json", batch], cwd=ROOT, capture_output=True, text=True).stdout).get("games", [])}
        scores = []
        for i, t in enumerate(trials, 1):
            g = games.get(str(i))
            if not g:
                study.tell(t, state=optuna.trial.TrialState.FAIL)
                continue
            s = score(g["result"], g["minutes"], g.get("dealtTaken") or 0, args.minutes)
            scores.append(s)
            study.tell(t, s)
        best = study.best_trial
        mean = sum(scores) / len(scores) if scores else 0
        print(f"generation {gen}: {len(scores)}/{len(trials)} games, mean score {mean:.3f}; best so far {best.value:.3f} "
              f"(trial {best.number}): {best.params}", flush=True)
        exp["mean_score"].append(mean, step=gen)
        exp["best_score"].append(best.value, step=gen)
        for n, v in best.params.items():
            exp[f"best/{n}"].append(float(v), step=gen)
    # a single game is noisy: the best region, not the best trial, is what to try next. Report the top 5
    done = sorted([t for t in study.trials if t.value is not None], key=lambda t: -t.value)[:5]
    print("\ntop trials:")
    for t in done:
        print(f"  {t.value:.3f}  {t.params}")
    try:
        imp = optuna.importance.get_param_importances(study)
        print("importance:", {k: round(v, 3) for k, v in imp.items()})
    except Exception:
        pass
    exp.finalize("completed", print_summary=False)


if __name__ == "__main__":
    sys.exit(main())
