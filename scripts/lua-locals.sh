#!/bin/bash
# usage: scripts/lua-locals.sh file.lua...
# Fails when a file's main chunk declares too many locals: BAR's Lua 5.1 refuses to load it ("main
# function has more than 200 local variables") and the widget is gone; the Lua installed here allows more,
# so luac -p doesn't catch it. Counts the names in unindented `local ...` lines (the main chunk's own).
LIMIT="${LIMIT:-195}"
fail=0
for f in "$@"; do
	n=$(grep -E '^local ' "$f" | sed -E 's/--.*//; s/^local function ([A-Za-z_][A-Za-z0-9_]*).*/\1/; s/^local ([^=]*)(=.*)?$/\1/' | tr ',' '\n' | grep -c '[A-Za-z_]')
	if [ "$n" -gt "$LIMIT" ]; then
		echo "$f: $n main-chunk locals (BAR's Lua allows 200; keep under $LIMIT: put new ones in a table such as Engine)"
		fail=1
	fi
done
exit $fail
