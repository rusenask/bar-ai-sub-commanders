#!/bin/bash
# usage: play/vs.sh   (all settings optional: [MAP="..."] [YOU=Armada] [BOT=Cortex] [BOT_AI=0] [BARB=...])
#
# A local 1v1 against sub-commanders: your BAR hosts the game and a second, small BAR window joins as the
# bot player, whose whole team is run by sub-commanders (gui_subcommanders_autopilot.lua). macOS.
#
#   MAP      map name as in BAR's archive cache (default All That Simmers v1.1.1)
#   YOU/BOT  factions: Armada, Cortex, Legion (default: you Armada, the bot a random one)
#   BOT_AI   default 1: the bot's sub-commanders use the AI strategist, through their own bridge on port
#            7879 (the scbridge-bot service, started by make up; without it they play on rules alone).
#            0 = rules only
#   BARB     add a BARbarian AI on your side (ally:<profile>) or the bot's (enemy:<profile>)
#   HOST_DIR write dir of the hosting game (default: your BAR install, with your settings and widgets)
#   SCENARIO with HOST_DIR=testenv: the test harness scenario the host plays (self-play tests)
#   TIMEOUT  seconds before both games are stopped (default 3 hours)
P="$(cd "$(dirname "$0")" && pwd)"
ROOT="$P/.."
APP="/Applications/BAR Launcher.app/Contents"
RES="$APP/Resources"
BAR="$HOME/Library/Application Support/Beyond-All-Reason-mac"
ICD="$RES/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"
export EGL_PLATFORM=surfaceless VK_ICD_FILENAMES="$ICD" VK_DRIVER_FILES="$ICD" GALLIUM_DRIVER=zink \
       MESA_LOADER_DRIVER_OVERRIDE=zink MESA_GL_VERSION_OVERRIDE=4.6 DYLD_FALLBACK_LIBRARY_PATH="$APP/Frameworks"
MAP="${MAP:-All That Simmers v1.1.1}"
GAME="${GAME:-$(sed -n 's/^ *gametype=\(.*\);/\1/p' "$ROOT/testenv/script_vsai.txt")}"
PORT="${PORT:-8452}"
NAME="${NAME:-Player}"
HOST_DIR="${HOST_DIR:-$BAR}"
BOTDIR="$P/bot"
YOU="${YOU:-Armada}"
FACTIONS=(Armada Cortex Legion)
BOT="${BOT:-${FACTIONS[$((RANDOM % 3))]}}"
TIMEOUT="${TIMEOUT:-10800}"

# the bot: its own write dir, small window, our widgets with the autopilot on
mkdir -p "$BOTDIR/LuaUI/Widgets" "$BOTDIR/LuaUI/Include"
[ -f "$BOTDIR/springsettings.cfg" ] || {
	sed -e 's/XResolutionWindowed = .*/XResolutionWindowed = 640/' -e 's/YResolutionWindowed = .*/YResolutionWindowed = 400/' \
		-e 's/WindowPosX = .*/WindowPosX = 20/' -e 's/WindowPosY = .*/WindowPosY = 600/' "$ROOT/testenv/springsettings.template.cfg" > "$BOTDIR/springsettings.cfg"
}
cp "$ROOT"/widget/LuaUI/Widgets/gui_subcommanders.lua "$ROOT"/widget/LuaUI/Widgets/gui_subcommanders_ai.lua "$BOTDIR/LuaUI/Widgets/"
sed 's/enabled = false,/enabled = true,/' "$ROOT/widget/LuaUI/Widgets/gui_subcommanders_autopilot.lua" > "$BOTDIR/LuaUI/Widgets/gui_subcommanders_autopilot.lua"
cp "$ROOT"/widget/LuaUI/Include/sc_*.lua "$BOTDIR/LuaUI/Include/"
# the bot's own bridge for the AI strategist: the test bridge, or another port when the test harness hosts
# (a new connection replaces the old one, so two games can't share a bridge)
BOT_BRIDGE="${BOT_BRIDGE:-127.0.0.1:$([ -n "$SCENARIO" ] && echo 17879 || echo 7879)}"
sed -i '' "s/^SubCommandersBridge = .*/SubCommandersBridge = $BOT_BRIDGE/" "$BOTDIR/springsettings.cfg"
# the bot's window stays small and windowed (BAR rewrites the file and can drop these)
for kv in "Fullscreen 0" "WindowBorderless 0" "WindowState 0" "XResolutionWindowed 640" "YResolutionWindowed 400"; do
	set -- $kv
	if grep -q "^$1 = " "$BOTDIR/springsettings.cfg"; then sed -i '' "s/^$1 = .*/$1 = $2/" "$BOTDIR/springsettings.cfg"; else echo "$1 = $2" >> "$BOTDIR/springsettings.cfg"; fi
done
[ "${BOT_AI:-1}" = 1 ] && echo ai > "$BOTDIR/autopilot.txt" || echo rules > "$BOTDIR/autopilot.txt"
rm -f "$BOTDIR/LuaUI/Config/BYAR.lua" # fresh widget state: no saved sub-commanders

ai_section=""
ally_you=0
ally_bot=1
if [ -n "$BARB" ]; then
	side="${BARB%%:*}" profile="${BARB#*:}"
	[ "$side" = ally ] && barb_ally=0 || barb_ally=1
	ai_section="
  [team2] { teamleader=0; allyteam=$barb_ally; side=$([ "$side" = ally ] && echo "$YOU" || echo "$BOT"); }
  [ai0] { shortname=BARb; version=stable; team=2; host=0; name=BARbarian; [options] { profile=${profile:-hard}; } }"
fi

cat > "$P/host_script.txt" <<EOF
[game]
{
  gametype=$GAME;
  mapname=$MAP;
  ishost=1;
  hostip=127.0.0.1;
  hostport=$PORT;
  myplayername=$NAME;
  startpostype=0;
  [player0] { name=$NAME; team=0; spectator=0; }
  [player1] { name=SubCommanders; team=1; spectator=0; }
  [team0] { teamleader=0; allyteam=$ally_you; side=$YOU; }
  [team1] { teamleader=1; allyteam=$ally_bot; side=$BOT; }$ai_section
  [allyteam0] { numallies=0; }
  [allyteam1] { numallies=0; }
  [modoptions] { experimentallegionfaction=1; }
}
EOF
cat > "$BOTDIR/join_script.txt" <<EOF
[game]
{
  hostip=127.0.0.1;
  hostport=$PORT;
  ishost=0;
  myplayername=SubCommanders;
}
EOF

run() { # run <write dir> <datadirs> <script> <log>
	SPRING_DATADIR="$2" perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$APP/MacOS/spring" --window --write-dir "$1" "$3" > "$4" 2>&1
}

echo "hosting: $NAME ($YOU) vs SubCommanders ($BOT, $(cat "$BOTDIR/autopilot.txt")) on $MAP${BARB:+, BARbarian $BARB}"
if [ -n "$SCENARIO" ]; then
	# self-play test: the test harness hosts (testenv/run.sh: isolated write dir, scenario, logs)
	(cd "$ROOT/testenv" && ./run.sh "$P/host_script.txt" "$TIMEOUT" "$SCENARIO" > /dev/null 2>&1) &
else
	run "$HOST_DIR" "$RES" "$P/host_script.txt" "$P/host.log" &
fi
host=$!
sleep 8
run "$BOTDIR" "$RES:$BAR" "$BOTDIR/join_script.txt" "$P/bot.log" &
bot=$!
wait $host
sleep 5
kill $bot 2>/dev/null
wait $bot 2>/dev/null
echo "done (logs: play/host.log, play/bot.log)"
