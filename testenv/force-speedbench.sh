#!/bin/bash
# usage: [PAR=6] [GAMES=PAR] [MINUTES=20] [DEMO=testenv/speeddemo/late30.sdfz | LIVE=1] [SPRING_CFG="K=V ..."]
#        [WIDGETS=minimal|all] [FORCE_HOST=force] testenv/force-speedbench.sh <label>
# How fast games run on the force host (docs/research/speed.md): GAMES games, PAR at a time, headless. By
# default the same recorded game (DEMO) every time, so settings compare like for like; LIVE=1 plays duelrules
# vs medium instead. WIDGETS turns BAR's interface widgets off (speed_widgets.py). Prints each game's speed
# over minutes 2..MINUTES (from the harness's "speed minute=" lines) and the mean, appends to
# testenv/speedbench.tsv. Failed games' logs stay in ~/bar-sim/speedbench/<label>/g<i>/ on force.
T="$(cd "$(dirname "$0")" && pwd)"
LABEL="${1:?label}"
PAR="${PAR:-6}"
GAMES="${GAMES:-$PAR}"
MINUTES="${MINUTES:-20}"
HOST="${FORCE_HOST:-force}"
ssh -n -o ConnectTimeout=5 "$HOST" true 2>/dev/null || { echo "force-speedbench.sh: $HOST unreachable (tailnet?)" >&2; exit 1; }
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/LuaUI/Widgets" "$STAGE/LuaUI/Include" "$STAGE/LuaUI/Config"
cp "$T"/../widget/LuaUI/Widgets/gui_subcommanders*.lua "$STAGE/LuaUI/Widgets/"
cp "$T"/../widget/LuaUI/Include/sc_*.lua "$STAGE/LuaUI/Include/"
sed 's/setmaxspeed 20/setmaxspeed 1000/g; s/setmaxspeed 40/setmaxspeed 1000/g' "$T/LuaUI/Widgets/zz_sctest.lua" > "$STAGE/LuaUI/Widgets/zz_sctest.lua"
cp "$T/springsettings.template.cfg" "$STAGE/springsettings.cfg"
for kv in ${SPRING_CFG:-}; do echo "${kv%%=*} = ${kv#*=}" >> "$STAGE/springsettings.cfg"; done
[ -n "$WIDGETS" ] && python3 "$T/speed_widgets.py" --new "$STAGE/LuaUI/Config/BYAR.lua" "$WIDGETS"
echo "1000 0" > "$STAGE/LuaUI/Config/sctest_speed.txt"
if [ -n "$LIVE" ]; then
	sed -e "s/profile=[a-z_]*;/profile=medium;/" "$T/script_vsai.txt" > "$STAGE/script.txt"
	echo duelrules > "$STAGE/LuaUI/Config/sctest_scenario.txt"
	echo "$MINUTES" > "$STAGE/LuaUI/Config/sctest_minutes.txt"
else
	cp "${DEMO:-$T/speeddemo/late30.sdfz}" "$STAGE/demo.sdfz"
	echo replay > "$STAGE/LuaUI/Config/sctest_scenario.txt"
	echo $(( MINUTES * 1800 )) > "$STAGE/LuaUI/Config/sctest_replayend.txt"
fi
cp "$STAGE"/LuaUI/Config/sctest_*.txt "$STAGE/" # older game versions read the write dir's root
R="bar-sim/speedbench/$LABEL"
ssh -n "$HOST" "rm -rf $R && mkdir -p $R"
rsync -a "$STAGE/" "$HOST:$R/template/"
scp -q "$T/force/speed_game.sh" "$HOST:bar-sim/speed_game.sh"
rm -rf "$STAGE"
ssh -n "$HOST" "cd \$HOME/$R && seq 1 $GAMES | xargs -P $PAR -I{} bash \$HOME/bar-sim/speed_game.sh \$HOME/$R {} $(( MINUTES * 60 + 300 ))"
ssh -n "$HOST" "cd $R && for g in g*; do echo \"\$g \$(cat \$g/exit.txt) \$(grep 'speed minute=' \$g/sctest_out.txt | awk '{for(i=1;i<=NF;i++){split(\$i,a,\"=\");v[a[1]]=a[2]} if(v[\"minute\"]>1){w+=v[\"wall\"];n++}} END{if(w>0)printf \"x=%.1f sim-wall=%.1f\", n*60/w, w}')\"; done" |
	tee /dev/stderr | awk -v l="$LABEL" -v cfg="${SPRING_CFG:-}${WIDGETS:+ widgets:$WIDGETS}${LIVE:+ live}" '{for(i=1;i<=NF;i++){split($i,a,"="); if(a[1]=="x"&&a[2]!=""){s+=a[2];n++}}} END{printf "%s: mean x=%.1f over %d games  [force PAR=%s %s]\n", l, (n?s/n:0), n, ENVIRON["PAR"], cfg}' | tee -a "$T/speedbench.tsv"
