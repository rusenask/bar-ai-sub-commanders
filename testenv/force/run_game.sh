#!/bin/bash
# On the force host: plays game <i> of a batch with the headless engine, in its own write dir copied from
# the batch's template. usage: run_game.sh <batch dir> <i> <wall-clock limit, seconds>
# Retries once when the game left no RESULT line (a hang or a crash at load).
# force is shared and ran out of memory (2026-10-31): a game starts only with MIN_FREE_MB available
# (waits up to 10 min, then skips: exit.txt "skipped"), and is killed when the host falls under
# MEM_FLOOR_MB while it runs (exit.txt "lowmem": no retry)
B="$1"
I="$2"
LIMIT="$3"
G="$B/g$I"
MIN_FREE_MB="${MIN_FREE_MB:-8000}"
MEM_FLOOR_MB="${MEM_FLOOR_MB:-3000}"
avail() { awk '/MemAvailable/ { print int($2 / 1024) }' /proc/meminfo; }
for try in 1 2; do
	waited=0
	while [ "$(avail)" -lt "$MIN_FREE_MB" ]; do
		if [ "$waited" -ge 600 ]; then
			mkdir -p "$G" && echo "skipped: $(avail) MB available < $MIN_FREE_MB" > "$G/exit.txt"
			exit 0
		fi
		sleep 10
		waited=$(( waited + 10 ))
	done
	rm -rf "$G"
	cp -r "$B/template" "$G"
	cd "$G" || exit 1
	# an interleaved A/B (force-batch.sh WIDGET_SRC_B): even games play arm B, each pair the same spec
	pair=$(( I - 1 ))
	if [ -d armB ]; then
		if [ $((I % 2)) = 0 ]; then
			rm -f LuaUI/Widgets/gui_subcommanders*.lua LuaUI/Include/sc_*.lua
			cp armB/Widgets/*.lua LuaUI/Widgets/ && cp armB/Include/*.lua LuaUI/Include/
		fi
		rm -rf armB
		pair=$(( (I - 1) / 2 ))
	fi
	# battles: game i takes spec (pair mod count) of the template's battles/
	if [ -d battles ]; then
		specs=(battles/*.txt)
		mkdir -p LuaUI/Config && cp "${specs[$(( pair % ${#specs[@]} ))]}" LuaUI/Config/sctest_battle.txt
	fi
	SPRING_DATADIR="$HOME/bar-sim/data:$HOME/bar-sim/engine" timeout "$LIMIT" \
		"$HOME/bar-sim/engine/spring-headless" --write-dir "$G" "$G/script.txt" > run.log 2>&1 &
	pid=$!
	lowmem=
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$(avail)" -lt "$MEM_FLOOR_MB" ]; then
			lowmem=1
			pkill -KILL -P "$pid" 2>/dev/null
			kill -KILL "$pid" 2>/dev/null
			break
		fi
		sleep 5
	done
	wait "$pid"
	code=$?
	if [ -n "$lowmem" ]; then
		echo "lowmem: killed at $(avail) MB available < $MEM_FLOOR_MB, try=$try" > exit.txt
		break
	fi
	echo "exit=$code try=$try" > exit.txt
	[ -s sctest_out.txt ] || cp LuaUI/Config/sctest_out.txt . 2>/dev/null # BAR 31614+: widgets write under LuaUI/Config
	grep -q "RESULT" sctest_out.txt 2>/dev/null && break
done
# keep what the batch reads; drop the rest (caches are large)
rm -rf "$G/cache" "$G/demos" "$G/LuaUI"
