---
name: ab-test
description: Run and judge A/B test batches of BAR games for a sub-commander change in this repo - arm setup with LABEL and WIDGET_SRC, sample sizes, comparing arms, deciding keep or revert, and recording results. Use whenever a change to the widgets, harness or strategist should be measured in games.
---

# A/B testing a change

## Rules

- **One game environment at a time.** Test games, `testenv/collect.sh` and `testenv/replays.sh` share the
  `testenv/` write dir and port 17878. Check nothing runs first: `pgrep -fl "[r]un.sh|[r]eplays.sh|[c]ollect.sh|[M]acOS/spring"`.
- **Widgets are copied at the start of every game.** Editing `widget/LuaUI/Widgets/*.lua` during a batch
  leaks the edit into the remaining games. Run arms from frozen copies:
  ```sh
  WIDGET_SRC=$(testenv/arm.sh mine) LABEL=my-change testenv/batch.sh 8            # the working tree
  WIDGET_SRC=$(testenv/arm.sh base 310182e) LABEL=baseline testenv/batch.sh 8     # any commit
  ```
  `testenv/LuaUI/Widgets/zz_sctest.lua` (the harness) is live too: don't edit it mid-batch (if you must,
  write a copy, `luac -p` it, then `mv` it in).
- **Sample size.** Same code gives wildly different games. Use at least 8 games per arm; 16 when the
  difference is small. Run the baseline in the same session (BARbarian and the engine change).
- **Same conditions.** Same scenario, opponent, map and speed in both arms (`meta.txt` records them).

## Running

```sh
make test-batch GAMES=8 LABEL=baseline                     # rules only (duelrules), vs medium, 15x
WIDGET_SRC=/tmp/armB/Widgets LABEL=my-change testenv/batch.sh 8
make compare ARMS="testenv/batch/<date>-baseline testenv/batch/<date>-my-change"
```

Each batch prints a line per game, the summary and its findings. Games run on `WORKERS` parallel write
dirs (default 1, at lower CPU priority so the machine stays usable: 16 games of 45 minutes take about an
hour; `WORKERS=3` roughly doubles throughput when the machine is free, workers start 20 s apart). Older
arms ran 25 minutes: compare them on the `Lost by 25 min` column. A game that didn't run is
retried once; `meta.txt` says `ran: N/M`, a stalled game (no harness output for 2 minutes, or none within
150 s of launch: loading can hang) is killed, and failed tries leave their logs in `failed/`.
Strategist arms (`BATCH_SCENARIO=duel LOCKSTEP=1 SPEED=10`) use one worker and a running
`make test-bridge`; while a review is in flight the game runs at real time, not paused.
`BATCH_SCENARIO=autopilot` lets the Sub-Commanders Autopilot widget play instead of the harness's scripted
player (`MAP`, and the faction in `testenv/script_vsai.txt`, as needed); self-play against our own bot:
`HOST_DIR=testenv SCENARIO=duelrules YOU=Legion BOT=Cortex play/vs.sh` (the host's log is the harness log).

## Judging

Look at, in order: games lost, damage dealt / taken, metal produced, constructors lost, the pace at 8 and
12 minutes. A change "wins" when it improves the target metric without making losses worse. With 8 games,
treat a 1-game difference in losses as noise. If unclear, run 8 more games of both arms rather than
arguing from the numbers.

## Recording (always, also for failed ideas)

1. Add the arm table (from `make compare`) and two or three lines on what was learned to
   `docs/research/test-games.md`.
2. If it taught something durable (a cause, a dead end, a process trap), add it to
   `docs/research/lessons.md`.
3. Keep the change only if it won; otherwise revert it and record why.
4. Commit and push (AGENTS.md).
