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
		cd "$G" || return
		SPRING_DATADIR=/opt/bar/data:/opt/bar/engine timeout "$LIMIT" /opt/bar/engine/spring-headless --write-dir "$G" "$G/script.txt" > run.log 2>&1
		echo "exit=$? try=$try" > exit.txt
		[ -s sctest_out.txt ] || cp LuaUI/Config/sctest_out.txt . 2>/dev/null # BAR 31614+: widgets write under LuaUI/Config
		grep -q "RESULT" sctest_out.txt 2>/dev/null && break
	done
}
export -f one
export LIMIT
seq "$FIRST" "$LAST" | xargs -P "$PARALLEL" -I{} bash -c 'one {}'
cd /opt/bar/games && tar czf /opt/bar/results.tgz g*/sctest_out.txt g*/run.log g*/exit.txt 2>/dev/null
echo "done $FIRST-$LAST"
