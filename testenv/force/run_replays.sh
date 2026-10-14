#!/bin/bash
# On the force host: plays every replay of a manifest with run_replay.sh, PARALLEL at a time.
# usage: run_replays.sh <demos dir> <out dir> <parallel>   (started detached by testenv/force-replays.sh)
DEMOS="$1"
OUT="$2"
PARALLEL="$3"
python3 -c "import json,sys; d=sys.argv[1]; [print(d + '/' + v['file']) for v in json.load(open(d + '/manifest.json')).values()]" "$DEMOS" |
	xargs -P "$PARALLEL" -I{} bash "$HOME/bar-sim/run_replay.sh" "$HOME/bar-sim/replay-template" {} "$OUT" 3600
echo "all done"
