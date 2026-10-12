#!/bin/bash
# Fine-tunes Kev-0.8B into our BAR decision models and scores them (design/decision-models.md).
# Runs on a GPU machine with the Kev repo at ~/kev (uv synced) and the data sets at ~/bar-sets
# (cmd/decidedata output).
#
#   train_bar.sh [version] [task ...]      e.g. train_bar.sh v1 fight unit turret
#
# Per task: fine-tune from jaredpalmer/kev-0.8b, score the fine-tune and the untouched Kev-0.8B on the test
# games, fit a temperature on the dev games, and leave the checkpoint in ~/kev/runs/bar-<task>-<version>.
set -euo pipefail
VERSION="${1:-v1}"
shift || true
TASKS=("$@")
[ $# -eq 0 ] && TASKS=(fight unit turret)
SETS="$HOME/bar-sets"
BASE=Qwen/Qwen3.5-0.8B-Base
BASE_REV=dc7cdfe2ee4154fa7e30f5b51ca41bfa40174e68
EPOCHS="${EPOCHS:-2}"
LR="${LR:-5e-5}"
cd "$HOME/kev"
for task in "${TASKS[@]}"; do
	run="runs/bar-$task-$VERSION"
	echo "== $task: training $run ($(wc -l <"$SETS/$task/train.jsonl") records)"
	uv run python -m kev.train --data "$SETS/$task/train.jsonl" --base "$BASE" --base_revision "$BASE_REV" \
		--init_from jaredpalmer/kev-0.8b --epochs "$EPOCHS" --lr "$LR" --batch 8 --accum 2 --dtype bf16 \
		--checkpointing 1 --device cuda --out "$run" 2>&1 | tail -n 5
	echo "== $task: scoring"
	uv run python -m kev.benchmark --run "$run" --data "$SETS/$task/dev.jsonl" --out "runs/eval-bar-$task-$VERSION-dev" >/dev/null 2>&1
	uv run python scripts/calibrate_checkpoint.py --run "$run" --rows "runs/eval-bar-$task-$VERSION-dev/rows.json" --allow-in-distribution 2>&1 | tail -n 3 || true
	uv run python -m kev.benchmark --run "$run" --data "$SETS/$task/test.jsonl" --out "runs/eval-bar-$task-$VERSION" >/dev/null 2>&1
	[ -d "runs/eval-bar-$task-base" ] || uv run python -m kev.benchmark --run jaredpalmer/kev-0.8b --data "$SETS/$task/test.jsonl" --out "runs/eval-bar-$task-base" >/dev/null 2>&1
done
for task in "${TASKS[@]}"; do
	uv run python "$HOME/bar-deploy/score_rows.py" "$task" "runs/eval-bar-$task-base/rows.json" "runs/eval-bar-$task-$VERSION/rows.json"
done
