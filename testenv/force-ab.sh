#!/bin/bash
# usage: [GAMES=48] [SIDES="Cortex Legion"] testenv/force-ab.sh <name> <base commit> [<new commit>]
# An interleaved A/B on force for each faction in turn (one batch at a time): A = the base commit's
# widgets, B = the new commit's (default: the working tree), BAR_TRACK=0. Then pools the halves:
#   make compare ARMS="/tmp/pool-<name>-A /tmp/pool-<name>-B"
# Per faction: testenv/batch/<stamp>-force-<name>-<side>-A / -B. Logs: /tmp/force-<name>-<side>.log.
# Two factions x 48 games take ~105 min (more when force is busy): run it in the background with room to
# spare over a 2-hour limit, or one SIDES at a time.
set -e
T="$(cd "$(dirname "$0")" && pwd)"
name="$1" base="$2" new="$3"
[ -n "$name" ] && [ -n "$base" ] || { sed -n 2,5p "$0" >&2; exit 1; }
# the host is on the personal tailnet: with Tailscale switched to another one it doesn't resolve
ssh -o ConnectTimeout=10 -o BatchMode=yes "${FORCE_HOST:-force}" true 2>/dev/null || { echo "force-ab.sh: ${FORCE_HOST:-force} unreachable (Tailscale on the right tailnet?)" >&2; exit 1; }
A=$("$T/arm.sh" "$name-base" "$base")
B=$("$T/arm.sh" "$name-new" $new)
diff -rq "${A%/Widgets}" "${B%/Widgets}" >/dev/null && { echo "force-ab.sh: both arms are the same" >&2; exit 1; }
batches=()
for side in ${SIDES:-Cortex Legion}; do
	s=$(echo "$side" | tr '[:upper:]' '[:lower:]')
	BAR_TRACK=0 PARALLEL=${PARALLEL:-6} WIDGET_SRC="$A" WIDGET_SRC_B="$B" SIDE="$side" LABEL="force-$name-$s" \
		"$T/force-batch.sh" "${GAMES:-48}" > "/tmp/force-$name-$s.log" 2>&1 || echo "force-ab.sh: $side batch failed (/tmp/force-$name-$s.log)" >&2
	d=$(ls -d "$T"/batch/*-force-"$name-$s" 2>/dev/null | tail -1)
	[ -n "$d" ] && batches+=("$d") && tail -2 "$d/meta.txt"
done
"$T/pool-pairs.sh" "$name" "${batches[@]}"
