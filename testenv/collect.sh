#!/bin/bash
# usage: collect.sh <games> [outdir]
# Collects decision-model training data (design/decision-models.md): BARbarian vs BARbarian games watched
# by the data logger widget (zz_datalog.lua) with full view, random maps, factions and profiles, at 15x.
# Each game's samples end up in <outdir>/<n>-<timestamp>.jsonl (default testenv/data/raw).
T="$(cd "$(dirname "$0")" && pwd)"
N="${1:-10}"
OUT="${2:-$T/data/raw}"
mkdir -p "$OUT"
MAPS=("All That Simmers v1.1.1" "Altair_Crossing_V4.1" "Comet Catcher Remake 1.8" "Supreme Isthmus v1.7" "All That Glitters v2.2.3" "Red Comet Remake 1.8")
SIDES=(Armada Cortex Legion)
PROFILES=(hard hard medium)
touch "$T/datalog.txt"
for i in $(seq 1 "$N"); do
	map="${MAPS[$((RANDOM % ${#MAPS[@]}))]}"
	s0="${SIDES[$((RANDOM % 3))]}"
	s1="${SIDES[$((RANDOM % 3))]}"
	p0="${PROFILES[$((RANDOM % 3))]}"
	p1="${PROFILES[$((RANDOM % 3))]}"
	sed -e "s/__MAP__/$map/" -e "s/__SIDE0__/$s0/" -e "s/__SIDE1__/$s1/" -e "s/__PROFILE0__/$p0/" -e "s/__PROFILE1__/$p1/" \
		"$T/script_spectate.txt" >"$T/_script_collect.txt"
	rm -f "$T/datalog.jsonl"
	start=$(date +%s)
	SPEED="${SPEED:-15}" "$T/run.sh" "$T/_script_collect.txt" 900 spectate >/dev/null 2>&1
	name="$(printf '%03d' "$i")-$(date +%Y%m%d%H%M%S)"
	if [ -s "$T/datalog.jsonl" ]; then
		cp "$T/datalog.jsonl" "$OUT/$name.jsonl"
		echo "game $i: $map $s0($p0) vs $s1($p1): $(grep -c '"type":"fight"' "$OUT/$name.jsonl") fights, $(grep -c '"type":"unit"' "$OUT/$name.jsonl") units, $(grep -c '"type":"turret"' "$OUT/$name.jsonl") turrets | $(grep -m1 RESULT "$T/sctest_out.txt") | $(($(date +%s) - start))s"
	else
		echo "game $i: $map $s0 vs $s1: no data ($(tail -1 "$T/run.log"))"
	fi
done
rm -f "$T/datalog.txt"
