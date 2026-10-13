---
name: improve
description: The self-improvement loop for this repo's BAR sub-commanders - measure with a batch, analyse against strong players, pick the top finding, change, A/B test, record the result and the lesson, and improve the tools and skills themselves. Use when asked to make the AI play better, to "keep improving", or to run an improvement session.
---

# Improvement loop

Each round leaves the repo better at improving itself: results, lessons and tools are written down, so the
next session starts where this one stopped.

## 0. Load what's known

- `docs/research/lessons.md`: causes found, fixes that failed, process traps. Don't repeat a failed idea
  without a new reason.
- `docs/research/test-games.md`: past batches and arms.
- The newest report: `make report` (if `testenv/batch/latest` exists).

## 1. Measure

No fresh baseline for the current code? Freeze the widgets and run one (ab-test skill):
`make test-batch GAMES=8 LABEL=baseline`. Then read its `report.md` (analyze-games skill).

## 2. Pick one finding

Take the most severe finding the code can plausibly change. Write a one-line hypothesis with the evidence
(log lines, minutes, positions) and the metric that should move.

## 3. Change

Smallest change that tests the hypothesis. Where things live (design/engine.md):

- numbers (retreat, engage ratios, unit mix, counters, turret budget, factory pace, autonomy): 
  `widget/LuaUI/Include/sc_doctrine.lua`
- world model and decisions: `sc_threatmap.lua`, `sc_squads.lua`, `sc_production.lua`, `sc_pathing.lua`,
  `sc_autozones.lua` (plain Lua: add a test in `widget/tests/` for any new behaviour)
- wiring and jobs: `widget/LuaUI/Widgets/gui_subcommanders.lua` (`Engine.*`, `Tactics.*`, `Jobs.*`)

`make lint` (runs the module tests), `go test ./...`, `make build`.

## 4. A/B

Frozen copies of both arms, 8+ games each, `make compare`. Keep it only if it wins (ab-test skill).

## 5. Record, then commit

- Arm table and what was learned: `docs/research/test-games.md`.
- Durable lessons (cause, dead end, trap): `docs/research/lessons.md`, one bullet each with the batch name.
- New strategist knowledge (how to play BAR): `strategist/.agents/skills/<role>/SKILL.md`, then `make restart`.
- Commit and push; bring the running setup up to date (AGENTS.md table).

## 6. Improve the process

Before finishing, ask: what slowed this round down or nearly went wrong? Fix it where it lives:

- a missing measurement → add it to the harness (`eco` / `lost` lines in `zz_sctest.lua`) and
  `internal/analysis` (parse, report, a `Findings` rule), with a test;
- a repeated manual step → a script or a make target;
- a trap or a better way of working → the relevant skill in `.claude/skills/` or AGENTS.md.

Keep skills short and true: edit or delete outdated lines rather than appending contradictions.
