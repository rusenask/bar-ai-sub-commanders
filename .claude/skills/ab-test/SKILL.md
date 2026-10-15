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

## Failures first

Before comparing arms: every game ran (`ran: N/M`), no `WIDGET CRASHED`, no sandbox errors in `meta.txt`.
For each failure read its log and name the cause; a batch with silent failures is a biased batch.

## Deciding: the verdicts, not the averages

`make compare` ends with a verdict table per arm against the first (the baseline): each metric's
difference with a 95% bootstrap interval, by stage (opening < 10 min, mid 10-25, late 25+). "can't tell"
means the interval holds zero: the arms may be the same. Read it like this:

- Keep a change when its target metric (the stage it was meant for) says **better** and nothing says
  **worse**. Say which stage it helps: an idea can pay in one stage and cost in another.
- "can't tell" on everything = no evidence either way: run more games (24+ a side) before deciding, or
  drop it if it was a long shot. Don't call 3 wins against 1 an improvement on its own.
- Any **worse** = revert, or restrict the change to the stage where it helps.
- Kept strategies (firebases, cannons, nukes, anti-nukes, shields, Juno, resurrection) are never reverted:
  A/B version against version, and judge the piece on its own too: the **feature table** at the end of
  `make compare` (per feature: games used, metal spent, enemy metal killed, its losses, return). Then ask
  why with `uv run --quiet --with certifi python scripts/llm_review.py <batch>-B --feature <name>`
  (DeepSeek flash reads each game's events for it in parallel, ~10 s, and synthesises the recurring
  problems and the next version's changes). Check its claims against the log before acting on them.

## Micro changes: the battle lab first

A change to how units fight (targeting, focus fire, kiting, approach, retreats) is tested in battles, not
games: 72 battles (9 specs x 8, standing and attacking enemies) take ~7 minutes on force and the verdict has a "battle efficiency" row.

```sh
SCENARIO=battle DUEL_MINUTES=4 PARALLEL=6 WIDGET_SRC=$(testenv/arm.sh mine) LABEL=battle-mine testenv/force-batch.sh 72 battle
go run ./cmd/gamereport -battles testenv/batch/<dir>      # efficiency per spec
```

Better, in Lightning sandboxes and **interleaved**: both arms in one batch, odd games A, even games B,
each pair the same spec on the same sandbox (separate batches drift +-0.2 log2 on their own):
`uvx --with lightning-sdk python testenv/sandbox/batch.py 144 --scenario battle --minutes 4 --sandboxes 3
--instance cpu-16 --parallel 6 --widgets /tmp/arm-base/Widgets --widgets-b /tmp/arm-mine/Widgets --label
sbx-il-mine` (keep all bar-* sandboxes under 12), then `make compare ARMS="<batch>-A <batch>-B"`: the
verdict rows say "(paired)". Works for whole games too (12+ pairs), on force as well
(`WIDGET_SRC_B=... testenv/force-batch.sh 24`). The same A/B on both hosts pools into one paired verdict:
`testenv/pool-pairs.sh <name> <sandbox batch> <force batch>`, then `make compare ARMS="/tmp/pool-<name>-A
/tmp/pool-<name>-B"`.

Battle verdicts compare within each spec (`(within specs)` rows): pooled, the gap between specs drowns
the change. Also read the per-spec table: a gain in one mirror can hide a loss in another.

To tune micro numbers instead of testing one change, let the learner search them on battles (scored
against each spec's mean; every 6th battle plays the mean):
`batch.py 72 --scenario battle --minutes 4 --sandboxes 6 --parallel 6 --widgets ... --learn battle-micro
--generations 8 --learn-only "<micro tunables>" --mean-every 6 --learn-score battle`, then A/B the mean
(`go run ./cmd/learn overlay`) against the defaults before `learn validate`.

Then confirm in whole games that it holds up (micro that wins battles can still lose games: chasing,
over-committing).

## Running

On the force host (default: headless, 6 at a time, 16 games of 60 minutes in about half an hour; the
harness is copied at the start, so local edits don't leak):

```sh
WIDGET_SRC=$(testenv/arm.sh mine) LABEL=force-my-change testenv/force-batch.sh 16
WIDGET_SRC=$(testenv/arm.sh base <commit>) LABEL=force-baseline testenv/force-batch.sh 16
```

Compare force arms with force arms (100x headless vs 15x windowed may differ). Locally, when you want
to watch:

```sh
make test-batch GAMES=8 LABEL=baseline                     # rules only (duelrules), vs medium, 15x
WIDGET_SRC=/tmp/armB/Widgets LABEL=my-change testenv/batch.sh 8
make compare ARMS="testenv/batch/<date>-baseline testenv/batch/<date>-my-change"
```

Each batch prints a line per game, the summary and its findings. Games run on `WORKERS` parallel write
dirs (default 1, at lower CPU priority so the machine stays usable: 16 games of 60 minutes take about an
hour; `WORKERS=3` roughly doubles throughput when the machine is free, workers start 20 s apart). Older
arms ran 25 minutes: compare them on the `Lost by 25 min` column. A game that didn't run is
retried once; `meta.txt` says `ran: N/M`, a stalled game (no harness output for 2 minutes, or none within
150 s of launch: loading can hang) is killed, and failed tries leave their logs in `failed/`.
Strategist arms (`BATCH_SCENARIO=duel LOCKSTEP=1 SPEED=10`) use one worker and a running
`make test-bridge`; while a review is in flight the game runs at real time, not paused.
`BATCH_SCENARIO=autopilot` lets the Sub-Commanders Autopilot widget play instead of the harness's scripted
player (`MAP`, and the faction in `testenv/script_vsai.txt`, as needed); self-play against our own bot:
`HOST_DIR=testenv SCENARIO=duelrules YOU=Legion BOT=Cortex play/vs.sh` (the host's log is the harness log).

## When a fix lands mid-batch

If a fix for something seen in the games (by you or the player watching) is committed while a batch runs,
stop that batch (`pkill -f "[b]atch.sh"; pkill -f "[t]estenv/run.sh"; pkill -9 -f "[M]acOS/spring"`),
note it in its `meta.txt`, and start one with the newest widgets. Old arms only repeat known mistakes.

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
