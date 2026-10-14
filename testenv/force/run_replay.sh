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
# a replay listens on the UDP port it was recorded with: several at once collide ("Address already in
# use"), so each plays in a network namespace of its own (passwordless sudo on force)
sudo -n unshare -n -- bash -c "ip link set lo up && exec sudo -n -u $USER env HOME=$HOME \
	SPRING_DATADIR=$HOME/bar-sim/data:$HOME/bar-sim/engine timeout $LIMIT \
	$HOME/bar-sim/engine/spring-headless --write-dir $W $DEMO" > run.log 2>&1
code=$?
[ -s datalog.jsonl ] || cp LuaUI/Config/datalog.jsonl . 2>/dev/null # BAR 31614+: widgets write under LuaUI/Config
if [ -s datalog.jsonl ] && grep -q '"type":"end"' datalog.jsonl; then
	cp datalog.jsonl "$OUT/$id.jsonl"
	echo "$id: $(grep -c '"type":"micro"' datalog.jsonl) micro, $(grep -c '"type":"fight"' datalog.jsonl) fights | $(($(date +%s) - start))s"
else
	# why: the exit code (124 = the time limit) and the first line that matters; the log is kept in
	# $OUT/../replay-failed/<id>.log (the old report took the first "error" line: a harmless config warning)
	why=$(grep -m1 -E "Fatal|Dependent archive|outside the write paths|attempt to|Error in|segmentation|terminate" run.log | cut -c1-160)
	mkdir -p "$OUT/../replay-failed"
	cp run.log "$OUT/../replay-failed/$id.log"
	echo "$id: no data (exit $code${why:+: $why})"
fi
rm -rf "$W"
