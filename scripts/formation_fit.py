#!/usr/bin/env python3
"""What in a group's formation goes with a good trade, beyond strength: least squares of
log2((enemy lost + 50) / (our lost + 50)) on log2 strength ratio and the formation features of both sides
(data logger v9 fight samples). usage: formation_fit.py label=dir[:team] ..."""
import glob, json, math, sys
import numpy as np

FEATS = [
    ("log2 ratio", lambda f: math.log2(max(f["r"], 1 / 16))),
    ("our share able to shoot", lambda f: f["ownForm"]["inRange"]),
    ("our share exposed", lambda f: f["ownForm"]["exposed"]),
    ("their share able to shoot", lambda f: f["enemyForm"]["inRange"]),
    ("their share exposed", lambda f: f["enemyForm"]["exposed"]),
    ("our spread / sqrt(n) /100", lambda f: f["ownForm"]["spread"] / math.sqrt(f["ownForm"]["n"]) / 100),
    ("our log2 width/depth", lambda f: math.log2(max(f["ownForm"]["width"], 1) / max(f["ownForm"]["depth"], 1))),
    ("our approach", lambda f: f.get("ownApproach", 0)),
    ("their approach", lambda f: f.get("enemyApproach", 0)),
    ("our turrets (k metal)", lambda f: f["ownTurrets"]["value"] / 1000),
    ("their turrets (k metal)", lambda f: f["enemyTurrets"]["value"] / 1000),
]


def load(spec):
    label, path = spec.split("=", 1)
    team = None
    if ":" in path:
        path, t = path.rsplit(":", 1)
        team = int(t)
    rows = []
    for fn in glob.glob(path + "/*.jsonl"):
        for line in open(fn):
            if '"type":"fight"' not in line or '"ownForm"' not in line:
                continue
            f = json.loads(line)
            if not f.get("ownForm") or not f.get("enemyForm") or f["ownForm"]["n"] < 3 or f["enemyForm"]["n"] < 1:
                continue
            if team is not None and f.get("team") != team:
                continue
            f["r"] = (f["own"]["value"] + f["ownTurrets"]["value"]) / max(f["enemy"]["value"] + f["enemyTurrets"]["value"], 1)
            rows.append(f)
    return label, rows


def fit(label, rows):
    X = np.array([[g(f) for _, g in FEATS] for f in rows])
    y = np.array([math.log2((f["enemyLost"] + 50) / (f["ownLost"] + 50)) for f in rows])
    mu, sd = X.mean(0), X.std(0) + 1e-9
    Z = np.column_stack([np.ones(len(rows)), (X - mu) / sd])
    beta, *_ = np.linalg.lstsq(Z, y, rcond=None)
    res = y - Z @ beta
    r2 = 1 - res.var() / y.var()
    # bootstrap the coefficients
    rng = np.random.default_rng(7)
    bs = []
    for _ in range(300):
        i = rng.integers(0, len(rows), len(rows))
        b, *_ = np.linalg.lstsq(Z[i], y[i], rcond=None)
        bs.append(b)
    bs = np.array(bs)
    print(f"\n### {label}: {len(rows)} fights, mean log2 trade {y.mean():+.2f}, R^2 {r2:.2f}\n")
    print("| Feature | Mean | Effect of +1 sd on log2 trade [95%] |\n|---|---|---|")
    for k, (name, _) in enumerate(FEATS):
        lo, hi = np.percentile(bs[:, k + 1], [2.5, 97.5])
        star = " **" if lo > 0 or hi < 0 else ""
        print(f"| {name} | {mu[k]:.2f} | {beta[k + 1]:+.3f} [{lo:+.3f}, {hi:+.3f}]{star} |")


for spec in sys.argv[1:]:
    fit(*load(spec))
