#!/bin/bash
# usage: split-arms.sh <batch dir> <widgets A> <widgets B>
# An interleaved batch (odd games arm A, even games arm B, each pair the same battle spec on the same
# machine) into <batch dir>-A and <batch dir>-B, for make compare (paired verdicts).
DIR="$1"
for arm in A B; do
	D="$DIR-$arm"
	rm -rf "$D" && mkdir -p "$D"
	k=0
	for f in $(ls "$DIR"/[0-9]*.txt 2>/dev/null | sort -t/ -k2 -V); do
		i=$(basename "$f" .txt)
		if { [ "$arm" = A ] && [ $((i % 2)) = 1 ]; } || { [ "$arm" = B ] && [ $((i % 2)) = 0 ]; }; then
			cp "$f" "$D/$(( (i + 1) / 2 )).txt"
			k=$((k + 1))
		fi
	done
	w=$([ "$arm" = A ] && echo "$2" || echo "$3")
	printf 'label: %s-%s\nwidgets: %s\ninterleaved: %s\n' "$(basename "$DIR")" "$arm" "$w" "$(basename "$DIR")" > "$D/meta.txt"
	echo "arm $arm: $k games in $D"
done
