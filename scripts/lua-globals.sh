#!/bin/bash
# usage: scripts/lua-globals.sh file.lua...
# Fails when a Lua file reads or writes a global that isn't an engine / BAR / Lua one. Calling a local
# function above its definition compiles to a global read and is nil at run time: BAR then removes the
# widget ("attempt to call global 'addUnit'"), and the games go on without it (v15-v17 lost that way).
ALLOWED=" _ CMD GL Game GameCMD Json Spring UnitDefNames UnitDefs VFS WG WeaponDefNames WeaponDefs gl widget widgetHandler socket
 ipairs pairs next select type tonumber tostring pcall xpcall debug error assert print setmetatable getmetatable rawget rawset unpack
 math string table os io "
ALLOWED=" $(echo $ALLOWED) "
fail=0
for f in "$@"; do
	for g in $(luac -l -p "$f" | grep -o '_ENV "[A-Za-z_][A-Za-z0-9_]*"' | sed 's/_ENV //; s/"//g' | sort -u); do
		case "$ALLOWED" in
		*" $g "*) ;;
		*)
			echo "$f: unknown global '$g' (a local used above its definition?)"
			luac -l -p "$f" | grep "_ENV \"$g\"" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*/  line /' | head -3
			fail=1
			;;
		esac
	done
done
exit $fail
