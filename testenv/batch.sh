#!/bin/bash
# usage: [AI_PROFILE=medium] [MAP="..."] [SPEED=15] [LOCKSTEP=1] batch.sh <games> [scenario] [script]
# Plays several test games back to back and prints one line per game plus a summary.
# Each game's full output is kept in testenv/batch/<n>.txt.
T="$(cd "$(dirname "$0")" && pwd)"
N="${1:-3}"
SCENARIO="${2:-duelrules}"
SCRIPT="${3:-script_vsai.txt}"
export AI_PROFILE="${AI_PROFILE:-medium}" SPEED="${SPEED:-15}" LOCKSTEP="${LOCKSTEP:-0}" MAP="${MAP:-}"
mkdir -p "$T/batch"
wins=0 losses=0 timeouts=0
for i in $(seq 1 "$N"); do
	start=$(date +%s)
	"$T/run.sh" "$T/$SCRIPT" 1500 "$SCENARIO" >/dev/null 2>&1
	cp "$T/sctest_out.txt" "$T/batch/$i.txt"
	result=$(grep -m1 "RESULT" "$T/batch/$i.txt" | sed 's/^\[[0-9]*\] RESULT //')
	us=$(grep -m1 "  us:" "$T/batch/$i.txt" | sed -E 's/.*metalProduced=([0-9]+).*unitsKilled=([0-9]+) unitsDied=([0-9]+).*damageDealt=([0-9]+) damageReceived=([0-9]+).*/metal=\1 killed=\2 lost=\3 dealt=\4 taken=\5/')
	echo "game $i: ${result:-no result} | $us | $(( $(date +%s) - start ))s"
	case "$result" in
	WIN*) wins=$((wins + 1)) ;;
	LOSS*) losses=$((losses + 1)) ;;
	TIMEOUT*) timeouts=$((timeouts + 1)) ;;
	esac
done
echo "$SCENARIO vs $AI_PROFILE ${MAP:-All That Simmers}: $wins won, $timeouts alive at 25 min, $losses lost"
