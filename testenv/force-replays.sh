#!/bin/bash
# usage: [PARALLEL=6] [SPEED=100] testenv/force-replays.sh [outdir]
# Plays every strong players' replay on the force host (~/bar-sim/demos, fetched there with
# pro_replays.py: testenv/force/README.md) with the data logger, PARALLEL at a time, and copies the
# samples to <outdir> (default testenv/data/pro), one <replay id>.jsonl each. Replays already logged on
# force are skipped; delete ~/bar-sim/prodata/<id>.jsonl there to log one again (e.g. a new logger).
set -e
T="$(cd "$(dirname "$0")" && pwd)"
HOST="${FORCE_HOST:-force}"
OUT="${1:-$T/data/pro}"
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
ssh "$HOST" "rm -rf bar-sim/replay-template && mkdir -p bar-sim/prodata bar-sim/replay-runs"
rsync -a "$STAGE/" "$HOST:bar-sim/replay-template/"
scp -q "$T/force/run_replay.sh" "$HOST:bar-sim/run_replay.sh"
rm -rf "$STAGE"
# only replays in the manifest: their game version and map were fetched (other .sdfz files are
# leftovers of failed fetches)
ssh -n "$HOST" "python3 -c 'import json,os; d=os.path.expanduser(\"~/bar-sim/demos\"); [print(d + \"/\" + v[\"file\"]) for v in json.load(open(d + \"/manifest.json\")).values()]' | xargs -P $PARALLEL -I{} bash \$HOME/bar-sim/run_replay.sh \$HOME/bar-sim/replay-template {} \$HOME/bar-sim/prodata 1800"
rsync -a "$HOST:bar-sim/prodata/" "$OUT/"
rsync -a "$HOST:bar-sim/demos/manifest.json" "$T/demos/pro/manifest.json"
echo "$(ls "$OUT"/*.jsonl | wc -l | tr -d ' ') replays logged in $OUT"
