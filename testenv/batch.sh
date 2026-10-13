#!/bin/bash
# usage: [LABEL=name] [WORKERS=3] [AI_PROFILE=medium] [MAP="..."] [SPEED=15] [LOCKSTEP=1] [DUEL_MINUTES=25]
#        [WIDGET_SRC=dir] batch.sh <games> [scenario] [script]
# Plays several test games and prints one line per game plus a summary. Games run in parallel on WORKERS
# separate write dirs (testenv/workers/<n>, default 3; 1 for the duel scenario, whose strategist needs
# the one test bridge). Each batch is kept in testenv/batch/<date>-<label>/ (testenv/batch/latest points
# at the newest): every game's harness log (<n>.txt), meta.txt (code version, settings, how many games
# ran) and report.md (cmd/gamereport). A game that didn't run is tried once more; meta.txt and the summary
# say how many ran. Compare arms with
#   go run ./cmd/gamereport -compare testenv/batch/<A> testenv/batch/<B>
T="$(cd "$(dirname "$0")" && pwd)"
N="${1:-3}"
SCENARIO="${2:-duelrules}"
SCRIPT="${3:-script_vsai.txt}"
export AI_PROFILE="${AI_PROFILE:-medium}" SPEED="${SPEED:-15}" LOCKSTEP="${LOCKSTEP:-0}" MAP="${MAP:-}" DUEL_MINUTES="${DUEL_MINUTES:-25}"
WORKERS="${WORKERS:-$([ "$SCENARIO" = duel ] && echo 1 || echo 3)}"
[ "$SCENARIO" = duel ] && WORKERS=1
DIR="$T/batch/$(date +%Y%m%d-%H%M)-${LABEL:-$SCENARIO}"
mkdir -p "$DIR"
ln -sfn "$DIR" "$T/batch/latest"
{
	echo "label: ${LABEL:-$SCENARIO}"
	echo "commit: $(git -C "$T/.." rev-parse --short HEAD)$(git -C "$T/.." diff --quiet -- widget testenv/LuaUI || echo ' (+ uncommitted widget changes)')"
	echo "widgets: ${WIDGET_SRC:-widget/LuaUI/Widgets}"
	echo "scenario: $SCENARIO  script: $SCRIPT  opponent: $AI_PROFILE  map: ${MAP:-All That Simmers}  speed: $SPEED  lockstep: $LOCKSTEP  minutes: $DUEL_MINUTES  workers: $WORKERS"
	# the test bridge serves the decision models: they change how the rules play, so record them
	echo "test bridge: $(docker inspect scbridge-test --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -E '^SCBRIDGE_DECIDER_(URL|ROUTES)=.' | tr '\n' ' ' || true)$(docker inspect scbridge-test >/dev/null 2>&1 && { docker inspect scbridge-test --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^SCBRIDGE_DECIDER_(URL|ROUTES)=.' || echo 'no decision models'; } || echo 'not running')"
	echo "started: $(date '+%Y-%m-%d %H:%M')"
} > "$DIR/meta.txt"

# one game on one worker: up to two tries; appends "<n>|<line>" to results
play() { # play <game> <worker>
	local i="$1" w="$2" start try out
	for try in 1 2; do
		start=$(date +%s)
		if [ "$WORKERS" -gt 1 ]; then
			WORKER="$w" "$T/run.sh" "$T/$SCRIPT" "" "$SCENARIO" >/dev/null 2>&1
			out="$T/workers/$w/sctest_out.txt"
		else
			"$T/run.sh" "$T/$SCRIPT" "" "$SCENARIO" >/dev/null 2>&1
			out="$T/sctest_out.txt"
		fi
		if [ -s "$out" ] && grep -q "RESULT" "$out"; then
			cp "$out" "$DIR/$i.txt"
			local result us
			result=$(grep -m1 "RESULT" "$DIR/$i.txt" | sed 's/^\[[0-9]*\] RESULT //')
			us=$(grep -m1 "  us:" "$DIR/$i.txt" | sed -E 's/.*metalProduced=([0-9]+).*unitsKilled=([0-9]+) unitsDied=([0-9]+).*damageDealt=([0-9]+) damageReceived=([0-9]+).*/metal=\1 killed=\2 lost=\3 dealt=\4 taken=\5/')
			local line="game $i: $result | $us | $(( $(date +%s) - start ))s$([ "$try" = 2 ] && echo ' (second try)')"
			echo "$line"
			echo "$i|$line" >> "$DIR/results.txt"
			return
		fi
	done
	echo "game $i: did not run twice (see the run.log of worker $w)"
	echo "$i|game $i: did not run twice" >> "$DIR/results.txt"
}

for w in $(seq 1 "$WORKERS"); do
	[ "$WORKERS" -gt 1 ] && "$T/worker.sh" "$w" >/dev/null
	(
		i=$w
		while [ "$i" -le "$N" ]; do
			play "$i" "$w"
			i=$((i + WORKERS))
		done
	) &
done
wait

ran=$(ls "$DIR"/[0-9]*.txt 2>/dev/null | wc -l | tr -d ' ')
wins=$(grep -c "game [0-9]*: WIN" "$DIR/results.txt" 2>/dev/null)
losses=$(grep -c "game [0-9]*: LOSS" "$DIR/results.txt" 2>/dev/null)
timeouts=$(grep -c "game [0-9]*: TIMEOUT" "$DIR/results.txt" 2>/dev/null)
echo "ran: $ran/$N" >> "$DIR/meta.txt"
[ "$ran" -lt "$N" ] && echo "WARNING: only $ran of $N games ran"
echo "$SCENARIO vs $AI_PROFILE ${MAP:-All That Simmers}: $ran/$N ran: $wins won, $timeouts alive at $DUEL_MINUTES min, $losses lost" | tee -a "$DIR/meta.txt"
(cd "$T/.." && go run ./cmd/gamereport -title "Batch $(basename "$DIR")" "$DIR") > "$DIR/report.md" 2>&1
echo "report: $DIR/report.md"
sed -n '/^## Findings/,$p' "$DIR/report.md"
