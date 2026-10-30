#!/bin/bash
# usage: testenv/widget-check.sh <game's run.log> <game's result file>
# Our widgets' Lua errors in one game's spring log, for the batch scripts' result line. Prints
#   " | WIDGET CRASHED"    an error nothing caught: BAR removed the widget, the game went on without it
#                          (looks like a plain loss): the game's result is invalid
#   " | WIDGET ERRORS <n>" n distinct errors sc_guard.lua caught and skipped: the game ran on, the
#                          errors need fixing (make errors)
# and appends the first lines to the result file as [widget-error]. Prints nothing for a clean game.
log=$1 out=$2
crash=$(grep -E "Error in .*(gui_subcommanders|sc_[a-z]+\.lua)|Removed widget: Sub-Commanders" "$log" 2>/dev/null | head -5)
caught=$(grep -E "Sub-Commanders ERROR \(" "$log" 2>/dev/null)
{ echo "$crash"; echo "$caught" | head -5; } | grep . | sed 's/^/[widget-error] /' >> "$out"
if [ -n "$crash" ]; then
	echo " | WIDGET CRASHED"
elif [ -n "$caught" ]; then
	echo " | WIDGET ERRORS $(echo "$caught" | grep -c ', 1x)')"
fi
