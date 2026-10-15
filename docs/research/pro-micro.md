# How strong players' units fight (micro)

143 rated duels (both players 30+, BAR's replay archive), played back headless on force with the data logger's micro samples (testenv/force-replays.sh), 245k samples: every few seconds, up to 25 combat units per team within 1.5x their range of an armed enemy. Regenerate with `go run ./cmd/gamereport -micro testenv/data/pro`. Mostly Cortex and Armada (Legion is rare in rated duels): our Legion units follow the kind and range of theirs.

Columns: *fights from* = distance to the nearest enemy over its own range while firing; *backs off* = share moving away from a close enemy it outranges / one that outranges it (kiting is the difference); *ahead of group* = elmos ahead (+) of the armed units around it toward the enemy; *shoots structures* = share of unit targets that are structures (in brackets: how often a structure was the nearest enemy); *pulls out* = share moving away without firing, by health.

| Kind | Samples | Firing | Fights from (range, p25-p75) | Backs off: outranged / outranging enemy | Backs off at | Closes on longer range | Ahead of group | Shoots structures (when near) | Pulls out by health <.35 / <.6 / <.85 / more |
|---|---|---|---|---|---|---|---|---|---|
| assault | 112754 | 38% | 0.73 (0.48-0.91) | 27% / 20% | 0.83 | 47% | 9 | 10% (9%) | 9 / 9 / 9 / 7% |
| raider | 54417 | 31% | 0.67 (0.43-0.86) | 21% / 16% | 0.95 | 48% | 6 | 9% (8%) | 8 / 11 / 11 / 10% |
| heavy | 26391 | 37% | 0.75 (0.45-0.90) | 26% / 22% | 0.80 | 47% | 16 | 12% (10%) | 8 / 9 / 8 / 8% |
| skirmisher | 15773 | 29% | 0.72 (0.50-0.91) | 24% / 18% | 0.66 | 36% | 8 | 16% (14%) | 8 / 11 / 9 / 6% |
| fighter | 13152 | 5% | 0.30 (0.17-0.48) | 34% / 28% | 0.85 | 40% | -5 | 0% (6%) | 15 / 32 / 27 / 24% |
| gunship | 5336 | 60% | 0.69 (0.44-0.82) | 22% / 15% | 0.66 | 21% | -33 | 9% (9%) | 10 / 9 / 7 / 6% |
| mobile anti-air | 5045 | 1% | 0.62 (0.48-0.88) | 18% / 44% | 0.77 | 18% | -4 | 0% (12%) | 16 / 14 / 11 / 10% |
| scout | 4669 | 32% | 0.67 (0.45-0.88) | 24% / 18% | 1.03 | 35% | 2 | 9% (7%) | 11 / 12 / 7 / 9% |
| bomber | 3905 | 15% | 0.17 (0.06-0.43) | 27% / 0% | 0.33 | 62% | -29 | 19% (29%) | 9 / 17 / 13 / 10% |
| naval | 2189 | 32% | 0.64 (0.29-0.84) | 25% / 18% | 0.67 | 33% | -4 | 11% (4%) | 12 / 12 / 9 / 6% |
| artillery | 1877 | 49% | 0.79 (0.65-0.87) | 17% / 0% | 0.62 | 0% | 24 | 31% (35%) | 10 / 11 / 9 / 4% |

By unit (most sampled):

| Kind | Samples | Firing | Fights from (range, p25-p75) | Backs off: outranged / outranging enemy | Backs off at | Closes on longer range | Ahead of group | Shoots structures (when near) | Pulls out by health <.35 / <.6 / <.85 / more |
|---|---|---|---|---|---|---|---|---|---|
| corak (raider, range 215) | 40717 | 33% | 0.68 (0.44-0.87) | 21% / 17% | 0.96 | 49% | 6 | 9% (8%) | 9 / 11 / 11 / 10% |
| corthud (assault, range 380) | 31122 | 42% | 0.82 (0.57-0.95) | 28% / 24% | 0.89 | 49% | 12 | 11% (8%) | 9 / 9 / 8 / 8% |
| corgator (assault, range 230) | 30154 | 38% | 0.64 (0.41-0.84) | 23% / 19% | 0.87 | 49% | 6 | 10% (9%) | 9 / 10 / 8 / 7% |
| armflash (assault, range 180) | 19378 | 30% | 0.61 (0.39-0.80) | 23% / 20% | 0.57 | 45% | 6 | 11% (9%) | 11 / 11 / 11 / 7% |
| corraid (heavy, range 350) | 18869 | 36% | 0.77 (0.50-0.91) | 25% / 23% | 0.87 | 45% | 18 | 13% (10%) | 8 / 9 / 8 / 9% |
| armham (assault, range 380) | 12297 | 42% | 0.79 (0.53-0.92) | 29% / 18% | 0.71 | 52% | 14 | 9% (8%) | 5 / 7 / 7 / 5% |
| armpw (raider, range 180) | 11612 | 25% | 0.64 (0.39-0.83) | 20% / 14% | 0.67 | 48% | 3 | 7% (6%) | 8 / 13 / 11 / 9% |
| armstump (assault, range 350) | 9416 | 35% | 0.68 (0.43-0.86) | 32% / 23% | 0.71 | 42% | 10 | 8% (8%) | 8 / 9 / 9 / 7% |
| corveng (fighter, range 680) | 9077 | 5% | 0.38 (0.22-0.50) | 35% / 32% | 0.83 | 41% | -11 | 0% (7%) | 15 / 32 / 27 / 24% |
| corlevlr (assault, range 315) | 5102 | 36% | 0.81 (0.56-0.97) | 13% / 20% | 0.90 | 42% | 4 | 7% (6%) | 7 / 6 / 6 / 7% |
| corbw (gunship, range 220) | 4113 | 64% | 0.69 (0.44-0.82) | 22% / 13% | 0.68 | 19% | -39 | 5% (5%) | 4 / 6 / 6 / 5% |
| cormort (skirmisher, range 850) | 3349 | 43% | 0.74 (0.56-0.94) | 34% / 4% | 0.56 | 36% | 19 | 31% (30%) | 7 / 8 / 10 / 9% |
| cormist (skirmisher, range 700) | 3333 | 4% | 0.73 (0.52-0.84) | 20% / 27% | 0.83 | 50% | 6 | 0% (3%) | 11 / 18 / 18 / 7% |
| corshad (bomber, range 1280) | 3303 | 16% | 0.19 (0.07-0.49) | 27% / 0% | 0.35 | 0% | -30 | 18% (29%) | 9 / 16 / 14 / 11% |
| correap (heavy, range 410) | 2961 | 43% | 0.65 (0.38-0.88) | 27% / 16% | 0.64 | 45% | 4 | 14% (11%) | 9 / 5 / 7 / 6% |
| armfig (fighter, range 680) | 2906 | 5% | 0.28 (0.15-0.53) | 34% / 18% | 0.84 | 40% | -16 | 0% (5%) | 18 / 28 / 31 / 24% |
| armfido (skirmisher, range 650) | 2437 | 46% | 0.79 (0.59-0.92) | 26% / 20% | 0.77 | 25% | -4 | 8% (9%) | 14 / 16 / 5 / 7% |
| armwar (heavy, range 325) | 2327 | 28% | 0.80 (0.50-0.96) | 30% / 18% | 0.90 | 50% | 23 | 9% (9%) | 10 / 12 / 9 / 8% |
| corstorm (assault, range 475) | 2140 | 52% | 0.79 (0.59-0.93) | 34% / 20% | 0.71 | 43% | 5 | 7% (7%) | 5 / 8 / 4 / 6% |
| armfav (scout, range 180) | 1931 | 29% | 0.67 (0.42-0.86) | 22% / 10% | 0.86 | 19% | 0 | 9% (7%) | 8 / 10 / 4 / 5% |
| armflea (scout, range 140) | 1887 | 33% | 0.71 (0.47-0.91) | 0% / 21% | 0.00 | 45% | 4 | 9% (8%) | 12 / 16 / 12 / 13% |
| corcrash (mobile anti-air, range 800) | 1733 | 0% | 0.00 (0.00-0.00) | 16% / 38% | 0.78 | 25% | -24 | 0% (0%) | 14 / 36 / 14 / 10% |
| armsam (skirmisher, range 700) | 1688 | 7% | 0.62 (0.32-0.82) | 14% / 23% | 0.60 | 25% | -8 | 0% (3%) | 7 / 12 / 11 / 4% |
| armjeth (mobile anti-air, range 800) | 1453 | 0% | 0.00 (0.00-0.00) | 18% / 47% | 0.80 | 23% | 11 | 0% (0%) | 34 / 19 / 7 / 14% |
| armjanus (assault, range 380) | 1398 | 52% | 0.85 (0.61-1.03) | 15% / 29% | 1.05 | 40% | -7 | 5% (5%) | 3 / 5 / 4 / 4% |


## What it means for our doctrine (sc_doctrine.lua D.micro)

- **Fight from 0.7-0.8 of range**, all ground kinds. Not point blank, not at the edge.
- **Kiting is for long range only.** Mortars (cormort, 850) back off from what they outrange 34% of the
  time against 4% from what outranges them; artillery 17% / 0%; Storm rockets (475) 34 / 20. Short-range
  units barely differ (raiders 21 / 16). They back off at about 0.6 of range. Rule: skirmishers and
  artillery with range 450+ kite at 0.6.
- **Outranged units close in** about half the time: nobody stands and takes fire.
- **Heavies lead** (+16 to +23 elmos ahead); artillery stays with its group (+24), not 350 behind.
- **No siege habit**: structures are targeted as often as they are what's near. Turret-first stays a style.
- **Damaged units aren't pulled out** more than healthy ones (8-11% at every health). Our fighters leave at
  50% health: an experiment to run (retreat_fighter lower), not a change yet.
- Air: gunships fight from 0.69 and come in from behind (-33); bombers drop from close (0.17) and close in
  on long-range targets; fighters engage from 0.3 of range.

## How strong players split fire (data logger v6 "fire" samples, 142 duels)

`gamereport -micro testenv/data/pro-fire` (logged again with `TAG=fire testenv/force-replays.sh`):
19,273 scans, 170,889 unit-moments within 1.2x range of an armed enemy.

| | Strong players |
|---|---|
| holding a set target (BAR's target-on-the-move) | 1.9% |
| shooting a unit | 62% |
| shooters per target | 2.27 |
| shots at a target nobody else shoots | 21% |
| shots at the scan's 3 most-shot targets | 90% |
| coverage (dps x 2 s / health), shot-weighted median | 1.23 |
| shots at targets covered over 1.2x | 51% (set targets: 53%) |
| shots at armed targets | 97% |

- Players hardly use set target, and they don't avoid overkill: half the shots go to targets already
  covered. Fire concentrates by itself (engine targeting plus how the units are placed).
- Our fire control splits at 1.2x over 2 s, about the players' median coverage; in the battle lab it is
  worth +0.13 log2 efficiency over attack orders (test-games.md). Their edge is elsewhere: when and where
  they commit.

## When strong players commit (data logger v7 fight samples: approach, 142 duels)

`gamereport -micro testenv/data/pro-commit`; ours: `gamereport -micro testenv/batch/20261014-1636-sbx-ours-datalog/data -team 0` (12 of
our games, Legion vs Armada medium, sandboxes). A group "moves in" / "pulls back" when its armed units'
average speed toward / away from the enemy group is over 20% of top speed. Trade = their value lost
over ours in the 25 s after.

| Ratio (ours / theirs) | Pros: in / hold / back | Pros: trade in / back | Ours: in / hold / back | Ours: trade in / back |
|---|---|---|---|---|
| 0-0.33 | 38 / 33 / 29% | 1.68 / 1.40 | 40 / 33 / 26% | 0.56 / 0.75 |
| 0.33-0.5 | 38 / 32 / 29% | 0.96 / 0.90 | 38 / 39 / 23% | 0.31 / 0.15 |
| 0.5-0.67 | 43 / 31 / 26% | 1.00 / 0.95 | 48 / 32 / 19% | 0.22 / 1.29 |
| 0.67-0.8 | 46 / 32 / 22% | 0.98 / 0.84 | 48 / 32 / 21% | 0.56 / 1.23 |
| 0.8-1 | 49 / 31 / 20% | 0.99 / 0.94 | 52 / 31 / 17% | 1.15 / 0.37 |
| 1-1.2 | 53 / 29 / 17% | 1.01 / 1.02 | 50 / 31 / 19% | 1.10 / 0.19 |
| 1.2-1.5 | 56 / 31 / 13% | 1.17 / 0.90 | 48 / 39 / 13% | 0.95 / 0.21 |
| 1.5-2 | 59 / 29 / 12% | 1.32 / 1.18 | 49 / 35 / 16% | 0.90 / 0.15 |
| 2-3 | 61 / 29 / 10% | 1.22 / 1.05 | 54 / 32 / 15% | 0.95 / 0.34 |
| 3+ | 63 / 28 / 9% | 0.65 / 0.68 | 60 / 29 / 11% | 0.82 / 0.32 |

- How often they push in or pull back at each ratio is close to ours: the decision isn't the gap.
- The outcome is: players trade about even whatever the ratio, and their retreats cost no more than
  their pushes. Ours trade 0.2-0.6 when outmatched and our retreats bleed (0.15-0.37 at 0.8-3x): the
  fallback is a plain move to the rally point, all at once, backs turned. Next doctrine: a fighting
  retreat.
- Our biggest losses (outmatched, moving in): groups of 8+ near our own base (141k metal lost at
  0.29), i.e. the base defence against BARbarian's pushes.

## Formation and firepower (fight samples v9: positions of both sides, full view)

Pros: 142 duels (`testenv/data/pro-form9`). Ours and BARbarian's: 24 of our games vs BARbarian medium,
each replayed as a spectator with the logger (`testenv/batch/20261015-0004-sbx-ours-full/data`, team 0 ours, team 1 BARbarian).
`scripts/formation_fit.py`: least squares of log2 trade on the log2 strength ratio and formation features
(effects per standard deviation; ** = the 95% bootstrap interval leaves out 0).

| Effect on log2 trade (+1 sd) | Pros (26.5k fights) | Ours (12.3k) | BARbarian (7.9k) |
|---|---|---|---|
| log2 strength ratio | +0.24 ** | +0.35 ** | +0.56 ** |
| our share of units able to shoot | +0.18 ** | +0.12 ** | +0.23 ** |
| our share exposed | -0.08 ** | -0.02 | +0.13 ** |
| their share able to shoot | -0.02 | -0.11 ** | -0.11 ** |
| our spread per sqrt(units) | +0.13 ** | +0.04 | +0.17 ** |
| our width / depth | -0.01 | +0.04 ** | +0.12 ** |
| their approach | -0.08 ** | -0.04 ** | -0.13 ** |
| our turrets near | +0.08 ** | +0.03 | +0.18 ** |
| their turrets near | -0.20 ** | -0.23 ** | -0.10 ** |
| mean log2 strength ratio | +0.42 | **+1.84** | +0.57 |
| mean log2 trade | +0.09 | **-0.17** | +0.22 |

Our fights by strength ratio (share of each side's units able to shoot):

| Ratio | Fights | Our units | Ours shooting | Theirs shooting | Approach | Trade |
|---|---|---|---|---|---|---|
| 0-0.67 | 2203 | 8 | 0.41 | 0.48 | +0.14 | 1.04 |
| 0.67-1.5 | 1406 | 12 | 0.32 | 0.47 | +0.17 | 0.82 |
| 1.5-3 | 1769 | 16 | 0.32 | 0.49 | +0.25 | 0.97 |
| 3+ | 6912 | 35 | **0.23** | 0.45 | +0.30 | **0.80** |

- We usually meet BARbarian 3.6x stronger and still lose more than we kill: our numbers don't become
  firepower. In our big fights only 23% of our units can shoot against 45% of theirs (BARbarian's groups
  of ~11 units: 36-40%). The share of a side's units able to shoot is a top predictor in every source.
- Every engaging unit fight-moves to the same point: the blob funnels in and only its front fires. The
  concave (sc_squads.lua arc) and BAR's roam move state are being tested on big-fight specs
  (testenv/battles-big).

## Our games against BARbarian, by phase (24 games, full view; eco samples per team)

| Minutes | Our army | BARbarian's army | Our extractors | Theirs | Our metal income | Theirs |
|---|---|---|---|---|---|---|
| 10-19 | 5.9k | 6.2k | 16 | 28 | 34 | 55 |
| 20-29 | 15.7k | 7.9k | 22 | 45 | 70 | 96 |
| 30-39 | 41.4k | 10.4k | 27 | 45 | 119 | 119 |
| 40-49 | 80.0k | 25.6k | 30 | 42 | 163 | 138 |
| 50-59 | 88.1k | 58.4k | 26 | 46 | 155 | 177 |
| 60-69 | 95.8k | 98.5k | 24 | 51 | 156 | 202 |

- From minute 20 to 50 our army is 3-4x theirs, and it spends that chasing their raiders at home
  ("engaging intruders (6.3x)"): an army attacks only when no intruder is around, and against a
  raiding opponent one always is. BARbarian takes nearly twice our extractors, overtakes our income
  after minute 50 and wins late (29 of 42 losses at minutes 40-59, all "no units left").
- Rules under test: press the advantage (2.5x their mobile army: go for their side), spend overflowing
  metal (more turrets and labs).

## Against BARbarian hard (24 games, full view: 20261015-0622-sbx-hard-full)

| Minutes | Our extractors | Hard's | Our metal income | Hard's | Our constructors | Hard's | Our army | Hard's |
|---|---|---|---|---|---|---|---|---|
| 5-9 | 10 | 13 | 21 | 26 | 6 | 9 | 1.5k | 1.7k |
| 10-14 | 15 | 33 | 30 | 64 | 9 | 14 | 3.7k | 6.2k |
| 20-24 | 13 | 64 | 43 | 187 | 10 | 23 | 7.1k | 16.0k |
| 30-34 | 12 | 85 | 65 | 331 | 9 | 42 | 8.8k | 50.8k |

- All 24 lost, at minutes 21-48. Hard expands across the map with ever more constructors; we stall at
  12-15 extractors and ~10 constructors from minute 10 (the constructor target follows income: 3 +
  income/10, at most 12). Our trade against hard: log2 -0.63 (against medium about -0.2).
- Under test: the expansion drive (constructors for free metal spots, up to 20).
