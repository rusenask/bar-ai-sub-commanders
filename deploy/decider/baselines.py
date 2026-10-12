"""Baselines for our decision models (design/decision-models.md), on the same splits as the Kev fine-tunes.

usage: python baselines.py <sets dir> [task ...]

For each task reads <task>/{train,test}.feat.jsonl (from cmd/decidedata) and reports, on the test split:
  - base rate: always predict the training yes-rate
  - rules: what the widget does today (fight: our value + turrets vs theirs; unit/turret: no rule, base rate)
  - logistic regression and gradient-boosted trees on the raw features
Accuracy, Brier score and ROC AUC; writes <sets>/baselines.json.
"""

import json
import math
import sys
from pathlib import Path

import numpy as np
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.feature_extraction import DictVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler


def load(path):
    rows = [json.loads(line) for line in open(path)]
    return [r["features"] for r in rows], np.array([1 if r["label"] else 0 for r in rows])


def scores(y, p):
    p = np.clip(p, 1e-6, 1 - 1e-6)
    out = {
        "n": int(len(y)),
        "yesRate": round(float(y.mean()), 3),
        "accuracy": round(float(((p >= 0.5) == y).mean()), 3),
        "brier": round(float(((p - y) ** 2).mean()), 4),
    }
    if 0 < y.sum() < len(y):
        out["auc"] = round(float(roc_auc_score(y, p)), 3)
    return out


def rule_fight(features):
    # the widget's current rule: engage when our value (turrets count half) is at least the enemy's
    ours = features.get("own.value", 0) + 0.5 * features.get("ownTurrets.value", 0)
    theirs = features.get("enemy.value", 0) + features.get("enemyTurrets.value", 0)
    return 1 / (1 + math.exp(-2 * math.log((ours + 1) / (theirs + 1))))


def main():
    root = Path(sys.argv[1])
    tasks = sys.argv[2:] or ["fight", "unit", "turret"]
    report = {}
    for task in tasks:
        train_f, y_train = load(root / task / "train.feat.jsonl")
        test_f, y_test = load(root / task / "test.feat.jsonl")
        if len(y_test) == 0 or len(set(y_train)) < 2:
            print(task, "not enough data")
            continue
        vec = DictVectorizer(sparse=False)
        x_train = vec.fit_transform(train_f)
        x_test = vec.transform(test_f)
        r = {"base rate": scores(y_test, np.full(len(y_test), y_train.mean()))}
        if task == "fight":
            r["rules"] = scores(y_test, np.array([rule_fight(f) for f in test_f]))
        logit = make_pipeline(StandardScaler(), LogisticRegression(max_iter=2000, C=0.5))
        logit.fit(x_train, y_train)
        r["logistic regression"] = scores(y_test, logit.predict_proba(x_test)[:, 1])
        gbt = HistGradientBoostingClassifier(max_iter=300, learning_rate=0.05, max_leaf_nodes=31)
        gbt.fit(x_train, y_train)
        r["gradient boosting"] = scores(y_test, gbt.predict_proba(x_test)[:, 1])
        report[task] = r
        print(task)
        for name, s in r.items():
            print(f"  {name:22s} {s}")
    (root / "baselines.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
