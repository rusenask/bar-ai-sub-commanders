# Faster test games

Goal: double or triple how fast test games run, first on the laptop (M4 Max, 16 cores, windowed engine
through zink), then carry what works to force (headless).

**Status (2026-10-18):** `FAST=1` (run.sh, batch.sh) bundles what works: `MinSimDrawBalance=0`, `Sound=0`,
BAR's interface widgets off. Use `FAST=1 WORKERS=6 SPEED=100 testenv/batch.sh <n>` on the laptop.

- One game: 15-minute duel 40x -> 80x; late game (replay, 300-800 units) 17x -> 25x.
- Six at once: late-game replay 15-18x -> 32-33x each; a live 60-minute batch of 12 games played 69 game
  seconds per wall second (7 minutes) against 43 for the same batch with default settings (1.6x), and
  against at most 15 for the old local default (`SPEED=15 WORKERS=1`): ~5x.
- Results unchanged as far as 58 games can tell (below).
- Force (headless, 12 cores): `FAST=1 testenv/force-batch.sh` = widgets off + 2 engine threads; live 46
  game seconds per wall second against 35 (1.3x), results unchanged against two default batches (below). Six
  late-game replays at once 12.5x -> 17.3x each; total throughput tops out at ~105 game seconds per wall
  second (4, 6 or 8 at once) against 75 for six default games: 1.4x. Four at once: 26x each.

## How to measure

- The harness logs `speed minute=<m> x=<game s per wall s> wall=<s> units=<n>` once a game minute.
- `testenv/speedbench.sh <label>`: GAMES (2) duelrules games of MINUTES (10) at SPEED (1000, no cap) on
  WORKER (1); prints the average speed over minutes 2.. and the total wall time, appends to
  `testenv/speedbench.tsv`, keeps failed games' logs in `testenv/speedbench-failed/`.
  `SPRING_CFG="K=V ..."` sets engine settings, `SPRING_ARGS` engine flags, `PREP` a shell hook on the
  worker dir (`$W`), `PROFILE=1` dumps the engine profiler (`debuginfo profiling`) into the infolog and the
  per-widget times (`zz_speedprof.lua`, via BAR's widget_profiling include) into
  `LuaUI/Config/sctest_speedprof.txt` every 5 game minutes (`PROFILE="nowidgets nogadgets noengine"` turns
  parts off), with our widget's time by callin, and by GameFrame step when the widget is an instrumented
  copy (`WIDGET_SRC`: wrap each call in GameFrame in `__P(name, f, ...)` that adds to `WG.scprof`). Several
  `WORKER=n` runs at once measure parallel throughput.
- `testenv/force-speedbench.sh <label>`: the same on force, headless: PAR replays at once (or `LIVE=1`),
  `SPRING_CFG`, `WIDGETS=minimal`; mean speed into `testenv/speedbench.tsv`.
- `DEMO=testenv/speeddemo/late30.sdfz` plays a recorded 30-minute game (783 units at the end) instead: the
  same simulation every run, so settings compare like for like (two runs: 17.0x and 17.2x). No AI or widget
  orders run in a replay, and replays pay synced Lua costs a live game doesn't (3.5 s vs 0.8 s per 10
  minutes), so confirm with live games.
- **Live games are not repeatable**: the same settings twice give different games (1500 differing log lines
  over 15 minutes), and a settings change changes the game's course; at 25-30 minutes single games differ
  by 1.5x in speed. Compare live games over several games, late-game settings on the replay.

## Where the time goes

Laptop, 10-minute live duel, defaults (profiler totals overlap: Lua runs inside Sim and Draw):

| Part | Total |
|---|---|
| Sim | 8.0 s |
| Lua callins, unsynced (LuaUI widgets + unsynced gadgets) | 8.4 s |
| Draw | 6.4 s |
| Lua callins, synced (gadgets) | 0.6 s |
| Lua GC | 1.3 s |

Plus ~16 s loading and ~3 s shutdown per game. Early on the pace is set by a fixed cost per frame
(drawing, widgets), late by the unit count: at 300-400 units both default and FAST run ~15x live.

Late game (30-minute live game, FAST minus widget pruning, profiled; the profiler slows it): Sim ~65% of
wall time, Draw ~20%, our Sub-Commanders widget ~11% (10 s of 90 s, the costliest widget by far), BAR
gadgets ~12% (synced 6.6%, unsynced 5.3%). The rest of Sim is the engine and BARbarian.

## Ideas and results

| Idea | Result | Status |
|---|---|---|
| `MinSimDrawBalance=0` (default 0.15: the engine keeps 15% of its time for drawing) | 10-minute: 44x -> 72x (2 games each); replay 17.2x -> 19.2x | **in FAST** |
| `MinDrawFPS=1`, `VSync=0` | no effect (44.6x, 45.2x) | dropped |
| `--hidden` (minimised window) | no effect (48x, 45x) | dropped |
| Camera at an empty corner, `hideinterface` | no effect (replay 24.0x vs 23.8x) | dropped |
| BAR's interface widgets off (`speed_widgets.py minimal`: keeps APIs and widgets that give orders) | 10-minute: 72x -> 87x; replay 19.2x -> 24.9x (incl. 37 widgets the saved config doesn't list) | **in FAST** |
| All widgets but ours off | no better than minimal (80x vs 87x) | dropped (riskier) |
| `WorkerThreadCount` cap (default: one per core) | one game: no change; six late-game replays at once: 2 threads 13.8x, 4 threads 22.9x, uncapped 33.3x / 31.8x (default settings 17.8x / 14.6x). An early live test (3 at once: 40x -> 65x with 3) was noise, and the second live pair with 2 threads ran no faster than default | **dropped** (`FAST_THREADS=n` still caps) |
| `Sound=0` | 6 at once: no load hangs in 36 starts (2 of 12 hung before) | **in FAST** |
| Gadget profiler (`luarules profile`) | replay 24x -> 36x (!), live 78x -> 53x: replay-only quirk | dropped |
| Disable BAR's visual gadgets (`disablegadget`, needs cheats; synced halves share names) | at most ~5% late | not tried: risky, small |
| Our widget's per-frame cost | 30-minute live game: 6.7 s of 45 s (15%): GameFrame 4.5 s (refreshWorld 1.9 s, the threat map 3x a second; Tactics.squad 0.7; runSub 0.6; Tactics.raid 0.3), DrawScreen + DrawWorldPreUnit 1.7 s (laptop only) | measured; not changed: halving it gains ~7% and touches AI code (needs its own A/B) |
| Loading (~16 s a game) and shutdown (~3 s) | | todo |
| End decided games early (mercy rule) | 5926 duelrules 60-minute games: every loss ends within ~0.5 min of our commander's death (nothing to cut); calling a loss earlier from our army value, income and killed/lost metal is wrong >=20% of the time (mostly games that reach 60 minutes) | **rejected** (our side's log can't call it) |
| Force: widgets off (generated BYAR.lua) | six replays at once 12.5x -> 14.3x | **in force FAST** |
| Force: `Sound=0` | 14.3x -> 14.1x: headless has no sound | dropped |
| Force: thread cap (unlike the laptop, 6 engines on 12 cores fight) | 6 at once: 2 threads 17.3x, 4 threads 16.2x; 8 at once: 1 thread 13.1x, 2 threads 12.2x; 4 at once with 2: 26.4x | **in force FAST** (2) |
| Force: more games at once | throughput (game s per wall s) 4: 106, 6: 104, 8: 98-105 (12: ran force out of memory, see Failures) | keep PARALLEL=4 |

## The engine itself (force, perf)

`perf record -g` on one live 20-minute duel, headless, FAST settings (needs
`sudo sysctl kernel.perf_event_paranoid=1`; force keeps 4, set it back). The official binary is stripped,
so only libraries and threads are named:

| Thread | Share of samples | Of which |
|---|---|---|
| recoil-main (the simulation) | 55% | engine 40%, **clock reads (vdso) 8%**, BARbarian (libSkirmishAI.so) 4%, kernel 2%, libc 1% |
| worker1 (the one helper thread with 2 threads) | 33% | engine 25%, clock reads 6% |
| pregame (loading) | 10% | |

With a build from source at the same tag (symbols; same speed as the official binary: 41.3x vs 42.1x),
the main thread (51.5% of samples): clock reads/timers 8.9, drawing work 7.6 (headless still runs draw
frames: feature drawer updates, SwapBuffers, model uniforms, camera culling), Lua 7.4, pathing 6.6,
loading/decompression 3.1. BARbarian ~2-4%.

Who reads the clock (branch records, `perf record -j any_call,u`, callers of `spring_clock::GetTicks`):
the per-scope profiler (`ScopedTimer`, `ScopedMtTimer`, `CTimeProfiler::AddTime`) ~55% of calls, draw-frame
pacing (`SwapBuffers`, `UpdateTimer`) ~16%, archive reads while loading 12%, the thread pool's waits ~9%,
the watchdog 6%.

| Change | Result | Status |
|---|---|---|
| `MinSimDrawBalance=0` headless (force, 4 replays at once) | 21.9x -> 25.3x | **in force FAST** |
| `MinDrawFPS=0` | every game hangs at the end of loading | dropped |
| Build without the per-scope timers (`-DRECOIL_NO_SCOPED_TIMERS`, testenv/force/engine/recoil-no-scoped-timers.patch) | 4 replays at once, alternating builds: 29.3 -> 30.7x, 28.2 -> 29.5x (+4.7%) | kept for the test engine |
| `-DLTO=ON` | the build fails linking lunasvg's svg2png example (gold) | not yet |
| `-DMARCH_FLAG=znver4` (official builds: generic x86-64) | replay 30 -> 50x, but **the replay desyncs** (321 units at minute 19 instead of 509: different float results, cheaper game); live, 8 games each at matched unit counts: no faster than official | **dropped** (fake gain, and the game's math differs from BAR's) |

A replay is only a fair benchmark while the build keeps it in sync: compare its per-minute unit counts with
the official engine's (the no-timers build matches minute for minute; znver4 doesn't).

Live, 8 games of 30 minutes per build, 4 at a time (speed by our unit count, <100 / 100-200 / 200-300 /
300+): official 72.6 / 27.4 / 12.0 / 10.7x, no timers 56.3 / 25.2 / 13.6 / 10.5x, znver4 52.2 / 21.5 / 13.6
/ 12.4x: live games are too noisy to see 5%.

**Verdict on a stripped engine:** the engine's own overhead that a build can remove is small: the
per-scope timers (+4.7%, needs rebuilding with every engine update BAR takes). The rest of the main thread is
the simulation itself (pathing, unit and feature updates, Lua gadgets, ours, BARbarian) and the draw frames
headless still runs, which `MinSimDrawBalance=0` already cuts (+16%, a setting, no build). Not worth a
custom engine for now; the patch and tools stay in testenv/force/engine.

Tools and builds: testenv/force/engine/README.md (`perf_game.sh`, `brcallers.py`, the patch;
`ENGINE=<dir> testenv/force-speedbench.sh`). Builds on force: `~/bar-sim/engine-src-base` (unpatched, same
speed as official), `engine-src-notimers`.

## Does FAST change results?

Laptop, duelrules vs medium, 60 minutes, 12 games per arm, 6 at a time, SPEED=100 (`make compare`):

| Arm | Wall time | Games | Results | Metal | Dealt / taken | Score |
|---|---|---|---|---|---|---|
| default (`20261017-2324-speed-nofast`) | 20 min | 11 | 6 win, 2 timeout, 3 loss | 152k | 0.80 | 0.70 |
| FAST, 2 threads (`20261017-2314-speed-fast`) | 10 min | 11 | 5 win, 1 timeout, 5 loss | 112k | 0.87 | 0.60 |
| FAST, 2 threads (`20261017-2345-speed-fast2`) | 11 min | 12 | 10 win, 1 timeout, 1 loss | | | |
| default (`20261017-2356-speed-nofast2`) | 11 min | 12 | 10 win, 1 timeout, 1 loss | | | |
| FAST (`20261018-0039-speed-fast3`) | 7 min | 12 | 8 win, 1 timeout, 3 loss | | | |

Pooled (games renumbered into one dir each, `gamereport -compare`): default 23 games 16 win, 3 timeout, 4
loss; FAST 35 games 23 win, 3 timeout, 9 loss. Score -0.04 [-0.24, +0.15], every metric "can't tell".

Wall time is a poor speed measure across batches (game lengths and the laptop's other load differ; a node
process used ~4.5 cores throughout, load average 20-60): compare game-minutes per wall-minute, or speed by
unit count. By unit count (<100 / 100-200 / 200-300 / 300+): default 28.5 / 14.9 / 11.0 / 7.5x, FAST 39.2 /
22.6 / 16.3 / 10.0x. The first default batch ran at half the second's speed at every unit count: other load.

### On force (live, 24 games each, PARALLEL=4)

| Arm | Wall | Game s per wall s | Results | Metal | Killed / lost | Dealt / taken |
|---|---|---|---|---|---|---|
| default (`20261018-1033-force-speed-default`) | 31 min | 35 | 20 win, 3 timeout, 1 loss | 245.2k | 296 / 821 | 0.87 |
| default again (`20261018-1200-force-speed-default2`) | 26 min | | 11 win, 7 timeout, 6 loss | 157.2k | 184 / 648 | 0.85 |
| FAST (`20261018-1008-force-speed-fast`) | 24 min | 46 | 15 win, 6 timeout, 3 loss | 187.2k | 207 / 608 | 0.96 |
| widgets off only (`...-1106-force-speed-widgetsonly`) | 24 min | 44 | 13 win, 5 timeout, 6 loss | 189.8k | 223 / 727 | 0.81 |
| 2 threads only (`...-1131-force-speed-threadsonly`) | 28 min | 38 | 17 win, 4 timeout, 3 loss | 226.4k | 242 / 783 | 0.90 |

Against the first default batch alone all three looked worse (FAST: score -0.14, late kills "worse").
But the second default batch, the same settings, came out **"worse" than the first** (score -0.29
[-0.47, -0.10], mid metal lost and late kills "worse"): the first was a lucky batch. Against both
pooled (48 games): FAST +0.01 [-0.17, +0.18], widgets only -0.09 [-0.29, +0.10], threads only +0.05
[-0.12, +0.22], every metric can't tell. FAST is cleared. The speed is mostly the widgets (44 vs 35).

## Failures seen

- ~4% of engine starts crash at "Loading Sound Definitions" (SIGSEGV in a worker thread), with or without
  sound, one game or six (4 of 16 starts in the FAST batch, 3 in the default one; one game crashed on both
  tries and dropped out of each batch): a Mac engine bug. batch.sh now retries such a load crash (exit 139
  within a minute) without using up one of the game's two tries, up to 3 times.
- run.sh's wall-clock limit counted SPEED up to 10x (900 s for 60 minutes): a default-settings game, 6 at
  once, ran out of it (games took up to 820 s). Counted at 6x at most now (1380 s).
- Engines started at the same moment can hang in window setup (watchdog after 30 s, run.sh's LOADMAX kills
  them at 150 s): 2 of 12 starts with sound on and games 5 s apart. run.sh now launches one engine at a
  time, 8 s apart (`LAUNCH_GAP`, a lock dir `testenv/.launch.lock`).
- Replays on several workers at once: all but the first hung, because every replay's local server binds
  port 8452 (`bind: Address already in use`). run.sh gives each worker its own `HostPortDefault`.
- 12 full-view late-game replays at once on force (2026-10-18 09:43) ran its 60 GB out of memory: the OOM
  killer took next-server, firefox, ptaas, fakegcp, devmail and desktop helpers (not the decision-model
  servers), and force dropped off the network for ~25 minutes. force-speedbench.sh refuses PAR > 8 now.

