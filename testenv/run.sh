#!/bin/bash
# usage: [AI_PROFILE=medium] run.sh <script.txt> [timeout_sec] [scenario]  -- runs a test skirmish in an isolated write dir
T="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/BAR Launcher.app/Contents"
RES="$APP/Resources"
BAR="$HOME/Library/Application Support/Beyond-All-Reason-mac"
ICD="$RES/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"
export EGL_PLATFORM=surfaceless VK_ICD_FILENAMES="$ICD" VK_DRIVER_FILES="$ICD" GALLIUM_DRIVER=zink \
       MESA_LOADER_DRIVER_OVERRIDE=zink MESA_GL_VERSION_OVERRIDE=4.6 DYLD_FALLBACK_LIBRARY_PATH="$APP/Frameworks"
rm -f "$T/infolog.txt"
[ -f "$T/springsettings.cfg" ] || cp "$T/springsettings.template.cfg" "$T/springsettings.cfg"
# test games talk to the test bridge (make test-bridge), never to the one a real game uses
grep -q '^SubCommandersBridge' "$T/springsettings.cfg" || echo "SubCommandersBridge = 127.0.0.1:17878" >> "$T/springsettings.cfg"
# AI_PROFILE=easy|medium|hard|hard_aggressive overrides the BARbarian profile in the script
SCRIPT="$1"
if [ -n "$AI_PROFILE" ]; then
  sed "s/profile=[a-z_]*;/profile=$AI_PROFILE;/" "$1" > "$T/_script_run.txt"
  SCRIPT="$T/_script_run.txt"
fi
cp "$T"/../widget/LuaUI/Widgets/gui_subcommanders*.lua "$T/LuaUI/Widgets/"
[ -n "$3" ] && echo "$3" > "$T/sctest_scenario.txt"
cd "$T"
# fresh widget state each run: re-enable and forget saved sub-commanders
python3 - "$T/LuaUI/Config/BYAR.lua" <<'PY'
import re, sys
p = sys.argv[1]
try:
    s = open(p).read()
except FileNotFoundError:
    sys.exit()
s = re.sub(r'\n\t\t\["Sub-Commanders"\] = \{.*?\n\t\t\},', '', s, flags=re.S)
s = re.sub(r'\["Sub-Commanders"\] = 0,', '["Sub-Commanders"] = 1001,', s)
open(p, "w").write(s)
PY
SPRING_DATADIR="$RES:$BAR" BAR_INFOLOG="$T/infolog.txt" perl -e 'alarm shift; exec @ARGV' "${2:-300}" \
  "$APP/MacOS/spring" --window --write-dir "$T" "$SCRIPT" > "$T/run.log" 2>&1
echo "exit=$?"
