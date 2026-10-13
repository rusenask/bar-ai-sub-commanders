#!/bin/bash
# usage: [LABEL=name] [WORKERS=3] [AI_PROFILE=medium] [MAP="..."] [SPEED=15] [LOCKSTEP=1] [DUEL_MINUTES=60]
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
# 60 game minutes by default: at 45 good games were still being decided (wins came at 40-43)
export AI_PROFILE="${AI_PROFILE:-medium}" SPEED="${SPEED:-15}" LOCKSTEP="${LOCKSTEP:-0}" MAP="${MAP:-}" DUEL_MINUTES="${DUEL_MINUTES:-60}"
# one game at a time by default (the machine stays usable); WORKERS=3 runs three at once
WORKERS="${WORKERS:-1}"
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
		local rc wdir
		if [ "$WORKERS" -gt 1 ]; then
			rc=$(WORKER="$w" "$T/run.sh" "$T/$SCRIPT" "" "$SCENARIO" 2>/dev/null | tail -1)
			wdir="$T/workers/$w"
		else
			rc=$("$T/run.sh" "$T/$SCRIPT" "" "$SCENARIO" 2>/dev/null | tail -1)
			wdir="$T"
		fi
		out="$wdir/sctest_out.txt"
		if [ -s "$out" ] && grep -q "RESULT" "$out"; then
			cp "$out" "$DIR/$i.txt"
			local result us
			result=$(grep -m1 "RESULT" "$DIR/$i.txt" | sed 's/^\[[0-9]*\] RESULT //')
			us=$(grep -m1 "  us:" "$DIR/$i.txt" | sed -E 's/.*metalProduced=([0-9]+).*unitsKilled=([0-9]+) unitsDied=([0-9]+).*damageDealt=([0-9]+) damageReceived=([0-9]+).*/metal=\1 killed=\2 lost=\3 dealt=\4 taken=\5/')
			# our widgets' Lua errors (spring's log): BAR removes a widget that errors, and the game goes on
			# without it, looking like a plain loss (v15-v17: "attempt to call global 'addUnit'")
			local crash
			crash=$(grep -E "Error in .*(gui_subcommanders|sc_[a-z]+\.lua)|Removed widget: Sub-Commanders" "$wdir/run.log" 2>/dev/null | head -5)
			if [ -n "$crash" ]; then
				echo "$crash" | sed 's/^/[widget-error] /' >> "$DIR/$i.txt"
				cp "$wdir/run.log" "$DIR/$i-run.log"
			fi
			local line="game $i: $result | $us | $(( $(date +%s) - start ))s$([ "$try" = 2 ] && echo ' (second try)')$([ -n "$crash" ] && echo ' | WIDGET CRASHED')"
			echo "$line"
			echo "$i|$line" >> "$DIR/results.txt"
			return
		fi
		# keep the evidence: why it didn't finish (run.sh's exit: 124 = stalled, 142 = time limit)
		mkdir -p "$DIR/failed"
		cp "$wdir/run.log" "$DIR/failed/$i-try$try-run.log" 2>/dev/null
		[ -f "$out" ] && cp "$out" "$DIR/failed/$i-try$try-harness.txt"
		echo "$i try $try: $rc after $(( $(date +%s) - start ))s, worker $w" >> "$DIR/failed/README.txt"
	done
	echo "game $i: did not run twice (see the run.log of worker $w)"
	echo "$i|game $i: did not run twice" >> "$DIR/results.txt"
}

for w in $(seq 1 "$WORKERS"); do
	[ "$WORKERS" -gt 1 ] && "$T/worker.sh" "$w" >/dev/null
	(
		# stagger the workers: several engines loading a map at once can hang
		sleep $(( (w - 1) * 20 ))
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
crashed=$(grep -c "WIDGET CRASHED" "$DIR/results.txt" 2>/dev/null)
[ "$crashed" -gt 0 ] && echo "WARNING: the Sub-Commanders widget crashed in $crashed games (see [widget-error] lines, N-run.log): results are invalid" | tee -a "$DIR/meta.txt"
[ "$ran" -lt "$N" ] && echo "WARNING: only $ran of $N games ran"
echo "$SCENARIO vs $AI_PROFILE ${MAP:-All That Simmers}: $ran/$N ran: $wins won, $timeouts alive at $DUEL_MINUTES min, $losses lost" | tee -a "$DIR/meta.txt"
(cd "$T/.." && go run ./cmd/gamereport -title "Batch $(basename "$DIR")" "$DIR") > "$DIR/report.md" 2>&1
echo "report: $DIR/report.md"
sed -n '/^## Findings/,$p' "$DIR/report.md"
