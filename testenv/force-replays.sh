#!/bin/bash
# usage: [PARALLEL=6] [SPEED=100] [PRESET=duel|team|ffa] testenv/force-replays.sh [outdir]
# Plays every strong players' replay on the force host (~/bar-sim/demos, fetched there with
# pro_replays.py: testenv/force/README.md) with the data logger, PARALLEL at a time, and copies the
# samples to <outdir> (default testenv/data/pro), one <replay id>.jsonl each. Replays already logged on
# force are skipped; delete ~/bar-sim/prodata/<id>.jsonl there to log one again (e.g. a new logger).
set -e
T="$(cd "$(dirname "$0")" && pwd)"
HOST="${FORCE_HOST:-force}"
PRESET="${PRESET:-duel}"
# duels: ~/bar-sim/demos -> testenv/data/pro; team games / ffa: ~/bar-sim/demos-<preset> -> testenv/data/<preset>
if [ "$PRESET" = duel ]; then DEMOS=bar-sim/demos PRODATA=bar-sim/prodata; LOCAL=pro; else DEMOS=bar-sim/demos-$PRESET PRODATA=bar-sim/prodata-$PRESET; LOCAL=$PRESET; fi
OUT="${1:-$T/data/$LOCAL}"
PARALLEL="${PARALLEL:-6}"
SPEED="${SPEED:-100}"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/LuaUI/Widgets" "$STAGE/LuaUI/Include" "$OUT"
cp "$T/LuaUI/Widgets/zz_datalog.lua" "$STAGE/LuaUI/Widgets/"
sed -e 's/setmaxspeed 40/setmaxspeed 1000/' -e 's/setmaxspeed 20/setmaxspeed 1000/g' "$T/LuaUI/Widgets/zz_sctest.lua" > "$STAGE/LuaUI/Widgets/zz_sctest.lua"
cp "$T/../widget/LuaUI/Include/sc_unitkinds.lua" "$STAGE/LuaUI/Include/"
cp "$T/springsettings.template.cfg" "$STAGE/springsettings.cfg"
touch "$STAGE/datalog.txt"
echo replay > "$STAGE/sctest_scenario.txt"
echo "$SPEED 0" > "$STAGE/sctest_speed.txt"
mkdir -p "$STAGE/LuaUI/Config" && cp "$STAGE"/sctest_*.txt "$STAGE/datalog.txt" "$STAGE/LuaUI/Config/" # BAR 31614+ reads only under LuaUI/
ssh -n "$HOST" "rm -rf bar-sim/replay-template && mkdir -p $PRODATA bar-sim/replay-runs"
rsync -a "$STAGE/" "$HOST:bar-sim/replay-template/"
scp -q "$T/force/run_replay.sh" "$HOST:bar-sim/run_replay.sh"
rm -rf "$STAGE"
# only replays in the manifest: their game version and map were fetched (other .sdfz files are
# leftovers of failed fetches)
# detached on force (setsid nohup): it keeps going when this side dies (a closed session, a timed-out
# wait); running this again while it runs only waits for it
LOG="bar-sim/replays-$PRESET.log"
scp -q "$T/force/run_replays.sh" "$HOST:bar-sim/run_replays.sh"
if [ "$(ssh -n "$HOST" "pgrep -fc '[r]un_replays.sh.*$PRODATA'")" = 0 ]; then
	ssh -n "$HOST" "setsid nohup bash \$HOME/bar-sim/run_replays.sh \$HOME/$DEMOS \$HOME/$PRODATA $PARALLEL > \$HOME/$LOG 2>&1 < /dev/null &"
	sleep 5
fi
until [ "$(ssh -n "$HOST" "pgrep -fc '[r]un_replays.sh.*$PRODATA'")" = 0 ]; do sleep 30; done
ssh -n "$HOST" "cat $LOG"
echo "failed: $(ssh -n "$HOST" "grep -c 'no data' $LOG") (logs in ~/$PRODATA/../replay-failed/ on force; check why before using the data)"
rsync -a "$HOST:$PRODATA/" "$OUT/"
mkdir -p "$T/demos/$LOCAL"
rsync -a "$HOST:$DEMOS/manifest.json" "$T/demos/$LOCAL/manifest.json"
echo "$(ls "$OUT"/*.jsonl | wc -l | tr -d ' ') replays logged in $OUT"
