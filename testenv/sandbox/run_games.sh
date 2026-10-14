#!/bin/bash
# In a sandbox: plays games <first>..<last> of a batch, <parallel> at a time, from /opt/bar/stage
# (the write dir template), each in /opt/bar/games/g<i>; then packs what the batch reads into
# /opt/bar/results.tgz. usage: run_games.sh <first> <last> <parallel> <wall-clock limit per game>
FIRST="$1"
LAST="$2"
PARALLEL="$3"
LIMIT="$4"
mkdir -p /opt/bar/games
one() {
	i="$1"
	G="/opt/bar/games/g$i"
	for try in 1 2; do
		rm -rf "$G"
		cp -r /opt/bar/stage "$G"
		# an interleaved A/B (batch.py --widgets-b): even games play arm B's widgets
		if [ -d "$G/armB" ]; then
			if [ $((i % 2)) = 0 ]; then
				rm -f "$G"/LuaUI/Widgets/gui_subcommanders*.lua "$G"/LuaUI/Include/sc_*.lua
				cp "$G"/armB/Widgets/*.lua "$G/LuaUI/Widgets/" && cp "$G"/armB/Include/*.lua "$G/LuaUI/Include/"
			fi
			rm -rf "$G/armB"
			pair=$(( (i - 1) / 2 )) # games 2k-1 and 2k: the same battle spec
		else
			pair=$(( i - 1 ))
		fi
		# battles: game i takes spec (pair mod count) of the stage's battles/
		if [ -d "$G/battles" ]; then
			specs=("$G"/battles/*.txt)
			mkdir -p "$G/LuaUI/Config" && cp "${specs[$(( pair % ${#specs[@]} ))]}" "$G/LuaUI/Config/sctest_battle.txt"
		fi
		# a learning run: this game's rule set (internal/learn), read by the widget at start
		[ -f "/opt/bar/overlays/g$i.json" ] && mkdir -p "$G/LuaUI/Config" && cp "/opt/bar/overlays/g$i.json" "$G/LuaUI/Config/sc_learned.json"
		cd "$G" || return
		SPRING_DATADIR=/opt/bar/data:/opt/bar/engine timeout "$LIMIT" /opt/bar/engine/spring-headless --write-dir "$G" "$G/script.txt" > run.log 2>&1
		echo "exit=$? try=$try" > exit.txt
		[ -s sctest_out.txt ] || cp LuaUI/Config/sctest_out.txt . 2>/dev/null # BAR 31614+: widgets write under LuaUI/Config
		[ -s datalog.jsonl ] || cp LuaUI/Config/datalog.jsonl . 2>/dev/null # the data logger (batch.py --datalog)
		grep -q "RESULT" sctest_out.txt 2>/dev/null && break
	done
}
export -f one
export LIMIT
seq "$FIRST" "$LAST" | xargs -P "$PARALLEL" -I{} bash -c 'one {}'
cd /opt/bar/games && tar czf /opt/bar/results.tgz g*/sctest_out.txt g*/run.log g*/exit.txt $(ls g*/datalog.jsonl 2>/dev/null) 2>/dev/null
echo "done $FIRST-$LAST"
