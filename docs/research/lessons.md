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
- Against hard, two 8-game arms of nearly the same code read 2 vs 4 losses; pooled to 16 each they were
  equal. Judge small changes on 16+ games, and on trades and losses per game more than on wins.
  (engine-v2/v3 hard)
- Offline model accuracy isn't game strength: the fight model (AUC 0.81) gave more kills and more lost
  games. (decision model arm F)

## Playing BAR (what the games showed)

- Early raids that reach the wind farm or extractors decide most games; constructors are lost by the dozen
  (about 8 per game in the last batch). (batches C-F)
- Against strong players' pace (`make report`): our metal income falls behind from about minute 8 and our
  energy income is far behind by minute 15. Strong players keep one or two factories until about minute
  12 and keep 5-7 constructors. (pro benchmark, batch 20261013-old-F)
- Against hard, economy isn't the problem until minute 12 (on strong players' pace); fights are: from
  minute 11 its concentrated army with artillery and rockets trades 7:1 against us. Against medium the
  early raids are: no combat units before minute 3, no turret by the extractors. (baseline batches
  20261013-1153 / -1208)
- A threat map with memory (constructors flee enemy reach, nothing built where we're outgunned), one lab
  feeding the army, and squads that only fight when stronger cut losses against medium from 5/8 to 1/8 and
  constructor losses by half. (engine-v1 vs baseline-rules)
- One army can't cover a base against several raid groups at once: static cover at what raids hit (labs,
  wind farms, exposed extractors) has to do it, as strong players do. (engine-v1, game 1 and 3)
- A squad's strength ratio only knows what it has seen: the first contact with a main army reads as 1x
  until radar contacts count too (threat map blips). (first engine test game)
- Scale production with construction turrets before more labs (200 build power for 230 metal against a
  lab's 150 for 470; a lab saturates at 4-7 turrets). Labs by income tier built three side by side.
  (autopilot-raids-40m)
- An army that attacks still needs to know where their factories are: scout their base before the push.
  (autopilot-raids-40m: no enemy factory found or killed in 8 games)
- Moving the base guards out to the frontier (pickets) let the economy grow but doubled commander deaths:
  whatever spreads the defence out must leave an escort with the commander. (engine-v7-territory)
- "Cheapest builder" isn't "the constructor": the T2 lab's cheapest builder was the Infestor, spammed 212
  times. Pick constructors by role (name / build options), and read the timeline of a disaster batch first:
  it showed the spam in the first minute of reading. (engine-v16)
- The whole team dies with the commander (BAR's default end condition): keep it home. (game 10)
- Letting emergency energy pick basic solar instead of wind made every average worse. (batch E)
- The counter-push rarely triggers: the army is seldom 1.5x what it sees. (batch B)
- The unit value model ("pays for itself") picked the cheapest units (505 Satyrs) and lost; production
  by fight-model lookahead lost too. Imitating strong players is the next attempt. (arms K, L)
- The strategist flip-flopped posture and read low metal storage as a stall; a 90 s posture cooldown and
  prompt fixes stopped it. (AI-1, AI-2)

- Spending escalation has to wait for the surplus: growing the turret mix from 30 metal/s (v20) ate the
  metal that would have overflowed into a second lab at balanced autonomy; one lab fed everything to the
  Army, the Economy kept no guards, and the commander died alone in both games. Escalate above ~50
  metal/s, and keep the commander's escort before feeding anyone.
- A team request changes who gets production: the Army's production request made the Economy feed it
  raiders from its second constructor on (v21b), so it never grew past 3 and the scripted player never
  had a spare constructor for Intelligence, Air Defense or the Air Force. Constructors first.
- Factions differ in what a plant makes: Legion's T1 aircraft plant has no scout plane, and "build a
  scout first" stuck the Air Force on gunships (v21). Choose from what the factory can actually build.
- The Air Force (v21c): fighters, gunships hunting raids, bombers striking around anti-air. First wins
  against BARbarian medium came with it (v21 game 1, v21c game 2).

- Strong players' micro is simpler than my first doctrine assumed (143 duels, 245k samples): units fight
  from 0.7-0.8 of their range, only long-range ones kite, artillery stays with its group, damaged units
  aren't pulled out more than healthy ones. Measure before writing doctrine (docs/research/pro-micro.md).

- Fleeing earlier doesn't save constructors (v25: an early-warning radius scaled by speed): they stopped
  building, expansion fell (Armada 12 -> 8 extractors at minute 20, 11 losses of 12) and they died as
  often. Our constructors die inside the base to BARbarian's main pushes, not on the road: the fix is
  holding the base against Hammers and Rockos, not running.

- Focus fire pays (v26): army units converging on the enemy in reach worth most per hit point left (armed
  first) traded 0.77 against 0.64 and lost a quarter fewer units for the same kills.

- Learning 18 rules at once from 24 games a generation found no trend in 6 generations: one game's
  result is mostly noise. Search fewer rules at a time (the few that moved the same way in every
  matchup), measure the mean on many more games, and confirm what it found with a plain A/B before
  shipping it.

## Engine and widget traps

- Widgets get no attacker in `UnitDamaged` (they do in `UnitDestroyed`); use `Spring.GetUnitExperience`
  (experienceMult 0.3) to estimate damage dealt.
- Lua's 200-locals-per-function limit: move code into `widget/LuaUI/Include/sc_*.lua` modules.
- BAR's idle-guard widget takes over idle constructors and the commander unless orders keep them busy.
  (game 1)
- In player mode `Spring.GetTeamUnits` / `GetTeamResources` of an enemy team return nothing: only the
  harness's own team has eco lines in test games.
- Widgets rarely get the attacker of an enemy unit in `UnitDestroyed`: count enemy deaths in view rather
  than "killed by us".
- `MaxParticles` below 7000 in springsettings makes BAR's fire/smoke gadget define an empty buffer; the
  error takes down all of LuaRules on that client: no commanders spawn, and in multiplayer it desyncs at
  frame 0. Keep it at 10000 (testenv template). (first self-play game)
- A client that joins a game and catches up may not see every frame in widget `GameFrame`: act when a
  frame is due (`n >= next`), not on `n % k == 0`. (autopilot bot, likely cause)
- When a multiplayer game desyncs, the engine writes `ServerGameState-*.txt` / `ClientGameState-*.txt` in
  the write dirs: diff them to see what differs, then look for Lua errors in the client's log.

- Calling a `local function` above the line that defines it compiles to a *global* read: nil at run
  time, so the first call errors and BAR removes the whole widget ("Removed widget: Sub-Commanders").
  The game goes on with nobody controlling our units and looks like an ordinary loss. The T2 lab's
  hand-off to the Army (`addUnit`, defined 1500 lines below) did this in v15-v18: most games after the
  second T2 constructor were played without the widget. `make lint` now runs `scripts/lua-globals.sh`
  (unknown globals fail), and batch.sh marks such games `WIDGET CRASHED` with the error in the game log.
- Spring buffers its log (testenv/run.log) until it exits; the infolog stops after loading. Lua errors
  only show up in run.log after the game, which the next game overwrites.

## Process traps
- BAR from game version test-31614 sandboxes user widgets: no `socket`, files only under `LuaUI/`
  (writes only under `LuaUI/Config/` and `LuaUI/Widgets/`), no `require`/`loadstring`. Our harness and
  logger fell silent on those replays ("sctest_out.txt: is outside the write paths for user widgets"):
  they now read inputs from `LuaUI/Config/` first and write there when the root is refused, and the
  scripts look in both. The AI widget's TCP link to the bridge will stop working in that version: it
  needs a file transport under `LuaUI/Config/` (planned).
- The replay runner reported the first line matching "error" as the reason (a harmless config warning)
  and deleted the log: failures looked random. Keep failed logs, report exit code + the first line that
  matters.
- The force host's first batch (v21c, 6 at a time at 100x) won 7 of the first 9 games where the same code
  won 1 of 16 on the Mac. Two causes: a per-game wall-clock limit of 660 s killed the long, even games
  (retried, killed again) and kept the quick decisive ones; and 6 games on 12 cores (load 27) may starve
  BARbarian's worker threads so it plays worse. Give games room (limit = minutes x 30 + 300 s), run
  fewer at once, and compare force arms only with force arms run the same way.
- A background job that runs `ssh` must not read the terminal: `ssh -n` (or `< /dev/null`), or the job
  stops or dies and nothing collects the results.
- Watch the sub-commander status lines, not just the result: identical lines minutes apart (same counts,
  same `spend=`, `threats=0` while the base burns) mean the widget stopped. (v18 game 2)

- The test bridge (`scbridge-test`) keeps the decision-model routes it was started with: a "baseline" ran
  with the fight + turret models for hours. batch.sh records them in meta.txt now; restart it with
  `make test-bridge` (no `DECIDER_URL` / `TEST_BRIDGE_ARGS`) for rules-only baselines.
- Widgets (and the harness) are copied at each game's start: editing them during a batch leaks into the
  remaining games. Freeze arms with `WIDGET_SRC` (ab-test skill).
- One game environment at a time: batches, `collect.sh` and `replays.sh` share `testenv/` and port 17878.
- BAR rewrites springsettings.cfg and can drop `Fullscreen = 0`: test windows opened fullscreen. run.sh
  now sets the window keys on every launch (800x500).
- macOS system Python has no CA certificates: `uv run --with certifi`.
- pr-downloader only finds BAR game versions with BAR's CDN env (`PRD_RAPID_REPO_MASTER`,
  `PRD_HTTP_SEARCH_URL`).
- Lightning studios auto-stop when idle mid-training; outputs persist, restart and continue. H100/H200/A100
  aren't available on the account: use L40S.
- A stale base-model eval (from a smoke run) once got reused: check evals ran on the current test set.
- `pgrep -f "replays.sh"` inside a shell loop matches the loop's own command line and never ends: use
  `pgrep -f "[r]eplays.sh"`.
- Don't edit a shell script while it runs: bash reads it as it goes and fails mid-run. testenv/run.sh runs
  once per game of a batch, so it counts as running for the whole batch.
