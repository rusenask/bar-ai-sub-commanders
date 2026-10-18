#!/bin/bash
# On the force host: one game of a speed benchmark (testenv/force-speedbench.sh). Plays the template's
# demo.sdfz (a replay) or script.txt (a live game) headless in its own write dir and port.
# usage: [ENGINE=dir] speed_game.sh <bench dir> <i> <wall-clock limit, seconds>
# ENGINE: another engine dir (default ~/bar-sim/engine, the official build)
B="$1"
I="$2"
LIMIT="$3"
G="$B/g$I"
rm -rf "$G"
cp -r "$B/template" "$G"
cd "$G" || exit 1
# replays' local servers listen on HostPortDefault: one port per game
echo "HostPortDefault = $((8452 + I))" >> springsettings.cfg
what="$G/script.txt"
[ -f demo.sdfz ] && what="$G/demo.sdfz"
start=$(date +%s.%N)
E="${ENGINE:-$HOME/bar-sim/engine}"
SPRING_DATADIR="$HOME/bar-sim/data:$E" timeout "$LIMIT" \
	"$E/spring-headless" --write-dir "$G" "$what" > run.log 2>&1
echo "exit=$? wall=$(echo "$(date +%s.%N) - $start" | bc)" > exit.txt
[ -s sctest_out.txt ] || cp LuaUI/Config/sctest_out.txt . 2>/dev/null
rm -rf "$G/cache" "$G/demos" "$G/LuaUI/Widgets" "$G/demo.sdfz"
