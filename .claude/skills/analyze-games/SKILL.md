---
name: analyze-games
description: Analyse BAR test games and batches in this repo - run gamereport, read the harness logs, compare against strong players' benchmarks, find why games were lost and what to fix next. Use after any test game or batch, or when asked how the sub-commanders are doing.
---

# Analysing test games

## Start with the report

```sh
make report                                    # newest batch (testenv/batch/latest)
make report BATCH=testenv/batch/<dir>          # a given batch, or a single log: BATCH=testenv/sctest_out.txt
make compare ARMS="testenv/batch/<A> testenv/batch/<B>"   # A/B arms side by side
```

Every `make test-batch` already writes `testenv/batch/<date>-<label>/report.md` (with `meta.txt`: commit,
widgets, opponent, map, speed). The report has:

- **per game**: result, length, metal produced, killed / lost, damage dealt / taken, constructors and
  factories lost;
- **economy pace**: our median at minutes 3-20 against strong players' 1v1s (quartiles from replays,
  `internal/analysis/benchmarks/pro-duel.json`); `!` marks a metric below their lower quartile;
- **losses by kind** per game (units and metal);
- **sub-commanders' recurring problems**: log messages like "gave up on ...", "couldn't ...";
- **findings, most severe first**: the list to work from.

Severity is rough (about 1 = clearly hurting games). Batches of fewer than 8 games are anecdotes:
results swing hugely with the same code (metal produced 9k-92k in one batch).

For agents: `go run ./cmd/gamereport -json <dir>` gives the same report as JSON (games, pace against strong
players, losses per kind, trades per phase, recurring problems, findings); `-compare -json` per arm.

## Digging into one game

Start with its timeline: `make timeline GAME=testenv/batch/latest/3.txt` (or `gamereport -timeline <log>`,
`-json` for JSON): minute by minute the economy, what we lost and killed by kind, and the decisions (squad
engage / hold / fall back with ratios, raids, factories, the player's actions, alarms). Then the raw log:

The harness log (`<n>.txt`, or `testenv/sctest_out.txt` for a single game) has `[frame]` prefixed lines
(30 frames = 1 s, 1800 = 1 min):

| Line | Meaning |
|---|---|
| `t=150s metal 132/1300 +9.3 energy ...` | team resources every 30 s (current/storage +income) |
| `units: legck=4 legmex=5 ...` | our units by name |
| `  [2] Defense 2 defense/balanced B1 F0 C0 threats=0 spend=0.0 \| ...` | each sub-commander: builders, factories, combat units, threats, unit tasks |
| `     log: ...` / `     AI: ...` | its latest log lines (repeat across snapshots) |
| `eco minute=5 metalIncome=... mex=... factories=... army=... energyStalled=... metalOverflow=...` | per-minute economy, same classification as the replay logger |
| `lost minute=3 kind=constructor name=legck cost=130 x= z=` / `killed ...` | every unit we lost or killed, with position |
| `player: ...` | what the scripted player did |
| `RESULT ...` then `us: metalProduced=...` | how it ended |
| `HARNESS ERROR` | the harness itself failed: fix that first |

The army's squad decisions are in its log: `engaging X (2.1x their strength)`, `regrouping`, `holding: X is
too strong here (0.6x)`, `falling back from X (0.4x)`; constructors fleeing show as `constructor pulled back
from enemies`. A ratio far above 1 that still loses means the threat map didn't see the enemy (radar,
memory); repeated `holding` means the army is too small for what it faces.

Useful greps:

```sh
grep -E "lost minute=[0-5] " testenv/batch/latest/*.txt          # early raid losses
grep -h "lost " testenv/batch/latest/*.txt | awk '{print $4}' | sort | uniq -c | sort -rn
grep -h "kind=factory" testenv/batch/latest/*.txt                  # labs lost: when and where
grep -h "gave up on" testenv/batch/latest/*.txt | sort | uniq -c | sort -rn
grep -B2 -A30 "t=480s" testenv/batch/latest/3.txt                 # the state of game 3 at 8 min
```

Positions are world coordinates; our start is in the `scenario ...`/`enemy start` lines near the top.
The engine log of the last game is `testenv/run.log` (Lua errors: `grep -i error testenv/run.log`), the
final screenshot is in `testenv/screenshots/`.

## One feature at a time

The report's **feature table** judges each of our features on its own (spent, killed, lost, return;
kills and losses carry `by=` the killer and `feature=` ours). For the why, `scripts/llm_review.py
<batch> --feature firebase|lrpc|nuke|antinuke|shield|juno|rez` (run with `uv run --quiet --with certifi
python`): a per-game account and a synthesis in `<batch>/llm-<feature>.md`. It reads only the log: it
doesn't know the doctrine's caps and limits, so check a claim in the code and the log before acting.

## Turning findings into work

1. Read `docs/research/lessons.md` first: the finding may already have a known cause or a failed fix.
2. Pick the top finding that the code can plausibly change. Write the hypothesis down ("constructors die
   to raids because Defense builds turrets after the extractors are already out": check `lost` lines vs
   the time Defense's first turret appears).
3. Find the code: executor rules in `widget/LuaUI/Widgets/gui_subcommanders.lua` (search the role name,
   `Tactics`, `Decider`, `Player`, `Lanes`, `Enemy`), the harness's player in
   `testenv/LuaUI/Widgets/zz_sctest.lua`, the strategist's knowledge in `strategist/.agents/skills/`.
4. Change it, then A/B test it (the `ab-test` skill) and record the result.

Strong players' games are a reference, not a target to copy blindly: they micro their units and scout,
our executor doesn't. The `pro-replays` skill explains the data.
