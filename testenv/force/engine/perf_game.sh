#!/bin/bash
# perf profile of one game (docs/research/speed.md): lowers perf_event_paranoid for the run only
E="${ENGINE:-$HOME/recoil-src/build-amd64-linux/install}"
D="$1"; OUT="$2"
trap "sudo -n sysctl -q kernel.perf_event_paranoid=4" EXIT
sudo -n sysctl -q kernel.perf_event_paranoid=1
rm -rf "$D/p" && cp -r "$D/template" "$D/p" && cd "$D/p" && echo "HostPortDefault = 8499" >> springsettings.cfg
what=$PWD/script.txt; [ -f demo.sdfz ] && what=$PWD/demo.sdfz
SPRING_DATADIR=$HOME/bar-sim/data:$E perf record -F 999 ${PERF_ARGS:-} --no-buildid -o "$OUT" -- $E/spring-headless --write-dir $PWD $what > run.log 2>&1
echo "rc=$?"
