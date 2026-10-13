# Lessons

Durable things learned while improving the sub-commanders: causes, dead ends and process traps. Read this
before starting work, and add to it after every experiment (one bullet, with the batch or game it came
from: details are in [test-games.md](test-games.md) and the design docs). Edit or remove bullets that turn
out wrong.

## Measuring

- Same code, wildly different games: metal produced ranged 9k-92k within one batch. Use 8+ games per arm,
  16 for small effects, and run the baseline in the same session. (batches A-D, decision model arms)
- Rules-only play decides most of the outcome against BARbarian; the AI strategist hasn't beaten rules
  only in raw strength (AI-1, AI-2). Measure executor changes with `duelrules`, strategist changes with
  `duel` + `LOCKSTEP=1`.
- Offline model accuracy isn't game strength: the fight model (AUC 0.81) gave more kills and more lost
  games. (decision model arm F)

## Playing BAR (what the games showed)

- Early raids that reach the wind farm or extractors decide most games; constructors are lost by the dozen
  (about 8 per game in the last batch). (batches C-F)
- Against strong players' pace (`make report`): our metal income falls behind from about minute 8 and our
  energy income is far behind by minute 15. Strong players keep one or two factories until about minute
  12 and keep 5-7 constructors. (pro benchmark, batch 20261013-old-F)
- The whole team dies with the commander (BAR's default end condition): keep it home. (game 10)
- Letting emergency energy pick basic solar instead of wind made every average worse. (batch E)
- The counter-push rarely triggers: the army is seldom 1.5x what it sees. (batch B)
- The unit value model ("pays for itself") picked the cheapest units (505 Satyrs) and lost; production
  by fight-model lookahead lost too. Imitating strong players is the next attempt. (arms K, L)
- The strategist flip-flopped posture and read low metal storage as a stall; a 90 s posture cooldown and
  prompt fixes stopped it. (AI-1, AI-2)

## Engine and widget traps

- Widgets get no attacker in `UnitDamaged` (they do in `UnitDestroyed`); use `Spring.GetUnitExperience`
  (experienceMult 0.3) to estimate damage dealt.
- Lua's 200-locals-per-function limit: move code into `widget/LuaUI/Include/sc_*.lua` modules.
- BAR's idle-guard widget takes over idle constructors and the commander unless orders keep them busy.
  (game 1)
- In player mode `Spring.GetTeamUnits` / `GetTeamResources` of an enemy team return nothing: only the
  harness's own team has eco lines in test games.

## Process traps

- Widgets (and the harness) are copied at each game's start: editing them during a batch leaks into the
  remaining games. Freeze arms with `WIDGET_SRC` (ab-test skill).
- One game environment at a time: batches, `collect.sh` and `replays.sh` share `testenv/` and port 17878.
- macOS system Python has no CA certificates: `uv run --with certifi`.
- pr-downloader only finds BAR game versions with BAR's CDN env (`PRD_RAPID_REPO_MASTER`,
  `PRD_HTTP_SEARCH_URL`).
- Lightning studios auto-stop when idle mid-training; outputs persist, restart and continue. H100/H200/A100
  aren't available on the account: use L40S.
- A stale base-model eval (from a smoke run) once got reused: check evals ran on the current test set.
