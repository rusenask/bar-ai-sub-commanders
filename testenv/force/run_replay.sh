#!/bin/bash
# On the force host: plays one replay with the data logger and keeps its samples.
# usage: run_replay.sh <template dir> <demo.sdfz> <out dir> <wall-clock limit, seconds>
TPL="$1"
DEMO="$2"
OUT="$3"
LIMIT="$4"
id="$(basename "$DEMO" .sdfz)"
[ -s "$OUT/$id.jsonl" ] && exit 0
W="$HOME/bar-sim/replay-runs/$id"
rm -rf "$W"
cp -r "$TPL" "$W"
cd "$W" || exit 1
start=$(date +%s)
SPRING_DATADIR="$HOME/bar-sim/data:$HOME/bar-sim/engine" timeout "$LIMIT" \
	"$HOME/bar-sim/engine/spring-headless" --write-dir "$W" "$DEMO" > run.log 2>&1
if [ -s datalog.jsonl ] && grep -q '"type":"end"' datalog.jsonl; then
	cp datalog.jsonl "$OUT/$id.jsonl"
	echo "$id: $(grep -c '"type":"micro"' datalog.jsonl) micro, $(grep -c '"type":"fight"' datalog.jsonl) fights | $(($(date +%s) - start))s"
else
	echo "$id: no data ($(grep -m1 -iE 'error|missing|not found' run.log | cut -c1-140))"
fi
rm -rf "$W"
