# Sub-commander engine: world model, doctrine, squads, autonomy

Status: phases 1-6 built (2026-10-13); tuning by A/B batches continues. Owner: the improvement loop
(`.claude/skills/improve`). Results: docs/research/test-games.md ("Engine v1" and later).

## Why

Measured against BARbarian (CircuitAI) and strong players (docs/research/test-games.md, lessons.md):

- **Medium** beats us with raids from minute 2: no combat units before minute 3, no turret at the
  extractors, a half-built second lab out front. Extractors peak at 7 and fall; the economy never recovers.
- **Hard** matches neither of those weaknesses at first: our economy is on strong players' pace until
  minute 12. Then its concentrated army with artillery trades 7:1 against us. Our units engage one by one,
  gather under turrets that artillery outranges, retreat late (30% health), and we spend more on turrets
  than strong players do.
- Strong players build **one** factory until about minute 8-10, combat units from minute 1, a turret by
  minute 3, and put metal into the army rather than turrets.

CircuitAI's edge is machinery we don't have: a **threat / influence map** with memory, rebuilt 3x a
second; **threat-aware pathing**; **squads** with retreat thresholds and power quotas; **doctrine as
data** (unit mix per income tier, a counter-response matrix, economy ratios); and a **macro curve**
(build power per income, extractor upgrades). Hard's profile is mostly that data tuned aggressively.

The LLM strategist didn't add raw strength (AI-1, AI-2) and better-predicting models didn't win games
(design/decision-models.md): the gap is the executor's policy. So the work goes into the executor, with the
strategist steering it (more often, when it can afford to).

## Architecture

The widget stays the executor (it has to: only the player's client can order the player's units), split
into modules so each part can be read, tested and extended on its own:

```
widget/LuaUI/Widgets/gui_subcommanders.lua   ownership, scheduler, jobs, panel, API (the glue)
widget/LuaUI/Include/
  sc_unitkinds.lua    unit classification (exists)
  sc_doctrine.lua     tuning as data: retreat thresholds, engage ratios, unit mix per income tier,
                      counter matrix, turret budget, economy ratios, autonomy levels
  sc_threatmap.lua    world model: enemy memory (last seen, decays), threat per cell and layer
                      (ground / air), our influence, queries (threat at, safe point, front, hotspots)
  sc_pathing.lua      threat-aware A* over the threat grid (waypoints around danger)
  sc_squads.lua       army as squads: cohesion, engage / hold / retreat by local power vs threat
  sc_production.lua   what a factory builds: tier mix + counter matrix (pure)
  sc_autozones.lua    areas per role when the player drew no zones; clusters (wind farms)
  sc_territory.lua    what's ours (cells near our structures), its frontier, and pickets: the frontier
                      points to hold (facing the enemy, where intruders came from, what they protect)
  sc_team.lua         the swarm's blackboard: the team plan (opening / expand / tech / defend / push)
                      and requests sub-commanders post for each other (defend, constructor, production)
  sc_commander.lua    the commander's modes (auto / builder / defender / frontline), personality
                      (careful / bold) and D-gun target choice
widget/tests/         plain-Lua unit tests of the modules (make test-lua; stubs for Spring)
```

Modules are pure where possible: they get what they need through a small context (`defs`, the frame,
map size, a few engine functions) so they run under plain Lua in tests. A module is a file that returns
a constructor: `local ThreatMap = VFS.Include("LuaUI/Include/sc_threatmap.lua", nil, VFS.RAW_FIRST)(ctx)`.

### Fast loops (in the widget, every frame budget)

| Loop | Every | What |
|---|---|---|
| threat map | 10 frames (3/s) | rebuild threat and influence grids from enemy memory and our units |
| combat / squads | 30 frames | squad state (gather, engage, hold, retreat), per-unit retreat, targets |
| builders | 15 frames, 8 per pass | jobs, with threat checks on build spots and builder safety |
| factories | 30 frames | production by doctrine (tier mix + counter response + hand-offs) |
| auto zones | 300 frames | recompute role areas for sub-commanders without player zones |

### Slow loop (the bridge)

The strategist reviews each AI-enabled sub-commander. Pacing adapts:

- **active** (threats in its area, losses, new orders): as often as the provider answers, measured as
  the moving average of its turn time, converted to game time with the measured game speed; never more
  often than `-urgent`;
- **calm**: every 2 x `-interval`;
- a cap on reviews in flight, so a slow provider isn't flooded.

The widget exports the threat map's view in the enemy intel (`groups`: their armed groups with power and
static share; `front`: the last safe point toward them) and each army's `squad` decision, so the
strategist sees the world model too.

## Doctrine (from BARbarian hard and strong players)

| Topic | Value | Source |
|---|---|---|
| retreat | constructors at 85% health under fire, fighters at 50%, commander 60% | BARb hard behaviour.json |
| engage | attack where our local power >= 1.2 x local threat (turrets count); hold >= 0.8 x; else regroup | BARb thr_mod, adapted to metal power |
| opening | economy lab: constructor, constructor, 2 raiders, then about 1 constructor per 2-3 combat units | BARb factory tier0 (10-25% constructors), strong players |
| factories | one lab, scaled with construction turrets (one per 8 metal/s above 10, 5 per lab); another lab only when every lab is saturated and income supports it | strong players (1 lab until min 8-10), BAR guidance: 200 BP for 230 metal vs a lab's 150 for 470 |
| constructors | target 3 + income / 10 (cap 12) | BARb buildpower 1.2, strong players 5-8 |
| turrets | budget max(300 + 90 x minute, 0.4 x army value); first at exposed extractors from about minute 2.5 | strong players (5 by min 6, ~1.7k at 12), BARb build chain |
| counters | response matrix: raiders vs scouts / raiders / artillery, skirmishers vs assault, anti-heavy vs heavy, artillery vs turrets, anti-air vs air (caps per kind) | BARb hard response.json |

## Autonomy (per sub-commander: light / balanced / full)

| Role | light | balanced (default) | full |
|---|---|---|---|
| economy | its zones only, no factories | + safe expansion, storage, converters | + builds factories by income tier, constructor target by income |
| defense | turrets only where threats show up | + front line and extractor cover, budgeted | + turret schedule across base and expansions, radar |
| army | defends its own area | + helps other areas, counter-pushes when clearly stronger | + attacks and raids on its own when the threat map says it wins |
| air defense | reacts to air seen | + covers valuable structures | + proactive by income |
| intelligence | radar only | + cameras, scouts | + jammer, hunting enemy intel |

The autopilot (bot opponent) runs everything at **full**.

## The team (swarm) and the commander

Every combat pass `Engine.refreshTeam` recomputes the **plan** from the state of the game: `defend` when
enemy metal inside the base passes `D.team.defendBase` or the strongest known enemy army outweighs ours
by `defendRatio`; `opening` for the first minutes; `push` when our army is at least `pushMin` and
`pushRatio` x everything known of theirs; `tech` when the economy carries tier 2 and we have no T2 lab;
else `expand`. Everyone reads it: no pushes or attacks while defending, raids pause when the base itself
is attacked, more turret budget and a bigger response squad; a push lets a balanced army attack; tech
lets a balanced economy start the T2 lab without overflowing metal.

**Requests** (posted by the rules, or by the strategist with `request_help`): an outgunned non-army area
posts `defend` (the Army's squad answers if it's in the base); an Army facing a bigger known army posts
`production` (the Economy's lab feeds it combat units even when it has labs); a Defense without
constructors posts `constructor` (the Economy's lab builds one and hands it over). Same kind, same
sender, nearby: merged; nobody refreshes them for 45 s: gone.

**The commander** (`Tactics.commander`, every combat pass for the sub-commander that owns it): the mode
(auto picks builder / defender / frontline from the plan, the threat near it, its health, autonomy and
personality), the D-gun at the most expensive armed enemy in reach above the personality's minimum,
frontline following the army's main body 350 behind it within the personality's range of home, and
retreat at the personality's health (`guardCommander`).

## Spending a big economy (doctrine.escalation)

v19's games reached 150-240 metal/s by minute 35 with metal at the storage cap, T1 turrets only and 130
guards idling at home. Escalation by income:

| From | What |
|---|---|
| any income | heavy and long-range turrets per area: base mix x (1 + income / 50), at most 4x (`P.mixScale`) |
| 50 metal/s | the Army's own aircraft plant; bombers and gunships (fighters if the enemy flies) raid as one wing (`Tactics.airRaid`: targets from `raidCandidates`, enemy anti-air within 900 at most a third of the wing, home at half strength) |
| 60 metal/s | Defense posts a tier 2 `constructor` request; any economy or army lab that makes one answers (the T2 lab) |
| 90 metal/s | Air Defense too |
| metal piling up | the Economy's lab sends units beyond its guards to the Army |
| push plan | intruders the main army outweighs 8x are left to the response squad and turrets |

## Zones are optional

A sub-commander without player-drawn zones gets **auto zones** recomputed by role: economy around our
structures plus safe metal spots on our side; defense at the base's front and exposed extractors; army at
the front between base and the enemy (moving with the threat map); air defense over the base; intelligence
on the approaches. Drawing a zone switches to manual zones; clearing them goes back to auto.

## Phases and how each is measured

1. Structure: modules, doctrine, plain-Lua tests. (no behaviour change)
2. Threat map + enemy memory; builder safety; threat checks for expansions and build spots.
3. Opening and macro: economy lab raiders and army hand-off, one lab until income tier, turret budget and
   extractor cover. Harness and autopilot stop ordering the early second lab.
4. Squads and counters: cohesion, engage / hold / retreat by power vs threat, 50% retreat, safe rally
   point, counter-response production.
5. Autonomy levels and auto zones (panel, API, text commands, strategist tool).
6. Strategist pacing and threat summary.

Phases 2-4 are measured with 8+ game batches against medium and hard versus the baselines of 2026-10-13
(`testenv/batch/20261013-1153-baseline-rules`, `-1208-baseline-rules-hard`). Results go to
docs/research/test-games.md, lessons to docs/research/lessons.md.

## Results so far

| Arm | vs | Lost | Dealt / taken | Constructors lost | Extractors at 8 min |
|---|---|---|---|---|---|
| rules baseline | medium | 5 / 8 | 0.56 | 18.8 | 5.5 |
| engine v1 | medium | 1 / 8 | 0.57 | 8.5 | 12 |
| rules baseline | hard | 5 / 8 | 0.38 | 22.4 | 16 |
| engine v1 | hard | 3 / 8 | 0.46 | 12.2 | 13 |

Open problems (from the reports): raid groups hit wind farms and labs while the army fights elsewhere
(answered in v2 by turret cover and factory-first army priority); metal overflows with one lab (v2: an
overflow factory at balanced); late fights against hard still trade ~1:5 (v3: fewer cheap raiders, more
varied mid-weight units).
