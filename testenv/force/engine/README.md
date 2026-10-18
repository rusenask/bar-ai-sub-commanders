# Engine builds and profiling for faster test games (force)

See docs/research/speed.md ("The engine itself").

- Source: `~/recoil-src` on force (`git clone --branch 2026.07.04 --recurse-submodules` of
  beyond-all-reason/RecoilEngine, the version BAR uses). Build: `docker-build-v2/build.sh -j 12 linux
  [cmake flags]`; the result is `build-amd64-linux/install`, a full engine dir (BARb included). Copy it to
  `~/bar-sim/engine-<name>` and pass `ENGINE=/home/karolis/bar-sim/engine-<name>` to
  `testenv/force-speedbench.sh`.
- `recoil-no-scoped-timers.patch`: with `-DCMAKE_CXX_FLAGS=-DRECOIL_NO_SCOPED_TIMERS` the per-scope profiler
  timers compile to nothing (special Sim/Draw timers stay). `debuginfo profiling` shows only those.
- `perf_game.sh <bench dir> <perf.data>` (copy to ~/bar-sim/): one game of a force-speedbench template under
  `perf record`, lowering `kernel.perf_event_paranoid` for the run only (force keeps 4). `PERF_ARGS="-j
  any_call,u"` records branches; `brcallers.py <perf.data> <binary> "<symbol>"` lists who calls a function
  (needs a build with symbols; the official binary is stripped).
