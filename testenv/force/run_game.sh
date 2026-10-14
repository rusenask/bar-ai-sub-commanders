#!/bin/bash
# On the force host: plays game <i> of a batch with the headless engine, in its own write dir copied from
# the batch's template. usage: run_game.sh <batch dir> <i> <wall-clock limit, seconds>
# Retries once when the game left no RESULT line (a hang or a crash at load).
B="$1"
I="$2"
LIMIT="$3"
G="$B/g$I"
for try in 1 2; do
	rm -rf "$G"
	cp -r "$B/template" "$G"
	cd "$G" || exit 1
	SPRING_DATADIR="$HOME/bar-sim/data:$HOME/bar-sim/engine" timeout "$LIMIT" \
		"$HOME/bar-sim/engine/spring-headless" --write-dir "$G" "$G/script.txt" > run.log 2>&1
	echo "exit=$? try=$try" > exit.txt
	[ -s sctest_out.txt ] || cp LuaUI/Config/sctest_out.txt . 2>/dev/null # BAR 31614+: widgets write under LuaUI/Config
	grep -q "RESULT" sctest_out.txt 2>/dev/null && break
done
# keep what the batch reads; drop the rest (caches are large)
rm -rf "$G/cache" "$G/demos" "$G/LuaUI"
