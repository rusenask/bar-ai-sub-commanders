#!/bin/bash
# usage: pool-pairs.sh <name> <interleaved batch>... (each with -A and -B halves)
# Pools interleaved batches (e.g. the same A/B on force and in sandboxes) into /tmp/pool-<name>-A and -B,
# keeping each pair's number the same on both sides, so make compare gives one paired verdict:
#   make compare ARMS="/tmp/pool-<name>-A /tmp/pool-<name>-B"
name="$1"
shift
for arm in A B; do
	out="/tmp/pool-$name-$arm"
	rm -rf "$out" && mkdir -p "$out"
	k=0
	for d in "$@"; do
		n=0
		for f in "$d-$arm"/[0-9]*.txt; do
			i=$(basename "$f" .txt)
			cp "$f" "$out/$((k + i)).txt"
			n=$((n + 1))
		done
		k=$((k + n))
	done
	echo "label: pool-$name-$arm" > "$out/meta.txt"
	echo "$out: $k games"
done
