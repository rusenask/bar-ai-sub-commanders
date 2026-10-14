#!/bin/bash
# usage: [LABEL=name] [WIDGET_SRC=...] [SIDE=Legion] [ENEMY_SIDE=Armada] [PARALLEL=4] [AI_PROFILE=medium] [MAP="..."] [SPEED=100] [OVERLAY=rules.json]
#        [DUEL_MINUTES=60] testenv/force-batch.sh <games> [scenario: duelrules|autopilot]
# Runs a batch on the force GPU host (FORCE_HOST, default force) with the headless engine, PARALLEL
# games at a time at up to SPEED x, and collects it into testenv/batch/<stamp>-<label>/ like batch.sh
# (N.txt, results.txt, meta.txt, report.md), so make compare / make report work the same. Setup of the
# host (engine, game package, maps): testenv/force/README.md. Doesn't touch testenv/ or a local batch.
# RESUME=<stamp-label> (a testenv/batch/ dir name): wait for that batch's games on force and collect them,
# when the local side died (a closed session) while the games kept running there.
set -e
T="$(cd "$(dirname "$0")" && pwd)"
HOST="${FORCE_HOST:-force}"
N="${1:-8}"
SCENARIO="${2:-duelrules}"
PARALLEL="${PARALLEL:-4}"
SPEED="${SPEED:-100}"
DUEL_MINUTES="${DUEL_MINUTES:-60}"
AI_PROFILE="${AI_PROFILE:-medium}"
LABEL="${LABEL:-force}"
STAMP="$(date +%Y%m%d-%H%M)"
DIR="$T/batch/$STAMP-$LABEL"
if [ -n "$RESUME" ]; then
	DIR="$T/batch/$RESUME"
	R="bar-sim/batches/$RESUME"
	start=$(date +%s)
	until [ "$(ssh -n "$HOST" "pgrep -fc '[x]args.*$RESUME'")" = 0 ]; do sleep 30; done
	rm -f "$DIR/results.txt"
	set +e
fi
if [ -z "$RESUME" ]; then
SRC="${WIDGET_SRC:-$T/../widget/LuaUI/Widgets}"
[ -f "$SRC/gui_subcommanders.lua" ] || { echo "force-batch.sh: no widgets in $SRC (WIDGET_SRC from a failed arm.sh?)" >&2; exit 1; }
mkdir -p "$DIR"
{
	echo "label: $LABEL"
	echo "commit: $(git -C "$T/.." rev-parse --short HEAD)"
	echo "widgets: $SRC"
	echo "scenario: $SCENARIO  script: script_vsai.txt  opponent: $AI_PROFILE  map: ${MAP:-All That Simmers}  speed: $SPEED  lockstep: 0  minutes: $DUEL_MINUTES  workers: $PARALLEL (force, headless)  side: ${SIDE:-Legion} vs ${ENEMY_SIDE:-Armada}"
	echo "started: $(date '+%Y-%m-%d %H:%M')"
} > "$DIR/meta.txt"
# the write dir every game starts from
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/LuaUI/Widgets" "$STAGE/LuaUI/Include"
cp "$SRC"/gui_subcommanders*.lua "$STAGE/LuaUI/Widgets/"
cp "$SRC"/../Include/sc_*.lua "$STAGE/LuaUI/Include/" 2>/dev/null || cp "$T"/../widget/LuaUI/Include/sc_*.lua "$STAGE/LuaUI/Include/"
# the harness; no rendering here, so the game may run far faster than the 20x it allows on a desktop
sed 's/setmaxspeed 20/setmaxspeed 1000/g' "$T/LuaUI/Widgets/zz_sctest.lua" > "$STAGE/LuaUI/Widgets/zz_sctest.lua"
[ "$SCENARIO" = autopilot ] && sed -i '' 's/enabled = false,/enabled = true,/' "$STAGE/LuaUI/Widgets/gui_subcommanders_autopilot.lua"
cp "$T/springsettings.template.cfg" "$STAGE/springsettings.cfg"
# SIDE / ENEMY_SIDE: the factions (team 0 ours, team 1 BARbarian's; default Legion vs Armada)
sed -e "s/profile=[a-z_]*;/profile=$AI_PROFILE;/" -e "s/mapname=[^;]*;/mapname=${MAP:-All That Simmers v1.1.1};/" "$T/script_vsai.txt" |
	awk -v us="${SIDE:-Legion}" -v them="${ENEMY_SIDE:-Armada}" '/side=/ { n++; sub(/side=[A-Za-z]+;/, "side=" (n == 1 ? us : them) ";") } { print }' > "$STAGE/script.txt"
# battles (scenario battle, testenv/battles/): the enemy is NullAI (its units stand and fight back;
# BARbarian pulls given units home), and each game takes the next spec (run_game.sh)
if [ "$SCENARIO" = battle ]; then
	sed -i '' -e 's/shortname=BARb;/shortname=NullAI;/' -e 's/version=stable;/version=0.1;/' "$STAGE/script.txt"
	mkdir -p "$STAGE/battles" && cp "${BATTLES:-$T/battles}"/*.txt "$STAGE/battles/"
	echo "battles: $(ls "$STAGE/battles" | tr '\n' ' ')" >> "$DIR/meta.txt"
fi
echo "$DUEL_MINUTES" > "$STAGE/sctest_minutes.txt"
echo "$SCENARIO" > "$STAGE/sctest_scenario.txt"
echo "$SPEED 0" > "$STAGE/sctest_speed.txt"
mkdir -p "$STAGE/LuaUI/Config" && cp "$STAGE"/sctest_*.txt "$STAGE/LuaUI/Config/" # BAR 31614+ reads only under LuaUI/
# OVERLAY=<file>: every game starts with these learned rules (cmd/learn overlay; the widget reads it)
[ -n "$OVERLAY" ] && cp "$OVERLAY" "$STAGE/LuaUI/Config/sc_learned.json" && echo "overlay: $OVERLAY" >> "$DIR/meta.txt"
R="bar-sim/batches/$STAMP-$LABEL"
ssh "$HOST" "mkdir -p $R"
rsync -a "$STAGE/" "$HOST:$R/template/"
scp -q "$T/force/run_game.sh" "$HOST:bar-sim/run_game.sh"
rm -rf "$STAGE"
# wall-clock limit per game: the game at 2x (late games with big armies slow down a lot, more with
# several games sharing the CPU), plus loading. A tight limit (660 s for 60 minutes) killed the long,
# even games and kept the quick decisive ones: a biased batch.
LIMIT=$(( DUEL_MINUTES * 60 / 2 + 300 ))
start=$(date +%s)
ssh -n "$HOST" "cd \$HOME/$R && seq 1 $N | xargs -P $PARALLEL -I{} bash \$HOME/bar-sim/run_game.sh \$HOME/$R {} $LIMIT"
fi
set +e # collecting: a missing file or an empty grep isn't fatal
rsync -a "$HOST:$R/" "$DIR/remote/" --include='g*/' --include='sctest_out.txt' --include='run.log' --include='exit.txt' --exclude='*'
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
wins=$(grep -c "game [0-9]*: WIN" "$DIR/results.txt" || true)
losses=$(grep -c "game [0-9]*: LOSS" "$DIR/results.txt" || true)
timeouts=$(grep -c "game [0-9]*: TIMEOUT" "$DIR/results.txt" || true)
echo "ran: $ran/$N in $(( ($(date +%s) - start) / 60 )) min" >> "$DIR/meta.txt"
crashed=$(grep -c "WIDGET CRASHED" "$DIR/results.txt" || true)
[ "$crashed" -gt 0 ] && echo "WARNING: the Sub-Commanders widget crashed in $crashed games: results are invalid" | tee -a "$DIR/meta.txt"
echo "$SCENARIO vs $AI_PROFILE ${MAP:-All That Simmers}: $ran/$N ran: $wins won, $timeouts alive at $DUEL_MINUTES min, $losses lost" | tee -a "$DIR/meta.txt"
(cd "$T/.." && go run ./cmd/gamereport -title "Batch $(basename "$DIR")" "$DIR") > "$DIR/report.md" 2>&1
echo "report: $DIR/report.md"
sed -n '/^## Findings/,$p' "$DIR/report.md"
