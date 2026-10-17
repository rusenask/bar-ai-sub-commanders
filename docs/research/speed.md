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
- Force (headless) untested: off the tailnet this session. Drawing doesn't apply there; widget pruning and
  `Sound=0` should.

## How to measure

- The harness logs `speed minute=<m> x=<game s per wall s> wall=<s> units=<n>` once a game minute.
- `testenv/speedbench.sh <label>`: GAMES (2) duelrules games of MINUTES (10) at SPEED (1000, no cap) on
  WORKER (1); prints the average speed over minutes 2.. and the total wall time, appends to
  `testenv/speedbench.tsv`, keeps failed games' logs in `testenv/speedbench-failed/`.
  `SPRING_CFG="K=V ..."` sets engine settings, `SPRING_ARGS` engine flags, `PREP` a shell hook on the
  worker dir (`$W`), `PROFILE=1` dumps the engine profiler (`debuginfo profiling`) into the infolog and the
  per-widget times (`zz_speedprof.lua`, via BAR's widget_profiling include) into
  `LuaUI/Config/sctest_speedprof.txt` every 5 game minutes (`PROFILE="nowidgets nogadgets noengine"` turns
  parts off). Several `WORKER=n` runs at once measure parallel throughput.
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
| Our widget's per-frame cost (11% late) | | todo: profile by callin (`zz_speedprof` writes it) |
| Loading (~16 s a game) and shutdown (~3 s) | | todo |
| End decided games early (mercy rule) | | idea: check the call against the real result first |
| Force: FAST's widget pruning + no sound in headless (and check its 6-on-12-cores load) | | todo (needs the personal tailnet) |

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
