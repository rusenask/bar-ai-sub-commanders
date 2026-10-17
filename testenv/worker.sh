#!/bin/bash
# usage: testenv/worker.sh <n>
# Prepares testenv/workers/<n>/, a separate write dir for running test games in parallel (run.sh
# WORKER=<n>): settings, the widget config and the archive cache from testenv/ (so the engine doesn't
# rescan every archive). Safe to run again: it refreshes the copies.
set -e
T="$(cd "$(dirname "$0")" && pwd)"
W="$T/workers/$1"
mkdir -p "$W/LuaUI/Widgets" "$W/LuaUI/Include" "$W/LuaUI/Config"
cp "$T/springsettings.template.cfg" "$W/springsettings.cfg"
cp -R "$T/cache" "$W/" 2>/dev/null || true
cp "$T"/LuaUI/Config/*.lua "$W/LuaUI/Config/" 2>/dev/null || true
rm -f "$W/LuaUI/Config/BYAR.lua.full" # run.sh FAST's copy of the full widget config: the fresh one wins
cp "$T"/LuaUI/Widgets/zz_*.lua "$W/LuaUI/Widgets/"
echo "$W"
