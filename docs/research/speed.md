# Faster test games

Goal: double or triple how fast test games run, first on the laptop (M4 Max, 16 cores, windowed engine
through zink), then carry what works to force (headless).

**Status (2026-10-17):** `FAST=1` (run.sh, batch.sh) bundles what works. Laptop, 15-minute duels: one game
40x -> 80x; six at once ~55x each (~300 game seconds per wall second, against ~40 for one default game).
Late game (300-800 units) gains less: 17x -> 25x on the replay benchmark. Open: does FAST change results
(A/B below), and the force host (untested: off the tailnet this session).

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
| `WorkerThreadCount=2-3` (default: one per core; every engine spins its pool) | one game: no change; 3 at once: 40x -> 65x each; 6 at once with 2: ~55x each | **in FAST** |
| `Sound=0` | 6 at once: no load hangs in 36 starts (2 of 12 hung before) | **in FAST** |
| Gadget profiler (`luarules profile`) | replay 24x -> 36x (!), live 78x -> 53x: replay-only quirk | dropped |
| Disable BAR's visual gadgets (`disablegadget`, needs cheats; synced halves share names) | at most ~5% late | not tried: risky, small |
| Our widget's per-frame cost (11% late) | | todo: profile by callin (`zz_speedprof` writes it) |
| Loading (~16 s a game) and shutdown (~3 s) | | todo |
| End decided games early (mercy rule) | | idea: check the call against the real result first |
| Force: FAST's widget pruning + threads + no sound in headless | | todo (needs the personal tailnet) |

## Failures seen

- ~4% of engine starts crash at "Loading Sound Definitions" (SIGSEGV in a worker thread), with or without
  sound, one game or six: a Mac engine bug; batch.sh tries a game twice.
- Engines started at the same moment can hang in window setup (watchdog after 30 s, run.sh's LOADMAX kills
  them at 150 s): 2 of 12 starts with sound on and games 5 s apart; none with `Sound=0` and 3-12 s apart.
