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
		[ -d "$G/replaystage" ] && rm -rf "$G/demos"
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
		grep -q "RESULT" sctest_out.txt 2>/dev/null && break
	done
	# batch.py --datalog: replay the game as a spectator with the data logger (both sides in full)
	if [ -d "$G/replaystage" ]; then
		demo=$(ls "$G"/demos/*.sdfz 2>/dev/null | head -1)
		R="/opt/bar/games/r$i"
		rm -rf "$R" && cp -r "$G/replaystage" "$R"
		# where the game ended (timed-out games have no game over to stop the replay)
		grep -o '^\[[0-9]*\]' "$G/sctest_out.txt" 2>/dev/null | tail -1 | tr -d '[]' > "$R/LuaUI/Config/sctest_replayend.txt"
		if [ -n "$demo" ]; then
			cd "$R" || return
			# a replay listens on the port its game was recorded with: two at once collide (exit 21, no
			# message). Each in its own network namespace where allowed, else one at a time
			if unshare -n true 2>/dev/null; then
				unshare -n -- bash -c "ip link set lo up 2>/dev/null; SPRING_DATADIR=/opt/bar/data:/opt/bar/engine timeout $LIMIT /opt/bar/engine/spring-headless --write-dir '$R' '$demo'" > run.log 2>&1
			else
				flock /opt/bar/replay.lock env SPRING_DATADIR=/opt/bar/data:/opt/bar/engine timeout "$LIMIT" /opt/bar/engine/spring-headless --write-dir "$R" "$demo" > run.log 2>&1
			fi
			echo "replay exit=$?" >> "$G/exit.txt"
			[ -s datalog.jsonl ] || cp LuaUI/Config/datalog.jsonl . 2>/dev/null
			if grep -q '"type":"end"' datalog.jsonl 2>/dev/null; then
				cp datalog.jsonl "$G/datalog.jsonl"
			else
				cp run.log "$G/replay.log"
			fi
		else
			echo "replay: no demo" >> "$G/exit.txt"
		fi
		rm -rf "$R"
	fi
}
export -f one
export LIMIT
seq "$FIRST" "$LAST" | xargs -P "$PARALLEL" -I{} bash -c 'one {}'
cd /opt/bar/games && tar czf /opt/bar/results.tgz g*/sctest_out.txt g*/run.log g*/exit.txt $(ls g*/datalog.jsonl g*/replay.log 2>/dev/null) 2>/dev/null
echo "done $FIRST-$LAST"
