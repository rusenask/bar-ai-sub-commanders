#!/bin/bash
# usage: [AI_PROFILE=medium] [MAP="..."] [WORKER=n] run.sh <script.txt> [timeout_sec] [scenario]
# Runs a test skirmish in an isolated write dir: testenv/ itself, or testenv/workers/<n>/ with WORKER=n
# (testenv/worker.sh prepares one; batches run several at once). Prints exit=<code>; 124 = stalled.
#
#   timeout_sec  wall-clock limit (default: twice the game's length at SPEED, plus 3 minutes)
#   STALL        seconds without a new harness log line before the game counts as hung (default 120,
#                600 with LOCKSTEP=1: the game pauses while the strategist thinks)
T="$(cd "$(dirname "$0")" && pwd)"
W="$T"
if [ -n "$WORKER" ]; then
	W="$T/workers/$WORKER"
	[ -d "$W" ] || "$T/worker.sh" "$WORKER" >/dev/null
fi
APP="/Applications/BAR Launcher.app/Contents"
RES="$APP/Resources"
BAR="$HOME/Library/Application Support/Beyond-All-Reason-mac"
ICD="$RES/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"
export EGL_PLATFORM=surfaceless VK_ICD_FILENAMES="$ICD" VK_DRIVER_FILES="$ICD" GALLIUM_DRIVER=zink \
       MESA_LOADER_DRIVER_OVERRIDE=zink MESA_GL_VERSION_OVERRIDE=4.6 DYLD_FALLBACK_LIBRARY_PATH="$APP/Frameworks"
rm -f "$W/infolog.txt" "$W/sctest_out.txt"
[ -f "$W/springsettings.cfg" ] || cp "$T/springsettings.template.cfg" "$W/springsettings.cfg"
# a small window, never fullscreen: BAR rewrites springsettings.cfg and can drop these, so set them each run
setcfg() { # setcfg <key> <value>
	if grep -q "^$1 = " "$W/springsettings.cfg"; then sed -i '' "s/^$1 = .*/$1 = $2/" "$W/springsettings.cfg"; else echo "$1 = $2" >> "$W/springsettings.cfg"; fi
}
setcfg Fullscreen 0
setcfg WindowBorderless 0
setcfg WindowState 0
setcfg XResolutionWindowed "${WINDOW_W:-800}"
setcfg YResolutionWindowed "${WINDOW_H:-500}"
# workers tile their windows across the screen
setcfg WindowPosX $((40 + ${WORKER:-0} % 3 * 420))
setcfg WindowPosY $((40 + ${WORKER:-0} / 3 % 2 * 300))
# test games talk to the test bridge (make test-bridge), never to the one a real game uses; workers to
# ports of their own (nothing listens there: rules-only games don't need a bridge)
setcfg SubCommandersBridge "127.0.0.1:$((17878 + ${WORKER:-0} * 2))"
# AI_PROFILE=easy|medium|hard|hard_aggressive overrides the BARbarian profile in the script
SCRIPT="$1"
# MAP="Altair Crossing v4.1" overrides the map
if [ -n "$AI_PROFILE" ] || [ -n "$MAP" ]; then
	sed -e "s/profile=[a-z_]*;/profile=${AI_PROFILE:-hard};/" -e "s/mapname=[^;]*;/mapname=${MAP:-All That Simmers v1.1.1};/" "$1" > "$W/_script_run.txt"
	SCRIPT="$W/_script_run.txt"
fi
# WIDGET_SRC=/path/to/Widgets runs another version of the widgets (A/B tests)
mkdir -p "$W/LuaUI/Widgets" "$W/LuaUI/Include"
cp "${WIDGET_SRC:-$T/../widget/LuaUI/Widgets}"/gui_subcommanders*.lua "$W/LuaUI/Widgets/"
cp "${WIDGET_SRC:-$T/../widget/LuaUI/Widgets}"/../Include/sc_*.lua "$W/LuaUI/Include/" 2>/dev/null || cp "$T"/../widget/LuaUI/Include/sc_*.lua "$W/LuaUI/Include/"
# the harness and the data logger (testenv/LuaUI/Widgets is their source)
[ "$W" != "$T" ] && cp "$T"/LuaUI/Widgets/zz_*.lua "$W/LuaUI/Widgets/"
# the autopilot scenario plays the team with the Sub-Commanders Autopilot widget (off by default)
[ "$3" = autopilot ] && sed -i '' 's/enabled = false,/enabled = true,/' "$W/LuaUI/Widgets/gui_subcommanders_autopilot.lua"
[ -n "$3" ] && echo "$3" > "$W/sctest_scenario.txt"
# SPEED=10 runs the game that fast (as far as the machine keeps up); LOCKSTEP=1 pauses it while the
# AI strategist is thinking, so it sees the game as often as at normal speed
echo "${SPEED:-} ${LOCKSTEP:-0}" > "$W/sctest_speed.txt"
# duels last DUEL_MINUTES (default 60: at 45 games were still being decided, some won after 40)
echo "${DUEL_MINUTES:-60}" > "$W/sctest_minutes.txt"
cd "$W"
# fresh widget state each run: re-enable and forget saved sub-commanders
python3 - "$W/LuaUI/Config/BYAR.lua" <<'PY'
import re, sys
p = sys.argv[1]
try:
    s = open(p).read()
except FileNotFoundError:
    sys.exit()
s = re.sub(r'\n\t\t\["Sub-Commanders"\] = \{.*?\n\t\t\},', '', s, flags=re.S)
s = re.sub(r'\["Sub-Commanders"\] = 0,', '["Sub-Commanders"] = 1001,', s)
# the autopilot's enabled state comes from the widget file (run.sh enables it for its scenario only)
s = re.sub(r'\n\s*\["Sub-Commanders Autopilot"\] = \d+,', '', s)
open(p, "w").write(s)
PY
# wall-clock limit: twice the game at the requested speed plus loading, unless given
SPEEDX="${SPEED:-3}"
LIMIT="${2:-$(( ${DUEL_MINUTES:-60} * 60 * 2 / SPEEDX + 180 ))}"
[ "${LOCKSTEP:-0}" = 1 ] && [ -z "$2" ] && LIMIT=$((LIMIT * 4))
STALL="${STALL:-$([ "${LOCKSTEP:-0}" = 1 ] && echo 600 || echo 120)}"
# at lower priority (NICE, default 10): the machine stays usable for other work while tests run
SPRING_DATADIR="$RES:$BAR" BAR_INFOLOG="$W/infolog.txt" nice -n "${NICE:-10}" perl -e 'alarm shift; exec @ARGV' "$LIMIT" \
	"$APP/MacOS/spring" --window --write-dir "$W" "$SCRIPT" > "$W/run.log" 2>&1 &
pid=$!
# watchdog: the harness writes a line at least every 30 game seconds; nothing new for STALL seconds
# (once the game has started) means it hung
stalled=0
launched=$(date +%s)
while kill -0 "$pid" 2>/dev/null; do
	sleep 5
	# loading hangs too (seen with several games loading at once): no harness output within LOADMAX
	if [ ! -f "$W/sctest_out.txt" ] && [ $(( $(date +%s) - launched )) -gt "${LOADMAX:-150}" ]; then
		echo "stalled: the game didn't start within ${LOADMAX:-150}s" >> "$W/run.log"
		kill "$pid" 2>/dev/null
		stalled=1
		break
	fi
	if [ -f "$W/sctest_out.txt" ]; then
		age=$(( $(date +%s) - $(stat -f %m "$W/sctest_out.txt") ))
		if [ "$age" -gt "$STALL" ]; then
			echo "stalled: no harness output for ${age}s" >> "$W/run.log"
			kill "$pid" 2>/dev/null
			pkill -f -- "--write-dir $W " 2>/dev/null
			stalled=1
			break
		fi
	fi
done
wait "$pid" 2>/dev/null
code=$?
[ "$stalled" = 1 ] && code=124
echo "exit=$code"
