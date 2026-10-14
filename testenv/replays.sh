#!/bin/bash
# usage: replays.sh [outdir]
# Plays every replay in testenv/demos/pro/ (fetched by pro_replays.py) with the data logger widget
# (zz_datalog.lua) and keeps each game's samples in <outdir>/<replay id>.jsonl (default testenv/data/pro).
# Replays already logged are skipped. A 25-minute game plays in about four minutes.
T="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$T/data/pro}"
mkdir -p "$OUT"
touch "$T/datalog.txt" && mkdir -p "$T/LuaUI/Config" && touch "$T/LuaUI/Config/datalog.txt"
for demo in "$T"/demos/pro/*.sdfz; do
	id="$(basename "$demo" .sdfz)"
	[ -s "$OUT/$id.jsonl" ] && continue
	rm -f "$T/datalog.jsonl" "$T/LuaUI/Config/datalog.jsonl"
	start=$(date +%s)
	SPEED="${SPEED:-20}" "$T/run.sh" "$demo" 1500 replay >/dev/null 2>&1
	[ -s "$T/datalog.jsonl" ] || cp "$T/LuaUI/Config/datalog.jsonl" "$T/datalog.jsonl" 2>/dev/null
	if [ -s "$T/datalog.jsonl" ]; then
		cp "$T/datalog.jsonl" "$OUT/$id.jsonl"
		echo "$id: $(grep -c '"type":"fight"' "$OUT/$id.jsonl") fights, $(grep -c '"type":"unit"' "$OUT/$id.jsonl") units, $(grep -c '"type":"turret"' "$OUT/$id.jsonl") turrets | $(($(date +%s) - start))s"
	else
		echo "$id: no data ($(grep -m1 -i 'error' "$T/infolog.txt" | cut -c1-120))"
	fi
done
rm -f "$T/datalog.txt" "$T/LuaUI/Config/datalog.txt"
