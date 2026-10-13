#!/bin/bash
# usage: collect-results.sh <batch dir> <games> <start epoch> <scenario> <opponent> <map> <minutes>
# Turns raw game output in <batch dir>/remote/g<i>/{sctest_out.txt,run.log,exit.txt} into a batch like
# batch.sh makes: <i>.txt, results.txt, meta.txt lines and report.md. Used by the sandbox batches.
T="$(cd "$(dirname "$0")" && pwd)"
DIR="$1"
N="$2"
start="$3"
SCENARIO="$4"
AI_PROFILE="$5"
MAP="$6"
DUEL_MINUTES="$7"
rm -f "$DIR/results.txt"
for i in $(seq 1 "$N"); do
	out="$DIR/remote/g$i/sctest_out.txt"
	if [ -s "$out" ] && grep -q "RESULT" "$out"; then
		cp "$out" "$DIR/$i.txt"
		result=$(grep -m1 "RESULT" "$DIR/$i.txt" | sed 's/^\[[0-9]*\] RESULT //')
		us=$(grep -m1 "  us:" "$DIR/$i.txt" | sed -E 's/.*metalProduced=([0-9]+).*unitsKilled=([0-9]+) unitsDied=([0-9]+).*damageDealt=([0-9]+) damageReceived=([0-9]+).*/metal=\1 killed=\2 lost=\3 dealt=\4 taken=\5/')
		crash=$(grep -E "Error in .*(gui_subcommanders|sc_[a-z]+\.lua)|Removed widget: Sub-Commanders" "$DIR/remote/g$i/run.log" 2>/dev/null | head -5)
		[ -n "$crash" ] && echo "$crash" | sed 's/^/[widget-error] /' >> "$DIR/$i.txt"
		line="game $i: $result | $us$([ -n "$crash" ] && echo ' | WIDGET CRASHED')"
	else
		line="game $i: did not run ($(cat "$DIR/remote/g$i/exit.txt" 2>/dev/null))"
	fi
	echo "$line"
	echo "$i|$line" >> "$DIR/results.txt"
done
ran=$(ls "$DIR"/[0-9]*.txt 2>/dev/null | wc -l | tr -d ' ')
wins=$(grep -c "game [0-9]*: WIN" "$DIR/results.txt")
losses=$(grep -c "game [0-9]*: LOSS" "$DIR/results.txt")
timeouts=$(grep -c "game [0-9]*: TIMEOUT" "$DIR/results.txt")
echo "ran: $ran/$N in $(( ($(date +%s) - start) / 60 )) min" >> "$DIR/meta.txt"
crashed=$(grep -c "WIDGET CRASHED" "$DIR/results.txt")
[ "$crashed" -gt 0 ] && echo "WARNING: the Sub-Commanders widget crashed in $crashed games: results are invalid" | tee -a "$DIR/meta.txt"
echo "$SCENARIO vs $AI_PROFILE ${MAP:-All That Simmers}: $ran/$N ran: $wins won, $timeouts alive at $DUEL_MINUTES min, $losses lost" | tee -a "$DIR/meta.txt"
(cd "$T/.." && go run ./cmd/gamereport -title "Batch $(basename "$DIR")" "$DIR") > "$DIR/report.md" 2>&1
echo "report: $DIR/report.md"
sed -n '/^## Findings/,$p' "$DIR/report.md"
