#!/bin/bash
# usage: testenv/unit-catalogue.sh [out.jsonl]
# Dumps every unit definition of the installed BAR game (abilities, economy, intel, builds, weapons) by
# starting a headless game on force with zz_defsdump.lua, and copies it to <out> (default
# docs/research/units.jsonl). Then: python3 scripts/unit_catalogue.py (docs/research/units.md).
set -e
T="$(cd "$(dirname "$0")" && pwd)"
HOST="${FORCE_HOST:-force}"
OUT="${1:-$T/../docs/research/units.jsonl}"
TPL=$(ssh -n "$HOST" 'ls -td ~/bar-sim/batches/*/template | head -1')
[ -n "$TPL" ] || { echo "unit-catalogue.sh: no batch template on $HOST (run a force batch first)" >&2; exit 1; }
scp -q "$T/LuaUI/Widgets/zz_defsdump.lua" "$HOST:/tmp/zz_defsdump.lua"
ssh -n "$HOST" "rm -rf /tmp/defsdump && cp -r $TPL /tmp/defsdump && rm -rf /tmp/defsdump/armB /tmp/defsdump/battles \
	&& cp /tmp/zz_defsdump.lua /tmp/defsdump/LuaUI/Widgets/ && mkdir -p /tmp/defsdump/LuaUI/Config \
	&& touch /tmp/defsdump/defsdump.txt /tmp/defsdump/LuaUI/Config/defsdump.txt && cd /tmp/defsdump \
	&& SPRING_DATADIR=\$HOME/bar-sim/data:\$HOME/bar-sim/engine timeout 300 \$HOME/bar-sim/engine/spring-headless \
	--write-dir /tmp/defsdump /tmp/defsdump/script.txt > run.log 2>&1; true"
scp -q "$HOST:/tmp/defsdump/defsdump.jsonl" "$OUT" 2>/dev/null || scp -q "$HOST:/tmp/defsdump/LuaUI/Config/defsdump.jsonl" "$OUT"
echo "$(wc -l < "$OUT") units in $OUT"
