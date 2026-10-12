"""System One server for the tree / linear models from baselines.py (design/decision-models.md).

The bridge sends, with every task request, {"task": ..., "flat": {question: {feature: value}}}; this server
answers each yes/no question with the probability from the task's model, so it can stand in for a Kev
model on any task route. Score questions (the fight outcome) get a spread derived from that probability.

usage: python serve_gbt.py --models dir [--kind gbt|logistic] [--port 8014]
"""

import argparse
import pickle
import time
from pathlib import Path

import uvicorn
from fastapi import FastAPI, HTTPException

ap = argparse.ArgumentParser()
ap.add_argument("--models", required=True)
ap.add_argument("--kind", default="gbt", choices=("gbt", "logistic"))
ap.add_argument("--host", default="0.0.0.0")
ap.add_argument("--port", type=int, default=8014)
args = ap.parse_args()

models = {p.stem: pickle.load(open(p, "rb")) for p in Path(args.models).glob("*.pkl")}
app = FastAPI()


@app.get("/health")
def health():
    return {"ok": True, "tasks": sorted(models), "kind": args.kind}


@app.post("/v1/systemone")
def answer(body: dict):
    start = time.perf_counter()
    task, flat, questions = body.get("task"), body.get("flat") or {}, body.get("questions") or {}
    m = models.get(task)
    if m is None:
        raise HTTPException(400, f"no model for task {task!r}")
    answers = {}
    for key, q in questions.items():
        feats = flat.get(key)
        if feats is None:
            raise HTTPException(400, f"no features for question {key!r}")
        p = float(m[args.kind].predict_proba(m["vectorizer"].transform([feats]))[0, 1])
        if q.get("type") == "noul":
            answers[key] = {"type": "noul", "noul": round(p, 4)}
        elif q.get("type") == "score":
            levels = q.get("criteria") or []
            n = len(levels)
            # put the mass around the level the probability points at
            centre = p * (n - 1)
            weights = [max(0.0, 1 - abs(i - centre)) + 0.05 for i in range(n)]
            total = sum(weights)
            probs = {str(i): round(w / total, 4) for i, w in enumerate(weights)}
            answers[key] = {"type": "score", "score": round(centre, 3), "probabilities": probs}
        else:
            raise HTTPException(400, f"{key}: only noul and score questions")
    return {"model": f"bar-{task}-{args.kind}", "answers": answers, "latency_ms": round((time.perf_counter() - start) * 1000, 1)}


uvicorn.run(app, host=args.host, port=args.port)
