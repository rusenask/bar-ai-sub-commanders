#!/bin/bash
# usage: [GAMES=2] [MINUTES=10] [SPRING_CFG="K=V ..."] [SPRING_ARGS=...] [PROFILE=1] [DEMO=file.sdfz] speedbench.sh <label>
# Measures how fast test games run on this machine (docs/research/speed.md): plays GAMES duelrules games
# of MINUTES at SPEED (1000: no cap) on worker 1 (fresh settings each game) and prints the average game-seconds per
# wall-second over minutes 2..MINUTES, plus the load time. Appends a row to testenv/speedbench.tsv.
# DEMO plays a recorded game instead (the same simulation every run: settings compare like for like; no AI or
# widget orders run, so it measures the engine, the gadgets, drawing and the widgets' upkeep), MINUTES of it.
T="$(cd "$(dirname "$0")" && pwd)"
LABEL="${1:?label}"
GAMES="${GAMES:-2}"
MINUTES="${MINUTES:-10}"
WK="${WORKER:-1}" # WORKER=n benchmarks on worker n (several at once: parallel throughput)
W="$T/workers/$WK"
for g in $(seq 1 "$GAMES"); do
	"$T/worker.sh" "$WK" >/dev/null
	rm -f "$W/LuaUI/Config/sctest_profile.txt" "$W/LuaUI/Config/sctest_fast.txt" "$W/LuaUI/Config/sctest_speedprof.txt"
	[ -n "$PROFILE" ] && echo "$PROFILE" > "$W/LuaUI/Config/sctest_profile.txt"
	[ -n "$PREP" ] && eval "$PREP" # a hook that edits the worker dir (e.g. disables widgets)
	start=$(date +%s)
	if [ -n "$DEMO" ]; then
		echo $(( MINUTES * 1800 )) > "$W/LuaUI/Config/sctest_replayend.txt"
		rc=$(SPEED="${SPEED:-1000}" WORKER="$WK" "$T/run.sh" "$DEMO" 900 replay | tail -1)
		rm -f "$W/LuaUI/Config/sctest_replayend.txt"
	else
		rc=$(AI_PROFILE=medium SPEED="${SPEED:-1000}" DUEL_MINUTES="$MINUTES" WORKER="$WK" "$T/run.sh" "$T/script_vsai.txt" 900 duelrules | tail -1)
	fi
	total=$(( $(date +%s) - start ))
	# keep a failed game's logs (testenv/speedbench-failed/): understand each failure before trusting a result
	if [ "$rc" != "exit=0" ]; then
		F="$T/speedbench-failed/$(date +%H%M%S)-$LABEL-w$WK-g$g"
		mkdir -p "$F" && cp "$W/infolog.txt" "$W/run.log" "$F/" 2>/dev/null
	fi
	out="$W/sctest_out.txt"
	# game seconds / wall seconds over minutes 2.. (minute 1 includes the opening's speed ramp)
	read -r x wall <<<"$(grep "speed minute=" "$out" | awk '{for(i=1;i<=NF;i++){split($i,a,"=");v[a[1]]=a[2]} if(v["minute"]>1){w+=v["wall"];n++}} END{if(w>0)printf "%.1f %.1f", n*60/w, w}')"
	[ -n "$PROFILE" ] && grep -E "^\[t=.*\]\s+(Draw|Sim|Lua::)" "$W/infolog.txt" | tail -6 | sed 's/^.*\] *//'
	echo "$LABEL w$WK game $g: $rc x=$x sim-wall=${wall}s total=${total}s"
	printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$(date '+%Y-%m-%d %H:%M')" "$LABEL" "$g" "$x" "$wall" "$total" "${SPRING_CFG:-}${SPRING_ARGS:+ args:$SPRING_ARGS}" >> "$T/speedbench.tsv"
done
