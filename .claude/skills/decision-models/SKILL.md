---
name: decision-models
description: Train, evaluate, deploy and A/B test this repo's small decision models (Kev LoRA fine-tunes and gradient-boosting baselines for fight, unit, turret, produce, turretpick) - data collection, Lightning studio training, the force GPU host, routes. Use when working on internal/decider, cmd/decidedata or deploy/decider.
---

# Decision models

Design, results and the full reproduce section: `design/decision-models.md`. This is the short version.

## Data

```sh
testenv/collect.sh 30                     # BARbarian vs BARbarian, spectated with the data logger -> testenv/data/raw*
testenv/replays.sh                        # strong players' replays -> testenv/data/pro (pro-replays skill)
go run ./cmd/decidedata -in <dir> -out <sets>   # per task train/dev/test split by game, + .feat.jsonl for baselines
```

## Train (GPU)

- Lightning studio: `lightning studio start --name bar-decider-train --create --machine L40S` (H100/H200/A100
  are not available on the account); ssh host `bar-decider-train`. It auto-stops when idle: outputs persist.
- `deploy/decider/train_bar.sh` trains from `jaredpalmer/kev-0.8b`, calibrates on dev, benchmarks on test
  and evaluates the base model. Always check the base eval ran on the same test set.
- Baselines first: `deploy/decider/baselines.py` (logistic, gradient boosting). If GBT matches Kev, serve GBT
  (`serve_gbt.py`), it's simpler.

## Deploy and use

- `force` (100.108.100.25, RTX 4090): `deploy/decider/decider.sh start bar [ver]` serves fight :8011,
  unit :8012, turret :8013.
- The bridge routes per task: `DECIDER_ROUTES=fight=http://...:8011,...` in `.env`, then `make up`.

## Lessons (see docs/research/lessons.md)

- Offline AUC is not in-game strength: the fight model (AUC 0.81) made the army chase local wins and lose
  more games. Test every model in A/B batches (ab-test skill).
- Outcome labels can be gamed by the policy: "pays for itself" picked the cheapest units. Prefer imitation
  of strong players (produce / turretpick) or lookahead with an outcome model.
