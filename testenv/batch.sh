#!/bin/bash
# usage: [LABEL=name] [AI_PROFILE=medium] [MAP="..."] [SPEED=15] [LOCKSTEP=1] [WIDGET_SRC=dir] batch.sh <games> [scenario] [script]
# Plays several test games back to back and prints one line per game plus a summary. Each batch is kept in
# testenv/batch/<date>-<label>/ (testenv/batch/latest points at the newest): every game's harness log
# (<n>.txt), meta.txt (code version and settings) and report.md (cmd/gamereport: pace against strong
# players, losses, recurring problems, ranked findings). Compare arms with
#   go run ./cmd/gamereport -compare testenv/batch/<A> testenv/batch/<B>
T="$(cd "$(dirname "$0")" && pwd)"
N="${1:-3}"
SCENARIO="${2:-duelrules}"
SCRIPT="${3:-script_vsai.txt}"
export AI_PROFILE="${AI_PROFILE:-medium}" SPEED="${SPEED:-15}" LOCKSTEP="${LOCKSTEP:-0}" MAP="${MAP:-}"
DIR="$T/batch/$(date +%Y%m%d-%H%M)-${LABEL:-$SCENARIO}"
mkdir -p "$DIR"
ln -sfn "$DIR" "$T/batch/latest"
{
	echo "label: ${LABEL:-$SCENARIO}"
	echo "commit: $(git -C "$T/.." rev-parse --short HEAD)$(git -C "$T/.." diff --quiet -- widget testenv/LuaUI || echo ' (+ uncommitted widget changes)')"
	echo "widgets: ${WIDGET_SRC:-widget/LuaUI/Widgets}"
	echo "scenario: $SCENARIO  script: $SCRIPT  opponent: $AI_PROFILE  map: ${MAP:-All That Simmers}  speed: $SPEED  lockstep: $LOCKSTEP"
	echo "started: $(date '+%Y-%m-%d %H:%M')"
} > "$DIR/meta.txt"
wins=0 losses=0 timeouts=0
for i in $(seq 1 "$N"); do
	start=$(date +%s)
	"$T/run.sh" "$T/$SCRIPT" 1500 "$SCENARIO" >/dev/null 2>&1
	cp "$T/sctest_out.txt" "$DIR/$i.txt"
	result=$(grep -m1 "RESULT" "$DIR/$i.txt" | sed 's/^\[[0-9]*\] RESULT //')
	us=$(grep -m1 "  us:" "$DIR/$i.txt" | sed -E 's/.*metalProduced=([0-9]+).*unitsKilled=([0-9]+) unitsDied=([0-9]+).*damageDealt=([0-9]+) damageReceived=([0-9]+).*/metal=\1 killed=\2 lost=\3 dealt=\4 taken=\5/')
	echo "game $i: ${result:-no result} | $us | $(( $(date +%s) - start ))s"
	case "$result" in
	WIN*) wins=$((wins + 1)) ;;
	LOSS*) losses=$((losses + 1)) ;;
	TIMEOUT*) timeouts=$((timeouts + 1)) ;;
	esac
done
echo "$SCENARIO vs $AI_PROFILE ${MAP:-All That Simmers}: $wins won, $timeouts alive at 25 min, $losses lost" | tee -a "$DIR/meta.txt"
(cd "$T/.." && go run ./cmd/gamereport -title "Batch $(basename "$DIR")" "$DIR") > "$DIR/report.md" 2>&1
echo "report: $DIR/report.md"
sed -n '/^## Findings/,$p' "$DIR/report.md"
