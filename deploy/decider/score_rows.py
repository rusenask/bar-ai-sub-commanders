"""Scores kev.benchmark rows.json files on the yes/no questions, with the same metrics as baselines.py.

usage: python score_rows.py <task> <rows.json> [rows.json ...]
"""

import json
import sys

import numpy as np
from sklearn.metrics import roc_auc_score


def yes_probability(row):
    keys = [str(k).lower() for k in row["keys"]]
    i = keys.index("true") if "true" in keys else (keys.index("yes") if "yes" in keys else 1)
    return row["p"][i], 1 if row["label"] == i else 0


def main():
    task = sys.argv[1]
    for path in sys.argv[2:]:
        data = json.load(open(path))
        rows = data["rows"] if isinstance(data, dict) else data
        rows = [r for r in rows if r["type"] == "noul"]
        if not rows:
            print(task, path, "no yes/no rows")
            continue
        p, y = map(np.array, zip(*(yes_probability(r) for r in rows)))
        out = {"n": len(y), "yesRate": round(float(y.mean()), 3), "accuracy": round(float(((p >= 0.5) == y).mean()), 3),
               "brier": round(float(((p - y) ** 2).mean()), 4)}
        if 0 < y.sum() < len(y):
            out["auc"] = round(float(roc_auc_score(y, p)), 3)
        print(f"{task:7s} {path:45s} {out}")


if __name__ == "__main__":
    main()
