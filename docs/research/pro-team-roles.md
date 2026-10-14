# Strong teams' roles and micro (team games)

103 rated team games (average player 25+, BAR's replay archive, mostly 8v8), played headless on force (`PRESET=team testenv/force-replays.sh`). Regenerate: `go run ./cmd/gamereport -roles testenv/data/team` and `-micro testenv/data/team`.

## Roles

Each player labelled by what they spent on: air if 40%+ of their unit metal flew, naval likewise, defense if turrets were 35%+ of everything, eco if they had their side's most extractors while building less army than the side's average, else ground.

| Players per side | Players | ground | air | eco | defense | naval | idle | Sides with an air player | First armed plane (median minute) |
|---|---|---|---|---|---|---|---|---|---|
| 2 | 12 | 83% | 0% | 17% | 0% | 0% | 0% | 0% | 14.8 |
| 4 | 128 | 77% | 12% | 5% | 2% | 4% | 0% | 44% | 8.8 |
| 5 | 20 | 90% | 5% | 0% | 5% | 0% | 0% | 25% | 7.2 |
| 7 | 14 | 79% | 14% | 0% | 7% | 0% | 0% | 100% | 1.9 |
| 8 | 1296 | 65% | 14% | 4% | 5% | 10% | 1% | 94% | 3.5 |

## Micro in team games

| Kind | Samples | Firing | Fights from (range, p25-p75) | Backs off: outranged / outranging enemy | Backs off at | Closes on longer range | Ahead of group | Shoots structures (when near) | Pulls out by health <.35 / <.6 / <.85 / more |
|---|---|---|---|---|---|---|---|---|---|
| assault | 547500 | 39% | 0.87 (0.70-0.97) | 26% / 18% | 0.93 | 40% | 23 | 11% (8%) | 9 / 10 / 9 / 7% |
| skirmisher | 465234 | 41% | 0.74 (0.54-0.90) | 22% / 18% | 0.75 | 39% | 1 | 12% (7%) | 9 / 8 / 8 / 6% |
| fighter | 219826 | 8% | 0.29 (0.15-0.54) | 31% / 26% | 0.99 | 39% | 25 | 0% (4%) | 9 / 27 / 29 / 22% |
| raider | 132153 | 28% | 0.61 (0.38-0.83) | 20% / 19% | 0.98 | 47% | 29 | 6% (4%) | 7 / 10 / 10 / 9% |
| naval | 122548 | 23% | 0.61 (0.40-0.81) | 19% / 18% | 0.86 | 39% | 5 | 11% (8%) | 15 / 12 / 13 / 10% |
| mobile anti-air | 103417 | 4% | 0.58 (0.37-0.77) | 15% / 13% | 0.75 | 26% | -8 | 0% (1%) | 14 / 13 / 12 / 7% |
| heavy | 92260 | 32% | 0.71 (0.44-0.91) | 22% / 20% | 0.97 | 44% | 33 | 10% (6%) | 10 / 10 / 9 / 8% |
| artillery | 72141 | 56% | 0.75 (0.55-0.90) | 17% / 20% | 0.61 | 32% | -5 | 16% (12%) | 7 / 7 / 7 / 4% |
| scout | 49039 | 29% | 0.62 (0.41-0.82) | 26% / 21% | 0.93 | 46% | 30 | 5% (3%) | 9 / 10 / 8 / 8% |
| gunship | 39113 | 54% | 0.62 (0.41-0.80) | 20% / 19% | 0.60 | 29% | -12 | 5% (5%) | 17 / 10 / 9 / 6% |
| bomber | 29429 | 10% | 0.09 (0.05-0.17) | 29% / 27% | 0.39 | 47% | -1 | 5% (20%) | 10 / 19 / 20 / 11% |
| air transport | 639 | 55% | 0.64 (0.45-0.80) | 9% / 10% | 1.11 | 36% | -8 | 1% (0%) | 2 / 7 / 14 / 4% |

## What it means for our sub-commanders

- One air player per side is the norm in bigger games (94% of 8v8 sides, first armed plane by minute
  3.5; in 4v4 44% of sides, minute 9). Our Air Force at minute 10 matches 4v4 timing; with allies (team
  games) it could start earlier.
- Dedicated defence players are rare (2-5%): turrets come from everyone, not a turret specialist. Our
  Defense sub-commander is a convenience for the player, not something strong teams do.
- Most players play ground (65-77%); eco specialists are few (4-5%) and only in bigger teams.
- Unit micro in team games is close to duels (docs/research/pro-micro.md): skirmishers fight from 0.74 of
  range (0.72 in duels), assault units further out (0.87 against 0.73: long, static front lines); kiting
  stays modest.
