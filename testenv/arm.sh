#!/bin/bash
# usage: testenv/arm.sh <name> [commit]
# Freezes the widgets (widget/LuaUI/Widgets + Include) of a commit (default: the working tree) into
# /tmp/arm-<name>/ for an A/B batch, and prints the WIDGET_SRC to use:
#   WIDGET_SRC=$(testenv/arm.sh baseline 310182e) LABEL=baseline testenv/batch.sh 8
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="/tmp/arm-$1"
rm -rf "$DIR"
mkdir -p "$DIR/Widgets" "$DIR/Include"
if [ -z "$2" ]; then
	cp "$ROOT"/widget/LuaUI/Widgets/*.lua "$DIR/Widgets/"
	cp "$ROOT"/widget/LuaUI/Include/*.lua "$DIR/Include/"
else
	for sub in Widgets Include; do
		for f in $(git -C "$ROOT" ls-tree --name-only "$2" "widget/LuaUI/$sub/"); do
			git -C "$ROOT" show "$2:$f" > "$DIR/$sub/$(basename "$f")"
		done
	done
fi
echo "$DIR/Widgets"
