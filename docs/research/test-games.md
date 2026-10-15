# Test games against BARbarian

1v1 on All That Simmers, Legion (us) vs Armada (BARbarian), no cheats, game speed 3x, 25 minute limit.
The harness (`testenv/LuaUI/Widgets/zz_sctest.lua`, scenarios `duel` / `duelrules`) plays a light-touch
human who delegates: it builds the first lab with the commander, hands the commander and that lab to an
Economy sub-commander, then creates Defense (two constructors), Army (a second lab), Air Defense and
Intelligence as constructors become available, gives each a standing order, and adds a lab for the Army
when metal keeps piling up. `duel` runs the AI strategist (deepseek-v4.1-flash), `duelrules` only the rules.

Results vary a lot between games with the same code (BARbarian is not deterministic), so single games
show direction, not precise strength. Games 1-11 ran at 3x (about 10 minutes each); from game 12 on, rules
games run at 15x (two minutes each) in batches.

| # | Code | Opponent | Mode | Result | Metal produced | Killed / lost | What we learned |
|---|---|---|---|---|---|---|---|
| 1 | initial | medium | rules | LOSS 10:56 | 6.8k | 1 / 65 | constructors and commander "taken over" by BAR's idle-guard widget forever: 2 extractors at 10 min |
| 2 | guard fix, expansion, converter-aware energy, army helps other zones | medium | rules | TIMEOUT (alive) | 48.0k | 27 / 181 | economy works (+50 metal/s), metal overflows, units die piecemeal |
| 3 | same | medium | strategist (sessions failing) | LOSS 13:37 | - | - | opencode couldn't create sessions (read-only `.opencode`); same code as #2 lost: high variance |
| 4 | same, strategist working | medium | strategist | TIMEOUT (alive) | 32.3k | 23 / 145 | strategist reasons well (counters, retreats, warnings) but the army lab sat forward and died; no replacement |
| 5 | + lanes, overflow spending, rally, counters | medium | rules | TIMEOUT (alive) | 34.8k | 30 / 140 | the player's second lab never finished: harness order not seen as the player's |
| 6 | same + decider (Clef-flash) | medium | strategist + decider | LOSS 19:25 | 25.0k | 20 / 102 | second lab again unfinished: sub-commanders starved the player's build of metal until it decayed |
| 7 | + give way to the player's builds, retreat, 6 constructors | medium | strategist + decider | LOSS 18:50 | 10.7k (enemy 42.6k) | 31 / 99 | early raids (~3 min) kill constructors and the half-built lab; energy stalls at zero |
| 8 | + economy guard, raid turret, quick energy | medium | strategist + decider | LOSS 14:11 | 18.7k (enemy 20.4k) | 33 / 135 | economy at parity (22 extractors, +39 metal/s at 7 min) but fights lost; Defense had no constructor most of the game |
| 9 | + constructor hand-off, spot reservation, decider turrets | medium | strategist + decider | TIMEOUT (7 units left) | 20.4k | 47 / 292 | second lab built (first time); 299 units, 76k damage dealt (best); the Army's lab died at ~15 min and was never replaced, the army bled out |

Fixes after #8: the economy's factory replaces lost constructors for Defense / Air Defense / Intelligence;
the player's build spot is reserved the moment the order arrives; the decider also picks Defense turret
types; Intelligence stops building scouts as raiders.

| 10 | + factory rebuild | medium | strategist + decider | LOSS 8:42 | - | - | the whole team died with the commander (BAR's default mode): the economy had walked it to a far expansion |
| 11 | + commander protection, order race fix | medium | rules, 15x | TIMEOUT (alive) | 16.7k | 21 / 113 | first fast run: the player's first lab had been replaced by a racing sub-commander order |

Fixes after #9: the economy rebuilds a destroyed factory the player had assigned (and hands it back); the
army gathers under our turrets when the enemy near the front outweighs it.

Fixes after #10/#11: the commander only builds inside its zones and falls back from armed enemies or when
hurt; a player order replaced by a racing sub-commander order is put back.

## Fast batches (15x, rules only, `testenv/batch.sh`)

Each line is a batch of games against BARbarian medium on All That Simmers, 25-minute limit. "Alive" means
still standing at 25 minutes (BARbarian wasn't beaten in any game yet). Averages per game.

| Batch | Code | Games | Alive / lost | Metal | Kills / losses | Damage dealt / taken |
|---|---|---|---|---|---|---|
| A | commander protection, order race fix (lab-first opener) | 4 | 2 / 2 | 34.4k | 64 / 197 | 0.70 |
| B | A + army counter-push | 4 | 4 / 0 | 22.7k | 20 / 130 | 0.54 |
| C | B + raid turrets, extractors-first opener, decider on | 6 | 5 / 1 | 39.2k | 51 / 184 | 0.57 |
| D | C without the decider | 6 | 5 / 1 | 35.1k | 46 / 185 | 0.63 |

- The counter-push triggered in only one game of B (the army rarely gets 1.5x stronger than what it sees);
  A vs B is mostly noise.
- C vs D: the decision model (Clef-flash) makes sensible production and turret picks but doesn't change
  results measurably in rules-only play. It stays optional.
- Same code, wildly different games: metal produced ranges from 9k to 66k. Early raids that reach the
  wind farm or the extractors decide most games.
| E | D + basic solar allowed when energy runs out | 6 | 4 / 2 | 30.1k | 37 / 203 | 0.48 |

- E reverted: letting the emergency energy rule pick basic solar (150 metal) instead of only cheap wind
  didn't help (worse on every average).
| AI-1 | D + strategist (lockstep, 10x) | 3 | 1 / 2 | 40.3k | 49 / 291 | 0.66 |

- AI-1: the strategist made the army bleed (291 losses vs 185 rules-only). It changed posture 103 times,
  40 of them to *conserve*, because the prompt read low metal storage as a stall; conserve cuts
  constructor and unit caps. Prompt fixed (low storage is normal; conserve is rare) and posture changes
  are refused within 90 s of the last one.
| AI-2 | AI-1 + prompt fix, posture cooldown | 3 | 2 / 1 | 25.6k | 47 / 217 | 0.57 |

- AI-2: posture flip-flopping is gone (26 changes, 38 refused by the cooldown) and survival is back to the
  rules' level, but the strategist still doesn't beat rules-only play against BARbarian. Against a scripted
  AI the rule engine decides most of the outcome; the strategist's value is in following the player's
  orders, explaining itself and covering what the player asks, not in raw strength.
| H | D, against BARbarian **hard** | 6 | 1 / 5 | 29.7k | 50 / 214 | 0.44 |

- H: hard is out of reach for a light-touch delegating player so far (losses between 14 and 24 minutes).

## Decision model arms (8 fast rules-only games each, medium; design/decision-models.md)

| Arm | Games | Lost | Metal | Kills / losses | Damage dealt / taken |
|---|---|---|---|---|---|
| rules only | 16 | 3 | 32.1k | 39 / 156 | 0.61 |
| our Kev models, all tasks | 8 | 4 | 38.9k | 48 / 273 | 0.47 |
| gradient boosting, all tasks | 8 | 5 | 32.1k | 40 / 275 | 0.47 |
| our Kev fight + turret | 16 | 7 | 35.7k | 50 / 183 | 0.65 |
| fight + turret + lookahead production | 8 | 5 | 18.4k | 31 / 162 | 0.55 |

## Baselines with game analysis (2026-10-13, `make report`, 8 fast rules-only games each)

Reports in `testenv/batch/<dir>/report.md` (gamereport: pace against 26 strong players' replays).

| Arm | Games | Results | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|
| fight-turret-models (test bridge still had the fight + turret routes) | 7 | 5 timeout, 2 loss | 21.4k | 32 / 151 | 0.57 | 15.3 | 6 | 1.6k |
| baseline-rules vs medium | 8 | 3 timeout, 5 loss | 24.5k | 42 / 171 | 0.56 | 18.8 | 5.5 | 2.7k |
| baseline-rules vs hard | 8 | 3 timeout, 5 loss | 38.6k | 31 / 263 | 0.38 | 22.4 | 16 | 4.4k |

- **Medium** raids from minute 2 (Fleas, Flash): we lose about 1k metal before minute 6 for 90 killed,
  the half-built second lab dies at minute 2-3, extractors peak at 7 and fall to 5-6, and the economy
  never recovers (17 metal/s at 15 min against strong players' 58).
- **Hard** raids less early: our economy is on strong players' pace until minute 12 (16 extractors at 8,
  21 at 10, army 4.4k at 12). Then its army (Stumpy, Hammer, Janus, artillery, Flash) arrives: our losses
  jump from about 300 to 1-7k metal per minute, trades after minute 12 are 0.13, and by minute 20 we're
  down to 1.5 factories and 1.6k army. Our turret value (2.8k at 12) is above strong players'; theirs goes
  into the army.
- Rules-only lost 5/8 against medium here, where earlier arms lost 3/16 (no code path differs without the
  models; variance or a cause not found yet).

## Engine v1 (design/engine.md: threat map, squads, doctrine, one lab + army feed, turret budget)

| Arm | Games | Results | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|
| 20261013-1153-baseline-rules | 8 | 3 timeout, 5 loss | 24.5k | 42 / 171 | 0.56 | 18.8 | 5.5 | 2.7k |
| 20261013-1257-engine-v1 | 8 | 7 timeout, 1 loss | 26.8k | 36 / 195 | 0.57 | 8.5 | 12 | 3.8k |
| 20261013-1208-baseline-rules-hard | 8 | 3 timeout, 5 loss | 38.6k | 31 / 263 | 0.38 | 22.4 | 16 | 4.4k |
| 20261013-1314-engine-v1-hard | 8 | 5 timeout, 3 loss | 33.3k | 35 / 270 | 0.46 | 12.2 | 13 | 4.9k |

- Medium: lost 1 of 8 instead of 5; constructors lost halved (8.5 vs 18.8); extractors at 8 min doubled
  (12 vs 5.5); the economy is on strong players' pace until minute 8. What's left: BARbarian's raid groups
  hit the wind farms and the lab in the base while the army fights elsewhere (110 economy buildings and 3
  labs lost per game), and metal overflows ~9 min per game with one lab.
- Hard: lost 3 of 8 instead of 5; trades 0.46 instead of 0.38; army at 12 min 4.9k (strong players'
  median). Fights after minute 12 still trade about 1:5.

## Engine v2 (army defends factories first; turret cover for labs, exposed extractors, wind farms; overflow factory at balanced; constructors route around threats)

| Arm | Games | Results | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|
| 20261013-1330-engine-v2 | 7 | 5 timeout, 2 loss | 29.6k | 51 / 185 | 0.74 | 4.7 | 9 | 3.8k |
| 20261013-1343-engine-v2-hard | 8 | 6 timeout, 2 loss | 47.2k | 53 / 264 | 0.57 | 9.8 | 16 | 5.6k |

- Trades improved against both (medium 0.74 vs 0.57, hard 0.57 vs 0.46), constructor losses fell again
  (4.7 / 9.8 per game), against hard metal produced 47k and the army 5.6k at 12 min (best so far); losses
  2/7 and 2/8 (noise against v1's 1/8 and 3/8).
- One medium game never got a lab: the scripted player's first lab order didn't start (spot taken) and
  the harness never re-ordered it. The harness now retries the first lab like the later ones.
- Late fights: cheap raiders (Goblins) were most of the late losses (500 after minute 12 in v1 hard);
  v3 cuts raiders after the opening and mixes the two strongest units of a category.

## Engine v3 (fewer raiders after the opening, the two strongest units of a category mixed)

| Arm | Games | Results | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|
| 20261013-1400-engine-v3 | 8 | 6 timeout, 2 loss | 31.4k | 72 / 218 | 0.77 | 6.1 | 10.5 | 4.3k |
| 20261013-1415-engine-v3-hard | 8 | 4 timeout, 4 loss | 34.0k | 43 / 240 | 0.56 | 7.1 | 12 | 4.9k |
| engine-v2 vs hard, 16 games pooled | 16 | 11 timeout, 5 loss | 41.1k | 61 / 279 | 0.58 | 10.9 | 11.5 | 4.6k |
| engine-v3 vs hard, 16 games pooled | 16 | 10 timeout, 6 loss | 36.9k | 51 / 236 | 0.54 | 7.1 | 12.5 | 4.1k |

- Against hard the first 8 games read 4 lost vs v2's 2; 8 more of each (same harness) pooled to 16
  show no difference (6 vs 5 lost, trades 0.54 vs 0.58). Against medium v3 is a little better (72 kills
  vs 51, trades 0.77). Kept: it matches BARbarian's mix and loses fewer units for the same trades.

## Full autonomy with raids (autopilot scenario, 40 minutes, vs medium)

| Arm | Games | Results | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|
| 20261013-1520-autopilot-raids-40m | 8 | 4 timeout, 4 loss | 47.6k | 99 / 379 | 0.68 | 15.4 | 10.5 | 5.0k |

- The army attacks now: kills reach their base area (up to 6.9k elmos out; their start is 6.5k away),
  46 raid targets hit across 8 games, more kills per game than ever (46-163). No enemy factory died: their
  base was never scouted, and base raids kept pulling the army home.
- Lost 4/8, all commander deaths at home at 21-32 min when their main army arrived after ours had been
  worn down: trades are still below 1 and income at 15 min is 25 metal/s against strong players' 58.
- The economy built a lab per income tier (2-4 at 20 min, three side by side in one game): strong players
  and BAR's own guidance scale one lab with construction turrets (200 BP for 230 metal vs a lab's 150 for
  470) and add labs only once one is saturated. Changed in the next arm.

## Engine v4 (construction turrets before labs, raids scout their base, attacking armies commit)

| Arm | Games | Results | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|
| 20261013-1544-engine-v4 | 8 | 3 timeout, 5 loss | 24.6k | 32 / 168 | 0.49 | 9.4 | 11.5 | 3.3k |
| 20261013-1558-autopilot-v4-40m | 7 | 4 timeout, 3 loss | 63.1k | 110 / 333 | 0.68 | 18.1 | 12 | 4.2k |

- Balanced (harness) got worse: lost 5/8 (v3 2/8), trades 0.49, energy 81/s at 15 min, 3 construction
  turrets in 8 games, no factories left by 15 min. Causes: an attacking army ignored raids in its own area
  (wind farms wrecked, energy collapsed); turrets (3200 energy each) never affordable, and the turret-first
  rule then blocked the lab on overflow; old threat memories kept raided bases from rebuilding.
- Full autonomy: about even with the first raids arm (3/7 vs 4/8 lost, 63k metal vs 48k).
- Watching a game: metal and energy overflowed with one lab all game: a 48-unit army cap idled the lab,
  storage (10.7k) hid the waste, the turret target was too low. No radar before minute 8-9.5 (only
  Intelligence built them, created at 8 min). Fixed in v5.

## v5 with the strategist, v6, v7 (16-game arms on 3 parallel workers from v6)

| Arm | Games | Results | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|
| 20261013-1719-engine-v6-16 | 16 | 13 timeout, 3 loss | 26.5k | 67 / 193 | 0.80 | 5.6 | 8 | 3.5k |
| 20261013-1739-engine-v7-territory | 16 | 9 timeout, 7 loss | 28.5k | 57 / 193 | 0.71 | 6.6 | 10 | 3.4k |
| 20261013-1633-engine-v5-strategist | 3 | 1 timeout, 2 loss | 24.5k | 49 / 195 | 0.75 | 8.3 | 10 | 3.4k |

- v5 + strategist (3 games, stopped: lockstep paused the game nearly all the time): it read the audit and
  tuned sensibly at first (capped factories, raised the turret budget, raids off against a push) but
  misread a rule (raised nano_per_income to get more turrets), ratcheted engage_attack to 2.0 and
  retreat_fighter to 0.75, and roles overwrote each other's rules. Fixed: rule ownership, rate limits,
  half-steps, clearer names; lockstep now slows to real time instead of pausing.
- v6 (turret mix per area, no army cap, tuning safeguards): best so far, 3/16 lost, trades 0.80. The
  economy plateaus: 8-11 extractors from minute 8, metal ~20/s all game.
- v7 (territory: terrain-aware frontier, pickets for Defense zones and guards): the economy grows (13-14
  extractors at 12-15 min, metal 30/s at 15) but 7/16 lost, all commander deaths (v6: 3): the guards left
  the base core for the pickets. v8 adds a commander escort and a safe-point retreat.
- Every game ends with a loss or at the 25-minute limit (TIMEOUT = alive): nothing else stops them. About
  1 in 5 games needed a second try (first try killed or failed; the cause wasn't kept: batch.sh now saves it).
| v8 (escort, safe-point retreat) |  15 | 14 timeout, 1 loss | 1 | 26.6k | 65 / 208 | 0.73 | 6.2 | 9 | 3.2k |

- v8: 1 of 15 lost (best so far; one game hung loading twice), 1 commander death (v7: 7). The economy
  plateaus again (9 extractors at 8-15 min, 6 at 20): two guards stay with the commander instead of the
  pickets. From here on batches run 45 game minutes (at 25 most games were still going).

## 45-minute games: v14 (response squad) and v16 (tier 2)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261013-1843-engine-v14-responders | 16 | 7 timeout, 9 loss | 2 | 75.4k | 136 / 457 | 0.69 | 15.8 | 11.5 | 4.5k |
| 20261013-1942-engine-v16 | 16 | 16 loss | 3 | 54.2k | 98 / 298 | 0.78 | 18.1 | 12.5 | 5.4k |

- v14: 7/16 alive at 45 min, 2 lost by 25; the economy scales late (30 extractors, +62 metal/s at 40)
  but BARbarian goes tier 2 around minute 25 and its T2 army (Fido, Bulldog, Maverick, Zeus, Panther)
  wins most fights after 28 minutes.
- v16 (T2 lab at minute 18 / 30 metal/s): 16/16 lost. Bug, not tier 2 itself: the "T2 constructor" pick
  took the cheapest builder, the Infestor (212 built across the batch), handed to the army because the
  hand-off wasn't reset, so the lab never stopped; the army shrank from 13k to 7k and the minute-25 push
  wiped the base every game. Fixed in v17 (the real T2 constructor; hand-off reset first).

**v15-v18 are invalid.** The T2 lab's hand-off to the Army called a local function before its definition
(`attempt to call global 'addUnit'`): BAR removed the widget once the second T2 constructor was done
(about minute 12-20), and the rest of each game was played without sub-commanders. Seen in v18 (game 2's
status froze at minute 12; spring's log: `Removed widget: Sub-Commanders`); v15 and v17 used the same
code (v16 mostly never reached the hand-off: its lab built Infestors). Re-measured in v19.

## v19: team plan + commander modes, crash fixed (first clean run since v14)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261013-1843-engine-v14-responders | 16 | 7 timeout, 9 loss | 2 | 75.4k | 136 / 457 | 0.69 | 15.8 | 11.5 | 4.5k |
| 20261013-2044-engine-v19-team-fixed | 7 | 6 timeout, 1 loss | 0 | 180.1k | 194 / 471 | 0.83 | 12.0 | 11 | 5.3k |

- 6/7 alive at 45 min (stopped at 7 for v20). The economy now scales: 150-240 metal/s by minute 35,
  armies of 150k by 45. But no wins: metal at the storage cap, turrets stay T1 (the per-area mix was
  full), the Economy kept ~130 guards at home, and the 200-unit army chased raiders at home during the
  push. The one loss: BARbarian's Hammer push at minute 17 took both labs past a 7k army.
- v20 spends it: turret mix grows with income, tier 2 constructors for Defense, an Army air wing,
  surplus guards to the Army, push ignores small raids.

## v21c: Air Force sub-commander (first wins)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261013-2044-engine-v19-team-fixed | 7 | 6 timeout, 1 loss | 0 | 180.1k | 194 / 471 | 0.83 | 12.0 | 11 | 5.3k |
| 20261013-2132-engine-v21c-airforce | 9 | 2 win, 6 timeout, 1 loss | 0 | 143.6k | 205 / 436 | 0.85 | 11.2 | 14 | 4.3k |

- First wins against BARbarian medium (minutes 40 and 43), both with the Air Force at tier 2 hunting raids
  and striking their economy. Stopped at 9 games: games still being decided at 45 minutes, so batches
  now run 60 minutes (v21c-60, same code).

## force host, 4 at a time, 60 minutes: v21c baseline, v22 (army mix + styles), v23 (pro micro doctrine)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261014-0027-force4-v21c | 12 | 2 win, 6 timeout, 4 loss | 1 | 263.2k | 267 / 814 | 0.82 | 16.7 | 13 | 4.5k |
| 20261014-0047-force4-v22-mix-styles | 12 | 3 win, 7 timeout, 2 loss | 1 | 199.2k | 179 / 709 | 0.71 | 16.1 | 12 | 4.5k |
| 20261014-0105-force4-v23-pro-micro | 12 | 1 win, 8 timeout, 3 loss | 0 | 299.0k | 282 / 1095 | 0.75 | 19.8 | 11 | 3.4k |

- Calibration: at 4 games on 12 cores the force baseline (2 / 6 / 4) matches the Mac's 60-minute batch
  (1 / 9 / 6 of 16); at 6 games with a 660 s limit it didn't (7 wins in 9).
- No arm is clearly better at 12 games; most games end undecided at 60 minutes. Bigger samples come from
  the sandboxes (testenv/sandbox/).

## Sandboxes: v23 by faction (12 games each, 60 min, vs medium)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261014-0117-sbx-v23-legion | 12 | 8 timeout, 4 loss | 1 | 198.2k | 174 / 852 | 0.75 | 23.2 | 12 | 3.6k |
| 20261014-0117-sbx-v23-armada (vs Cortex) | 12 | 5 timeout, 7 loss | 2 | 176.0k | 206 / 737 | 0.84 | 22.7 | 13.5 | 4.5k |
| 20261014-0117-sbx-v23-cortex (vs Armada) | 12 | 5 timeout, 7 loss | 1 | 175.4k | 178 / 955 | 0.62 | 36.4 | 12.5 | 3.7k |

- 36 games of 60 minutes in 13-16 minutes on 9 cpu-16 sandboxes. Armada and Cortex lose more than Legion;
  Cortex loses 36 constructors a game.

## Sandboxes: v24 (finish games: scaled base-attack threshold, pushes only stop for real attacks)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261014-0133-sbx-v24-legion | 12 | 1 win, 7 timeout, 4 loss | 0 | 289.4k | 276 / 996 | 0.83 | 23.8 | 11 | 4.3k |
| 20261014-0133-sbx-v24-armada (vs Cortex) | 12 | 3 win, 3 timeout, 6 loss | 1 | 152.9k | 205 / 689 | 0.92 | 15.7 | 14 | 4.3k |
| 20261014-0133-sbx-v24-cortex (vs Armada) | 12 | 4 timeout, 8 loss | 1 | 117.8k | 106 / 712 | 0.52 | 27.2 | 12.5 | 3.1k |

- 4 wins in 36 (v23: 0 in 36), losses unchanged (18 / 18). Cortex is the weakest faction for us: its
  extractors stall at ~14 after minute 15 (Legion grows to 24 by 35), trades 0.52.
- All factions lose 70-80 extractors a game to raids and rebuild them.
- Extractors at 8 / 20 min (new compare column): Legion 11 / 18, Armada 14 / 12, Cortex 12.5 / 11.
  Armada and Cortex lose their expansions to BARbarian's minute 15-25 pushes (Hammers and Rockos reach
  the base: most of our constructor losses are within 1500 of home) and don't recover; at minute 20
  Cortex has 5.5 constructors and 15 wind turbines a game to Legion's 7.6 and 51 (it builds advanced
  solars and converters instead). Next: why Cortex/Armada pick that energy, and why Legion holds.

## Sandboxes: v25 (constructors flee early, radius scaled by speed) — reverted

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261014-0335-sbx-v25-legion | 12 | 2 win, 5 timeout, 5 loss | 0 | 236.8k | 224 / 887 | 0.73 | 16.7 | 12 / 16.5 | 3.9k |
| 20261014-0335-sbx-v25-armada | 12 | 1 timeout, 11 loss | 0 | 86.8k | 83 / 509 | 0.82 | 21.5 | 14 / 8 | 4.9k |
| 20261014-0335-sbx-v25-cortex | 12 | 4 timeout, 8 loss | 1 | 152.3k | 132 / 876 | 0.57 | 31.1 | 12.5 / 13.5 | 4.4k |

- Worse (Armada 11 losses from 6, extractors at 20 min 8 from 12); constructors still died as often.

## force: focus fire (v26), 12 games each, Legion vs Armada medium, 60 min — kept

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261014-1027-force4-v26-base | 12 | 1 win, 8 timeout, 3 loss | 0 | 256.9k | 214 / 998 | 0.64 | 14.9 | 11 / 16.5 | 4.3k |
| 20261014-1051-force4-v26-focus | 12 | 3 win, 5 timeout, 4 loss | 0 | 246.1k | 222 / 738 | 0.77 | 14.0 | 11 / 17 | 4.2k |

- Engaged army units shoot the enemy in reach worth most per hit point left (armed 3x): trades 0.64 ->
  0.77, units lost 998 -> 738 for the same kills; more undecided games turn into wins (1 -> 3).
- Verdict (bootstrap, added after): overall score +0.10 [-0.13, +0.33] "can't tell"; mid-game enemy metal
  killed +3.0k [+150, +5.8k] **better**; nothing worse. A mid-game improvement, not a proven overall win.

## First learning run (internal/learn): Armada and Cortex vs medium, 6 generations x 24 games, sandboxes

| Matchup | Gen 1 | Gen 2 | Gen 3 | Gen 4 | Gen 5 | Gen 6 | (won / lost of 24) |
|---|---|---|---|---|---|---|---|
| armada-vs-cortex | 2 / 9 | 2 / 11 | 3 / 13 | 5 / 11 | 2 / 9 | 2 / 12 | |
| cortex-vs-armada | 0 / 18 | 0 / 16 | 0 / 14 | 0 / 17 | 0 / 16 | 0 / 20 | |

- No trend: the mean was measured on 4 games a generation, far too few against this much game-to-game
  noise, and 18 rules moved at once. Both matchups moved the same way: constructor_share 1 -> 0.68-0.81
  (more army early), responders_share 0.30 -> 0.23-0.25, defend_base_share 0.08 -> 0.056-0.063; tested
  directly as an A/B on force (v27).
- Ran on the widget before focus fire (frozen arm) and on slow sandboxes (~1x per game).

## force: Cortex vs Armada, default rules vs the first learning run's mean (v27, with focus fire)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261014-1133-force4-v27-cortex-default | 12 | 5 timeout, 7 loss | 1 | 190.0k | 199 / 931 | 0.55 | 26.1 | 11.5 / 18 | 3.6k |
| 20261014-1150-force4-v27-cortex-learned | 12 | 4 timeout, 8 loss | 1 | 159.9k | 131 / 838 | 0.56 | 26.7 | 10 / 16 | 2.7k |

- Not better: a smaller army at 12 minutes (the learned rules also delayed the second lab). Not shipped;
  the bridge now serves only validated stores (`learn validate` after an A/B like this one wins).

## force: mostly-anti-air units (Slasher, Samson, Lance) as anti-air for production (v28) — reverted

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261014-1207-force4-v28-cortex-aa (vs v27 cortex default) | 12 | 3 timeout, 9 loss | 2 | 117.0k | 106 / 681 | 0.55 | 20.6 | 11.5 / 15.5 | 3.7k |
| 20261014-1220-force4-v28-legion-aa (vs v26 focus) | 12 | 1 win, 6 timeout, 5 loss | 2 | 222.5k | 188 / 910 | 0.73 | 22.6 | 11.5 / 19 | 3.5k |

- Verdicts: Cortex all "can't tell" (score -0.06 [-0.16, +0.03]); Legion opening metal lost **worse**
  (+0.9k [+26, +1.9k]), opening kills better, score -0.14 [-0.41, +0.12]. The units are anti-air by
  their weapons, but in our armies they still earned their place. The ground/air damage split stays for
  analysis (aaPrimary), production is as before.

## Battle lab (scenario battle, force): focus fire on vs off, 36 battles each (6 specs x 6) — kept

| Spec | Battles | Won / drawn / lost (off → on) | Efficiency off → on | Our share lost off → on |
|---|---|---|---|---|
| armada-mirror | 6 | 0/6/0 → 0/6/0 | 1.74 → 1.96 | 40% → 36% |
| cortex-mirror | 6 | 5/1/0 → 6/0/0 | 3.16 → 4.52 | 33% → 21% |
| heavy-mirror | 6 | 0/1/5 → 3/3/0 | 0.74 → 1.28 | 96% → 74% |
| legion-mirror | 6 | 1/5/0 → 1/5/0 | 0.68 → 0.74 | 73% → 72% |
| raiders-mirror | 6 | 0/2/4 → 2/0/4 | 0.63 → 0.86 | 95% → 91% |
| skirmishers-vs-assault | 6 | 6/0/0 → 6/0/0 | 8.00 → 8.00 | 0% → 0% |

- Batches 20261014-1257-battle-nofocus, 20261014-1301-battle-focus (3 min each at 6 parallel).
- Pooled over specs the verdict was "can't tell" (efficiency +0.34 [-0.31, +0.98]): the specs differ far
  more from each other than focus fire changes them. Compared within each spec (verdicts now stratify
  battles by spec): efficiency (log2) +0.34 [+0.08, +0.60] **better**, our share lost -0.07 [-0.13,
  -0.02] **better**, score +0.19 [+0.07, +0.31] **better**.
- Seen in the logs: in mirrors the army mostly "holds" (0.5-0.8x), so focus fire (engage only) ran a
  small part of the fight. The response squad took the fastest 30% of the army home, leaving the main
  body at ~0.8x of an equal enemy.

## Battle lab: response squad only from units at home, and micro while holding (36 battles each)

| Arm | Won / drawn / lost | Efficiency (log2, within specs) | Our share lost | Score |
|---|---|---|---|---|
| 20261014-1310-battle-bbase (focus fire, as committed) | 20 / 12 / 4 | | | |
| 20261014-1314-battle-bresp (responders from units in base) | 29 / 3 / 4 | -0.10 [-0.36, +0.15] can't tell | +0.09 [+0.03, +0.16] **worse** | +0.18 [+0.00, +0.34] **better** |
| 20261014-1318-battle-bcontact (that + focus/kite while holding or regrouping) | 24 / 4 / 8 | -0.36 [-0.62, -0.10] **worse** | +0.15 [+0.07, +0.22] **worse** | +0.02 can't tell |

- With the whole army in the fight (no 30% sent home) the army engages instead of holding at 0.8x: more
  wins and shorter battles, but a larger share lost. Efficiency the same.
- Micro while holding is worse: attack orders from the holding line pull units into the enemy one by one.
  Removed.
- The baseline itself moved a lot from the focus-fire batch of the same code (legion-mirror efficiency
  0.74 there, 1.84 here): 6 battles per spec is noisy, use 72 per arm for small effects.

## Learning run (sandboxes): Cortex vs Armada, mid-game rules only, 4 generations x 24 games — nothing learned

- Key cortex-vs-armada-medium-mid, `-only engage_attack@mid,engage_hold@mid,responders_share@mid,turret_budget_scale@mid`,
  scored on the mid game's metal net (killed minus lost, minutes 10-25, thousands). 96/96 games ran.
- Generations 1-2 learned nothing because of a bug (staged rules weren't in the saved store; fixed in
  b0a80b8, the store was rebuilt from its trials). After that the mean moved +0.05 (engage_attack@mid
  1.2 -> 1.25, engage_hold@mid 0.8 -> 0.84) and the mean's own games scored -14.1 against -14.1 at the
  start.
- Scores ranged -44.8 to +7.0 (SD 10.3, median -15.7): the game's course swamps rule changes of this size.
  Not validated, not served.

## Battle lab: overkill-aware focus fire (72 each) — not kept

- 20261014-1322-battle-bresp2 (focus) vs 20261014-1330-battle-boverkill (a target with 1.5x its health
  already coming its way is left to the others): efficiency -0.04 [-0.18, +0.13], share lost +0.01, score
  0.00, all can't tell. Legion mirror read worse (0.80 vs 1.05), the others a little better. Dropped.

## Battle lab with defend specs (9 specs x 8): response squad only from units at home — kept for a game test

| Spec | Efficiency base → arm | Won / drawn / lost base → arm |
|---|---|---|
| armada-mirror | 2.59 → 2.00 | 1/7/0 → 7/1/0 |
| cortex-mirror | 4.15 → 2.13 | 7/1/0 → 7/1/0 |
| heavy-defend | 0.84 → 1.16 | 3/0/5 → 5/1/2 |
| heavy-mirror | 0.90 → 1.14 | 3/0/5 → 4/0/4 |
| legion-defend | 0.93 → 1.33 | 2/6/0 → 5/0/3 |
| legion-mirror | 0.80 → 1.46 | 2/6/0 → 5/0/3 |
| raiders-defend | 0.67 → 1.14 | 0/8/0 → 4/1/3 |
| raiders-mirror | 0.71 → 1.06 | 2/2/4 → 4/1/3 |
| skirmishers-vs-assault | 8.00 → 8.00 | 8/0/0 → 8/0/0 |

- 20261014-1339-battle-bbase9 vs 20261014-1347-battle-bresp9: efficiency (log2) +0.24 [+0.06, +0.43]
  **better**, score +0.19 [+0.04, +0.32] **better**, share lost +0.04 can't tell.
- Against standing enemies (NullAI without `attack`) the same change read worse in the 6-spec lab: a
  cautious army that holds trades well against an enemy that never comes. With them attacking, keeping
  the whole army in the fight wins. The standing-only lab was biased toward caution; defend specs fix it.

## Battle lab in Lightning sandboxes: bolder thresholds (engage attack 1.2 -> 1.0, hold 0.8 -> 0.6) — not kept

- 72 battles per arm, 4 cpu-16 sandboxes each, both arms at once: 3 min per arm. 72/72 ran in both.
- 20261014-1356-sbx-battle-resp (responders from home) vs 20261014-1357-sbx-battle-bold: efficiency
  -0.20 [-0.37, -0.03] **worse**, our share lost +0.07 [+0.02, +0.12] **worse**, score -0.12 can't tell.
  Bolder helped the heavy specs (heavy-defend 0.97 -> 1.55) and hurt raiders and Legion (raiders-defend
  1.15 -> 0.81, legion-defend 1.57 -> 1.03): if anything, the threshold wants to depend on the unit kind.
- Sandboxes (BAR test-31614) agree with force: the same responders arm on both read +0.01 [-0.17, +0.19].

## Battle lab (sandboxes): focus fire per unit kind, 72 each — no change

- 20261014-1401-sbx-battle-fbase (focus for all), -raidnf (raiders fight the nearest), -frontnf (raiders,
  assault and heavy fight the nearest; skirmishers and artillery focus): efficiency +0.13 [-0.06, +0.33]
  and +0.10 [-0.08, +0.28], share lost -0.04 and -0.03, all can't tell. Focus stays on for every kind;
  the switch (`focus = false` in a micro kind) stays for later tests.
- Per-spec efficiencies moved by up to 0.5 between arms of near-identical code (raiders-mirror 0.78 /
  0.92 / 1.25): 8 battles per spec only show effects of about 0.2 log2 or more.

## Battle lab (sandboxes): pacing (a unit 250 elmos ahead of the squad, not in contact, waits) — no change

- 20261014-1407-sbx-battle-pbase vs 20261014-1408-sbx-battle-pace: efficiency +0.04 [-0.12, +0.20], share
  lost -0.01, score -0.04, all can't tell. Battles start with both armies bunched 700 elmos apart, so
  there is little to pace; a test of it needs a spec with a long approach (mixed speeds, 2000+ elmos).
  Removed.

## force: response squad only from units at home (v29), 12 games each, Legion vs Armada medium, 60 min — reverted

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261014-1355-force4-v29-base | 12 | 3 win, 7 timeout, 2 loss | 1 | 308.0k | 221 / 1057 | 0.64 | 18.6 | 11.5 / 25.5 | 4.7k |
| 20261014-1415-force4-v29-resp | 12 | 1 win, 6 timeout, 5 loss | 0 | 229.7k | 184 / 979 | 0.69 | 20.1 | 11.5 / 14.5 | 4.4k |

- Verdicts: extractors at 20 min 25.5 -> 16.9 [-14.3, -2.75] **worse**; score -0.15 [-0.37, +0.06] can't
  tell; the rest can't tell. 24/24 ran, no crashes.
- The lab's best change (+0.24 in battles) cost the economy in games: the army waits at a rally point
  outside the base, so with only home units eligible the response squad seldom formed and raids took the
  expansions.

## Battle lab: fire control with BAR's set-target command (mode settarget) — promising, not yet on

Squad-level allocation every 15 frames: targets best first, shooters (fewest other choices first) until
their dps x killTime covers health x overkill, the rest spill over; orders are set targets (movement
untouched). 72 battles per arm; two void battles (armies never given: a late `cheat 1`) are left out.

| Arm vs attack-order focus | Host | Efficiency (log2) | Score |
|---|---|---|---|
| split (killTime 2, overkill 1.2) | sandboxes | +0.05 [-0.15, +0.27] | +0.11 [-0.00, +0.22] |
| everyone on the best (overkill off) | sandboxes | -0.02 [-0.22, +0.19] | +0.00 |
| spread (killTime 1) | sandboxes | +0.14 [-0.08, +0.37] | +0.11 [-0.01, +0.22] |
| split | force | **+0.23 [+0.04, +0.41] better** | +0.04 [-0.07, +0.15] |
| split, both hosts pooled (144 a side) | | +0.14 [-0.01, +0.29] | +0.07 [-0.01, +0.15] |

- Batches 20261014-1508-sbx-battle-fc{attack,split,all,spread}, 20261014-1508-battle-f-fcattack,
  20261014-1516-battle-f-fcsplit. Splitting fire is what helps (everyone-on-the-best is no better than
  attack orders); a decisive run (spread vs split vs attack, 144+ each) is next.

## Battle lab: air strikes and siege, first baselines (sandboxes, 8 per spec)

- Bombers flew over undefended solar collectors for two minutes without a bomb: a fight-move doesn't
  drop on unarmed structures. Area attack now (29ee591): the open strike destroys 90%, losing nothing.

| Spec | Won / drawn / lost | Efficiency | Our share lost | Their share lost |
|---|---|---|---|---|
| strike-open | 7/1/0 | 8.00 | 0% | 90% |
| strike-aa-flank (one cluster under 3 Nettles) | 8/0/0 | 7.92 | 2% | 96% |
| cortex-strike-aa-flank | 8/0/0 | 8.00 | 0% | 99% |
| strike-aa-covered (called off: right) | 0/8/0 | 1.00 | 0% | 0% |
| llt-line (8 Stouts + 4 Shellshockers vs 6 LLT, 2 Beamers, 1 HLT) | 8/0/0 | 7.60 | 11% | 100% |
| hlt-line | 8/0/0 | 5.59 | 18% | 100% |
| cortex-llt-line | 8/0/0 | 4.25 | 25% | 100% |
| artillery-push (10 Blitz vs 6 Shellshockers + 3 Stouts attacking) | 0/8/0 | **0.37** | 32% | 11% |

- Turret lines are no problem (our artillery outranges them); enemy artillery is: the raiders fight the
  escort tank while the artillery behind it shells them from out of their reach.
- Counting artillery at half in squad decisions (kindWeight) changed nothing on the artillery specs
  (push 0.36 -> 0.29, cortex push 0.55 -> 0.90, standing 0.68 -> 0.61) and leaned worse on the ground
  specs (-0.20 [-0.41, +0.01]): not used.

## Battle lab (sandboxes): doctrines against enemy artillery — none kept

Siege specs (48 per arm) with three artillery specs; ground specs (72) as a check. Base: as committed.

| Arm | Artillery specs (push / stands / cortex push) | Siege verdict | Ground verdict |
|---|---|---|---|
| base | 0.37 / 0.64 / 1.03 | | |
| dive the artillery when its group is within 1100 of the squad's centre | 0.27 / 0.63 / 0.46 (never fired: the group sat ~1450 away) | -0.31, noise | +0.19 can't tell |
| dive when any member is within 900, artillery at half value, fight on as engaged | 0.17 / 0.45 / 0.19 | **-0.62 [-0.93, -0.31] worse** | score -0.14 worse |
| shelled and outmatched: fall back (move) out of reach, else dive | 0.16 / 0.54 / 0.30 | **-0.56 [-0.92, -0.23] worse** | -0.12 can't tell |
| the same without the artillery discount | 0.15 / 0.68 / 0.14 | **-0.82 [-1.12, -0.51] worse** | |

- Diving escorted artillery feeds raiders to the escort; falling back flips on and off as units leave and
  re-enter its reach, and the squad oscillates under fire. Holding (the base) loses least.
- The "push" specs don't push: with `attack 1` the artillery group moved ~100 elmos in a minute and sat
  ~1450 from our squad, so they test standing artillery. The spec needs fixing before it can judge an
  artillery doctrine.

## Battle lab: fire control, decisive run — kept (mode settarget is the default)

- 144 per arm in sandboxes (20261014-1558-sbx-battle-fc2{attack,split,spread}): split +0.12 [-0.02,
  +0.26], spread (killTime 1) +0.06 [-0.07, +0.21] vs attack orders.
- Pooled with the earlier force and sandbox runs (287 vs 286 battles): split vs attack orders, efficiency
  (log2) **+0.13 [+0.03, +0.24] better**, score **+0.07 [+0.01, +0.13] better**, share lost -0.01 can't
  tell. Armada mirror 2.19 -> 3.13, Legion mirror 0.98 -> 1.17, heavy mirror 1.31 -> 1.38.
- Two more battles without armies (the give took over 25 frames in a busy sandbox): the harness now waits
  until both armies are complete, up to 10 s.

## Battle lab learning run: micro numbers (sandboxes, 8 generations x 72 battles) — on a plateau

- Key battle-micro, 9 rules (kite range, outrange, skirmisher and artillery kite/hold, fire control kill
  time, overkill, armed weight), each battle scored as log2 efficiency minus its spec's mean in the
  generation; every 6th battle plays the mean. 576/576 battles counted.
- The mean moved less than 5% anywhere (artillery kite 0.62 -> 0.65, overkill 1.2 -> 1.15, skirmisher
  kite 0.6 -> 0.58, kite range 450 -> 464) and the mean's own battles stayed around 0 (+0.12, -0.09, +0.10,
  +0.13, +0.15, -0.05, 0.00, -0.13). The pro-derived micro values sit on a plateau in these specs; nothing
  to validate.

## Sandboxes: fire control + bomber area attack + unseen-AA memory (v30), 12 games each, Legion vs Armada medium, 60 min — kept

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261014-1610-sbx-v30-base (f794153) | 12 | 5 timeout, 7 loss | 0 | 156.4k | 211 / 632 | 0.80 | 18.1 | 11 / 10 | 3.5k |
| 20261014-1610-sbx-v30-new (9259033) | 12 | 2 win, 5 timeout, 5 loss | 2 | 204.9k | 158 / 825 | 0.77 | 18.7 | 12 / 20 | 3.8k |

- Verdicts: score +0.12 [-0.07, +0.33] can't tell; extractors at 20 min +8.4 [+0.1, +16.1] **better**;
  opening metal lost -1.4k **better**, opening kills -0.8k worse; mid metal lost +4.7k [+0.4k, +9.2k]
  **worse**. 24/24 ran, no crashes.
- Strikes 67 vs 47; 338 "shot down by unseen anti-air" marks over the 12 games (planes now go where
  they die). Sandbox games run on BAR test-31614: compare only with sandbox batches (extractors at 20
  min here 10-20, on force 15-25).

## Battle lab (sandboxes): dodging incoming fire — off

Engine.dodge, 5 times a second: enemy shells and slow unguided missiles over an army (blast >= 30,
horizontal speed <= 14 elmos/frame), where they land, and the units inside the blast that can get out in
time step out (set targets kept). 72 per arm.

| Arm | Siege: efficiency / share lost | Ground: efficiency / share lost | Dodges (max per battle) |
|---|---|---|---|
| landing = the shell's target (unit or ground) | -0.33 [-0.71, +0.04] / +0.02 | -0.01 / +0.02 | 223 |
| landing = the shell's own ballistic arc | **-0.37 [-0.71, -0.04] worse** / +0.00 | -0.08 / +0.03 | 170 |

- The first try never fired: Shellshocker shells have a 37.5 blast, under the 40 cut-off. With 30 they
  are dodged, but our share lost doesn't drop at all (artillery-stands 51% -> 52%); what drops is what
  we kill (dodging units aren't shooting). Off until we know whether the landing prediction is right and
  what actually kills our units under artillery.

## Battle lab: batch effects, and interleaved A/B (corrects earlier verdicts)

- The fighting-retreat arm barely fired in the lab (one fallback per arm), so it was nearly the same
  code, yet siege read -0.40 [-0.78, -0.03] "worse". Identical widgets in separate batches
  (siege-artbase / dbase / d2base / d3base, ground the same) drifted by up to +-0.22 log2, one of six
  "worse": a batch shares its sandboxes, load and timing, so its battles aren't independent and the
  intervals were too narrow.
- Interleaved batches (batch.py --widgets-b: odd games arm A, even games arm B, each pair the same spec
  on the same sandbox; verdicts per pair): A/A on the same widgets read +0.03 [-0.24, +0.32] (siege) and
  -0.01 [-0.19, +0.18] (ground).
- Re-checked interleaved (20261014-18xx-sbx-il-*):

| Change | Specs | Pairs | Efficiency (log2, paired) | Verdict |
|---|---|---|---|---|
| fire control (set targets, overkill split) vs attack-order focus | ground | 144 | -0.04 [-0.21, +0.13] | can't tell: **back to attack orders** (the pooled +0.13 was batch effects) |
| dodging on vs off | siege | 144 | -0.42 [-0.67, -0.17] | **worse** (stays off) |
| dodging on vs off | ground | 72 | +0.16 [-0.03, +0.37] | can't tell |

- Earlier one-arm-per-batch lab verdicts of about 0.2-0.4 log2 or less are doubtful; the replicated
  ones (focus fire vs none, bombers) stand. From now on lab A/Bs are interleaved.

## Sandboxes, interleaved: fighting retreat and stricter home defence, 12 pairs each, Legion vs Armada medium, 60 min — neither kept

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261014-1836-sbx-g31-g31retreat-A (base) | 12 | 3 win, 5 timeout, 4 loss | 0 | 230.3k | 216 / 853 | 0.70 | 19.1 | 13.5 / 18 | 4.8k |
| 20261014-1836-sbx-g31-g31retreat-B (fallbackPace 0.5) | 12 | 3 win, 5 timeout, 4 loss | 0 | 285.8k | 247 / 1186 | 0.73 | 28.0 | 12.5 / 22 | 4.9k |
| 20261014-1836-sbx-g31-g31defend-A (base) | 12 | 1 win, 8 timeout, 3 loss | 1 | 289.0k | 244 / 1114 | 0.75 | 14.0 | 10 / 19.5 | 4.3k |
| 20261014-1836-sbx-g31-g31defend-B (engage defend 0.7) | 12 | 2 win, 6 timeout, 4 loss | 2 | 224.9k | 220 / 861 | 0.75 | 16.5 | 10 / 16.5 | 4.6k |

- Fighting retreat (used 45 times): mid metal lost +5.2k [+2.1k, +8.7k] **worse**, opening kills +0.4k
  better, score +0.03 can't tell. Backing off at half speed keeps the squad in reach longer; it stays off.
- Defend at 0.7 instead of 0.5: nothing tells (score +0.04 [-0.18, +0.24]); stays 0.5.
- 48/48 games ran, no crashes.

## Battle lab, big fights with an edge (32 v 16 units, 6 specs), interleaved, 72 pairs each

| Arm vs base | Efficiency (log2, paired) | Our share lost | Score |
|---|---|---|---|
| concave (each unit to its own place on an arc facing the enemy, at 0.85 x its range) | **+0.61 [+0.44, +0.78] better** | **-0.09 [-0.12, -0.06] better** | **+0.09 [+0.03, +0.17] better** |
| roam move state | -0.01 [-0.20, +0.17] | +0.02 | +0.05 |

- 20261015-0048-sbx-il-big-barc, 20261015-0048-sbx-il-big-broam; 288/288 battles, no harness errors.
- Concave per spec (base -> arc): armada 3.73 -> 6.26, armada defend 3.87 -> 5.06, cortex 3.76 -> 4.79,
  cortex defend 4.79 -> 6.45, legion 1.96 -> 4.55, legion defend 4.05 -> 5.87.
- In the small specs (12 v 12, mostly holding) it was +0.01: no harm, little use. Whole games next.

## Sandboxes, interleaved: concave engagement in whole games, 24 pairs, Legion vs Armada medium, 60 min — kept (on by default)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-0056-sbx-g32-arc-A (base) | 24 | 2 win, 8 timeout, 14 loss | 1 | 191.2k | 198 / 854 | 0.77 | 22.7 | 13 / 17 | 4.7k |
| 20261015-0056-sbx-g32-arc-B (concave) | 24 | 4 win, 10 timeout, 10 loss | 3 | 177.0k | 171 / 730 | 0.86 | 16.0 | 11 / 15.5 | 4.4k |

- Paired: score +0.08 [-0.07, +0.24], late metal lost -36k [-87k, +15k], all can't tell; nothing worse.
  With the lab's +0.61 [+0.44, +0.78] in big fights it is on. 48/48 ran, no crashes.

## Battle lab: hold line (a line facing the threat 450 elmos out from the rally point, not a ring), interleaved, 72 pairs each

| Specs | Efficiency (log2, paired) | Our share lost | Score |
|---|---|---|---|
| ground | **+0.59 [+0.34, +0.82] better** | -0.06 [-0.12, +0.00] | **+0.30 [+0.16, +0.45] better** |
| big fights | -0.06 [-0.19, +0.09] | +0.01 | +0.01 |
| siege | **-0.79 [-1.18, -0.41] worse** | **+0.18 worse** | -0.13 worse |

- The losses are all against artillery: artillery-stands share lost 50% -> 84%, cortex push 16% -> 75%:
  the line walked into the reach of what outranges it. Fixed: places inside the reach of their turrets
  or artillery (range 600+) move back toward the rally point; re-testing.

## Battle lab: the measured counter matrix (20261015-0123-sbx-counter, 264 battles, ~2000 metal a side, they attack)

Mean log2 efficiency, our category (rows) against theirs (columns); 4 battles per cell. `scripts/counter_matrix.py`.

### arm: mean log2 efficiency, ours (rows) vs theirs (columns)

| ours \ theirs | raider | assault | skirmisher | heavy | artillery |
|---|---|---|---|---|---|
| raider | +0.14 (4) | -1.51 (4) | -3.00 (4) | -3.00 (4) | -3.00 (4) |
| assault | +1.27 (4) | -1.14 (4) | +2.04 (4) | -0.67 (4) | +1.00 (4) |
| skirmisher | +0.22 (4) | -2.90 (4) | -0.35 (4) | -2.20 (4) | -3.00 (4) |
| heavy | +2.48 (4) | -1.10 (4) | -0.95 (4) | +0.86 (4) | -0.25 (4) |
| artillery | -0.73 (4) | -1.69 (4) | +1.07 (4) | -2.20 (4) | +0.65 (4) |

### cor: mean log2 efficiency, ours (rows) vs theirs (columns)

| ours \ theirs | raider | assault | skirmisher | heavy | artillery |
|---|---|---|---|---|---|
| raider | +0.44 (4) | -2.85 (4) | -3.00 (4) | -2.86 (4) | -1.33 (4) |
| assault | +2.23 (4) | +0.07 (4) | +3.00 (4) | +1.39 (4) | +0.31 (4) |
| skirmisher | +0.02 (4) | -2.66 (4) | -0.00 (4) | -2.83 (4) | -1.75 (4) |
| heavy | +1.63 (4) | -2.28 (4) | -1.50 (4) | -1.82 (4) | -0.04 (4) |
| artillery | -0.79 (4) | -0.44 (4) | +2.75 (4) | -2.06 (4) | +1.13 (4) |

### leg: mean log2 efficiency, ours (rows) vs theirs (columns)

| ours \ theirs | raider | assault | skirmisher | heavy |
|---|---|---|---|---|
| raider | +0.03 (4) | -0.17 (4) | -1.38 (4) | -2.14 (4) |
| assault | -0.38 (4) | -1.51 (4) | -0.77 (4) | -2.86 (4) |
| skirmisher | +1.51 (4) | +1.12 (4) | +1.01 (4) | +2.81 (4) |
| heavy | +2.44 (4) | -0.76 (4) | -1.81 (4) | +1.29 (4) |

- Mostly what the doctrine's matrix (D.response) says: assault beats skirmishers, raiders and artillery;
  heavies beat raiders; raiders lose to everything but raiders.
- What it shows about our micro: our skirmishers and artillery collapse when the enemy closes in
  (Janus -2.90 against assault units it outranges 2x, -2.20 against heavies; Cortex the same). Kiting
  lived in the engaging micro only; a holding squad (most of the time, always when they come to us)
  never backed off. Kiting while holding is under test.
- Mirrors we should hold even (we defend, they walk in) lean to losses (Armada assault -1.14, Legion
  assault -1.51, Cortex heavy -1.82).
- Fixed (out of reach of turrets and artillery), 72 pairs each: siege -0.07 [-0.47, +0.33] can't tell
  (artillery-stands share lost 50% -> 57%, the first version 84%); ground **+0.46 [+0.24, +0.70]
  better**, score +0.12 [+0.00, +0.24] better. Whole games next.

## Battle lab: a ridge between the sides (fixed) — wide-spec results before this are suspect

- The battle harness fought at the map's centre. All That Simmers has a ~200-elmo ridge 400 elmos east of
  it (heights along the line: 173 175 175 170 158 146 351 148 114): in specs 1400+ elmos wide the two
  sides stood on either side of it. In the assault spec our army "engaged" for 3 minutes without moving
  (goal ~950 from them, distance stuck at ~1560); the artillery "push" never came.
- The harness now picks the flat line nearest the centre (no step over 25 elmos per 64, above water, with
  300 margin) and logs it (`battle site`, `battle ground`). The same assault: a win in 63 s.
- Suspect, to re-run: siege specs (1400-1600), big fights (1500: the concave's +0.61), the counter matrix
  (1400), tactics (1200-1600), and the verdicts drawn on them (dive / fall back / dodge on artillery,
  hold line on siege, kiting while holding on the matrix). Ground specs (700-800) and air strikes are
  unaffected.

## Sandboxes, interleaved: hold line in whole games, 24 pairs — neutral, stays off

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-0152-sbx-g33-holdline-A (base, concave on) | 24 | 3 win, 10 timeout, 11 loss | 2 | 144.2k | 146 / 642 | 0.81 | 17.3 | 10.5 / 14.5 | 3.8k |
| 20261015-0152-sbx-g33-holdline-B (hold line 450) | 24 | 3 win, 8 timeout, 13 loss | 2 | 193.9k | 220 / 764 | 0.77 | 18.3 | 11.5 / 15 | 4.1k |

- Paired: score -0.01 [-0.17, +0.16]; mid kills +2.7k [-0.4k, +5.7k], late losses +37k [-7k, +84k]; all
  can't tell. 48/48 ran, no crashes. Off; it returns with the turret line if that holds up.

## Battle lab re-runs on flat sites (sandboxes, interleaved)

Counter matrix, flat sites (arm A of 20261015-0212-sbx-il-re-khold, 264 battles):

### arm: mean log2 efficiency, ours (rows) vs theirs (columns)

| ours \ theirs | raider | assault | skirmisher | heavy | artillery |
|---|---|---|---|---|---|
| raider | -0.37 (4) | -1.92 (4) | -3.00 (4) | -2.74 (4) | -3.00 (4) |
| assault | +2.10 (4) | -1.83 (4) | +2.56 (4) | -0.37 (4) | -0.00 (4) |
| skirmisher | +0.13 (4) | -2.86 (4) | +0.25 (4) | -2.20 (4) | -3.00 (4) |
| heavy | +2.23 (4) | -0.96 (4) | -1.66 (4) | +0.79 (4) | -1.50 (4) |
| artillery | -0.91 (4) | -1.23 (4) | +1.32 (4) | -0.81 (4) | +0.38 (4) |

### cor: mean log2 efficiency, ours (rows) vs theirs (columns)

| ours \ theirs | raider | assault | skirmisher | heavy | artillery |
|---|---|---|---|---|---|
| raider | +0.29 (4) | -2.89 (4) | -3.00 (4) | -2.35 (4) | -1.39 (4) |
| assault | +2.54 (4) | +0.36 (4) | +3.00 (4) | +1.06 (4) | +0.82 (4) |
| skirmisher | -0.07 (4) | -2.89 (4) | +0.04 (4) | -2.74 (4) | -2.03 (4) |
| heavy | +1.93 (4) | -2.46 (4) | -2.38 (4) | -1.32 (4) | +0.51 (4) |
| artillery | +0.33 (4) | +0.10 (4) | +3.00 (4) | -1.33 (4) | +2.44 (4) |

### leg: mean log2 efficiency, ours (rows) vs theirs (columns)

| ours \ theirs | raider | assault | skirmisher | heavy |
|---|---|---|---|---|
| raider | -0.18 (4) | +0.49 (4) | -3.00 (4) | -2.17 (4) |
| assault | -0.25 (4) | -0.93 (4) | +0.32 (4) | -3.00 (4) |
| skirmisher | +2.92 (4) | +0.69 (4) | -0.51 (4) | +2.56 (4) |
| heavy | +1.70 (4) | -0.65 (4) | -0.42 (4) | +0.10 (4) |

| Change | Specs | Pairs | Efficiency (log2, paired) | Our share lost | Score |
|---|---|---|---|---|---|
| kiting while holding, unless screened by 2+ front-line units within 300 | counter matrix | 264 | **+0.19 [+0.04, +0.34] better** | **-0.03 better** | **+0.08 better** |
| contact fallback (hold within 1200 of a threat -> fall back) + fall back to turrets | retreat | 48 | **+0.38 [+0.08, +0.68] better** | +0.00 | -0.00 |
| the same | ground | 72 | **-0.47 [-0.78, -0.18] worse** | +0.12 worse | -0.15 worse |

- Contact fallback at any ratio throws away mirror fights held at 0.5-0.8x; now only under 0.4x
  (the retreat specs are 0.1-0.3x). Re-testing, and kiting while holding on ground specs.

## Battle lab re-runs on flat sites (force, interleaved)

| Change | Specs | Pairs | Efficiency (log2, paired) | Our share lost | Score |
|---|---|---|---|---|---|
| concave engagement | big fights | 72 | **+0.61 [+0.49, +0.74] better** | **-0.11 better** | better |
| assault with artillery (stand outside their turrets' reach until they're down) | assault | 48 | -0.06 [-0.21, +0.07] | +0.01 | 0.00 |
| hold line at our turrets | defend with turrets | 48 | +0.27 [+0.14, +0.41] | **+0.10 worse** | **-0.21 worse** |

- The concave holds on flat ground (Legion advantage 2.24 -> 5.52, Cortex defend 3.87 -> 5.57): on.
- On a flat site our army takes the fortified position every time either way (24/24 wins): the standoff
  rule adds nothing; off.
- Defending with turrets against a 2x army that reaches us: we lose ~80% either way (efficiency 0.22);
  the line at the turrets loses more battles (20 v 3). Off. Next: the contact fallback to the turrets.

| Change (interleaved) | Specs | Pairs | Efficiency (log2, paired) | Our share lost | Score |
|---|---|---|---|---|---|
| contact fallback under 0.4x + fall back to turrets | retreat | 48 | **+0.59 [+0.28, +0.92] better** | +0.09 worse | -0.03 |
| the same | ground | 72 | +0.17 [-0.03, +0.36] | **-0.05 better** | **+0.15 better** |
| the same | defend with turrets (force) | 48 | **+0.34 [+0.18, +0.51] better** | +0.02 | +0.02 |
| kiting while holding (screened) | ground | 72 | -0.09 [-0.29, +0.11] | +0.01 | -0.02 |

- Both into a whole-game test.

## Whole games, interleaved: kiting while holding + contact fallback to turrets — not kept

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-0250-sbx-g34-retreat-kite-A (base) | 24 | 1 win, 12 timeout, 11 loss | 0 | 172.3k | 200 / 857 | 0.75 | 23.4 | 11 / 15 | 3.9k |
| 20261015-0250-sbx-g34-retreat-kite-B (bundle) | 24 | 3 win, 7 timeout, 14 loss | 3 | 173.5k | 198 / 769 | 0.81 | 19.7 | 11 / 17 | 3.9k |
| 20261015-0250-force4-g34-retreat-kite-A (base) | 12 | 3 win, 3 timeout, 6 loss | 1 | 186.8k | 189 / 659 | 0.78 | 14.2 | 12 / 17 | 4.5k |
| 20261015-0250-force4-g34-retreat-kite-B (bundle) | 12 | 1 win, 7 timeout, 4 loss | 0 | 233.9k | 227 / 1003 | 0.78 | 23.2 | 13 / 16.5 | 4.1k |

- Sandboxes: score -0.00 [-0.12, +0.12], opening kills worse; force: score -0.05 [-0.32, +0.20], late
  metal lost +72k [+15k, +127k] **worse**. 72/72 ran, no crashes. Both stay off: better in isolated
  battles, not in games.
- What decides these games is macro (base arm's report): 6 factories lost per game, metal storage full
  727 s while energy is near empty 598 s (income we can't spend), 23 constructors lost, the commander
  dead in 11 of 24. Energy is next.

## Whole games, interleaved: energy first (generators before build power, labs, radar while energy is behind metal) — kept

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-0328-sbx-g35-energy-A (base) | 24 | 4 win, 11 timeout, 9 loss | 2 | 206.3k | 221 / 875 | 0.67 | 22.8 | 11 / 17.5 | 3.5k |
| 20261015-0328-sbx-g35-energy-B (energy first) | 24 | 4 win, 12 timeout, 8 loss | 2 | 270.5k | 249 / 1126 | 0.82 | 21.1 | 13 / 21 | 4.1k |
| 20261015-0328-force4-g35-energy-A (base) | 12 | 1 win, 7 timeout, 4 loss | 0 | 315.3k | 256 / 1361 | 0.68 | 30.9 | 12 / 23.5 | 4.3k |
| 20261015-0328-force4-g35-energy-B (energy first) | 12 | 11 timeout, 1 loss | 0 | 344.8k | 290 / 1543 | 0.79 | 24.1 | 12.5 / 20 | 4.0k |

- Energy near empty 472 -> 133 s (sandboxes), 490 -> 112 s (force). Late enemy metal killed +35k [+3k,
  +68k] **better** (sandboxes); scores +0.04 / +0.03 can't tell; losses 9 -> 8, 4 -> 1. 72/72 ran.
- Metal storage full went up (578 -> 634 s, 798 -> 940 s): energy no longer holds building back, build
  power does. Next: spending the metal.
- Energy was found by the economy report (energy near empty 598 s a game, 9.4 energy per metal at
  minute 8) and the unused doctrine value energyPerMetal.

## Whole games, interleaved: safe generators (behind the base, out of known threat) — not kept

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-0411-sbx-g36-safegen-A (base) | 24 | 3 win, 15 timeout, 6 loss | 1 | 259.2k | 229 / 1048 | 0.81 | 20.1 | 11.5 / 18 | 4.2k |
| 20261015-0411-sbx-g36-safegen-B (safe generators) | 24 | 1 win, 13 timeout, 10 loss | 3 | 191.3k | 200 / 853 | 0.75 | 20.0 | 9.5 / 15 | 3.3k |
| 20261015-0411-force4-g36-safegen-A (base) | 12 | 2 win, 4 timeout, 6 loss | 1 | 217.6k | 209 / 966 | 0.84 | 24.8 | 11 / 15 | 3.1k |
| 20261015-0411-force4-g36-safegen-B (safe generators) | 12 | 1 win, 5 timeout, 6 loss | 1 | 194.4k | 178 / 809 | 0.81 | 16.2 | 10.5 / 15 | 3.5k |

- Wind turbines lost per game 79 -> 68 and 87 -> 46, economy buildings 192 -> 170 and 206 -> 137, but
  sandbox score -0.12 [-0.24, +0.00], extractors at 20 min -4.2 [-9.2, +1.2]: the walk to the back of
  the base costs the economy more than the raids did. Off. 72/72 ran.

## Whole games, interleaved: spending overflowing metal (2x construction turrets per lab, 3 more labs while metal is 90% full) — kept

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-0443-sbx-g37-overflow-A (base) | 24 | 1 win, 14 timeout, 9 loss | 1 | 286.2k | 229 / 1176 | 0.73 | 21.1 | 12 / 20 | 3.6k |
| 20261015-0443-sbx-g37-overflow-B (overflow spending) | 24 | 3 win, 14 timeout, 7 loss | 1 | 277.2k | 267 / 1109 | 0.71 | 18.0 | 13 / 18 | 3.6k |
| 20261015-0443-force4-g37-overflow-A (base) | 12 | 3 win, 5 timeout, 4 loss | 1 | 228.5k | 208 / 811 | 0.78 | 11.8 | 11.5 / 20 | 3.6k |
| 20261015-0443-force4-g37-overflow-B (overflow spending) | 12 | 3 win, 8 timeout, 1 loss | 0 | 351.7k | 244 / 1144 | 0.73 | 15.8 | 14 / 20 | 4.1k |

- Both hosts pooled (36 pairs): mid enemy metal killed +2.7k [+0.6k, +5.0k] **better**, score +0.06
  [-0.06, +0.20]; losses 13 -> 8, wins 4 -> 6. 72/72 ran, no crashes. On.
- Energy first pooled the same way (36 pairs): late enemy metal killed +26k [+2k, +50k] better, score
  +0.04 [-0.08, +0.15].

## Whole games, interleaved: pressing the advantage (2.5x their mobile army: go for their side) — kept

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-0527-sbx-g38-dominance-A (base) | 24 | 4 win, 12 timeout, 8 loss | 2 | 267.2k | 282 / 1138 | 0.74 | 20.4 | 11 / 20 | 3.6k |
| 20261015-0527-sbx-g38-dominance-B (pressing) | 24 | **10 win**, 6 timeout, 8 loss | 1 | 194.2k | 263 / 801 | 0.82 | 19.6 | 11.5 / 16.5 | 3.6k |
| 20261015-0527-force4-g38-dominance-A (base) | 12 | 2 win, 6 timeout, 4 loss | 2 | 289.9k | 262 / 1105 | 0.69 | 15.2 | 13.5 / 19 | 4.0k |
| 20261015-0527-force4-g38-dominance-B (pressing) | 12 | **6 win**, 2 timeout, 4 loss | 0 | 270.7k | 250 / 856 | 0.67 | 15.2 | 12.5 / 22 | 4.0k |

- Pooled 36 pairs: score **+0.19 [+0.03, +0.34] better**, late metal lost **-53k [-96k, -11k] better**;
  wins 6 -> 16, losses 12 -> 12. The rule fired 878 times. 72/72 ran, no crashes. On.
- Against BARbarian medium we now win more than we lose (16 / 8 / 12).
- Found by replaying our games with full view: our army was 3-4x theirs from minute 20 to 50 and spent
  it on their raiders at home.

## Pressing at 1.8x instead of 2.5x (sandboxes, 24 pairs) — 1.8 kept; against BARbarian hard (force) — lost everything

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-0604-sbx-g39-dominance18-A (2.5x) | 24 | 9 win, 11 timeout, 4 loss | 0 | 267.2k | 240 / 988 | 0.71 | 14.5 | 12 / 18.5 | 4.2k |
| 20261015-0604-sbx-g39-dominance18-B (1.8x) | 24 | 13 win, 6 timeout, 5 loss | 1 | 204.9k | 242 / 674 | 0.85 | 10.7 | 13 / 20 | 4.2k |
| 20261015-0603-force4-g39-hard-old-vs-new-A (ee612f3, hard) | 12 | 12 loss | 1 | 64.8k | 65 / 409 | 0.49 | 20.7 | 11.5 / 12.5 | 3.6k |
| 20261015-0603-force4-g39-hard-old-vs-new-B (today, hard) | 12 | 12 loss | 2 | 69.7k | 74 / 433 | 0.51 | 23.2 | 13 / 16.5 | 4.2k |

- 1.8x: late metal lost -60k [-103k, -17k] better, score +0.10 [-0.11, +0.31]; 13 / 6 / 5 against
  BARbarian medium. On.
- BARbarian hard beats both old and new in all 24 games; new loses less in the opening (-1.3k better).
  Next: what hard does that medium doesn't (full-view replays).

## force, interleaved: Cortex vs Armada medium, before this round's changes (ee612f3) vs now — worse

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-0633-force4-g40-cortex-old-vs-new-A (ee612f3) | 12 | 2 win, 4 timeout, 6 loss | 3 | 184.1k | 130 / 813 | 0.56 | 27.5 | 14 / 15 | 3.5k |
| 20261015-0633-force4-g40-cortex-old-vs-new-B (now) | 12 | 4 timeout, 8 loss | 3 | 169.1k | 129 / 1006 | 0.52 | 25.9 | 13 / 11 | 3.0k |

- Score -0.14 [-0.29, -0.01] **worse**; extractors at 20 min 15 -> 11. Everything this round was measured
  with Legion; one of the changes costs Cortex. Bisecting (sandboxes): now vs now without each of
  pressing, energy first, overflow spending, the concave.

## Whole games, interleaved: expansion drive (constructors for free metal spots, up to 20) — kept

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-0646-sbx-g41-expand-A (base, medium) | 24 | 6 win, 5 timeout, 13 loss | 1 | 162.8k | 174 / 746 | 0.72 | 20.8 | 11 / 14 | 3.9k |
| 20261015-0646-sbx-g41-expand-B (expansion drive) | 24 | 8 win, 8 timeout, 8 loss | 3 | 231.7k | 212 / 838 | 0.67 | 19.7 | 12 / 20 | 3.6k |
| 20261015-0701-force4-g41-expand-hard-A (base, hard) | 12 | 12 loss | 2 | 75.0k | 103 / 494 | 0.53 | 25.4 | 11 / 21 | 3.7k |
| 20261015-0701-force4-g41-expand-hard-B (expansion drive, hard) | 12 | 12 loss | 0 | 100.1k | 75 / 561 | 0.52 | 34.3 | 12 / 21 | 3.7k |

- Medium: extractors at 20 min +7.5 [+2.6, +13.2] **better**, losses 13 -> 8, score +0.08 [-0.15, +0.30].
  On. Hard: no change (it kills the expansions; constructors lost 25 -> 34). 72/72 ran.

## force, interleaved: Armada vs Cortex medium, ee612f3 vs now (12 pairs) — fine

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-0717-force4-g43-armada-old-vs-new-A (ee612f3) | 12 | 1 win, 6 timeout, 5 loss | 0 | 188.2k | 193 / 729 | 0.90 | 19.6 | 12 / 15.5 | 4.1k |
| 20261015-0717-force4-g43-armada-old-vs-new-B (now) | 12 | 3 win, 4 timeout, 5 loss | 0 | 234.1k | 212 / 858 | 0.64 | 22.8 | 13.5 / 17.5 | 3.9k |

- Score +0.07 [-0.14, +0.27]; extractors at 20 min +4.9 [+1.1, +8.6] better.

## Cortex bisection (sandboxes, interleaved, 12 pairs each; B = now without one change)

| Without | Score | Extractors at 20 min | Now's results in that batch |
|---|---|---|---|
| pressing the advantage | +0.08 [-0.00, +0.15] | **+6.2 [+0.6, +12.2] better** | 0 / 0 / 12 |
| energy first | -0.08 [-0.36, +0.19] | +0.6 | 3 / 2 / 7 |
| overflow spending | +0.18 [-0.01, +0.40] | **+5.2 [+0.6, +10.4] better** | 1 / 3 / 8 |
| the concave | +0.04 [-0.04, +0.12] | +4.1 [-0.2, +8.7] | 1 / 4 / 7 |

- Pressing costs Cortex most: its army leaves while BARbarian raids its base and expansions (Cortex's
  known weak spot, minutes 9-25). Testing safe pressing (not while the team defends, nor with more of
  their mobile units near home than the response squad). Overflow spending leans against Cortex too.

## Safe pressing (press only with home safe) — not kept

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-0747-sbx-g44-cortex-presssafe-A (Cortex, pressing) | 24 | 4 win, 10 timeout, 10 loss | 3 | 260.4k | 154 / 1119 | 0.49 | 25.2 | 13 / 27 | 2.4k |
| 20261015-0747-sbx-g44-cortex-presssafe-B (Cortex, safe pressing) | 24 | 3 win, 5 timeout, 16 loss | 3 | 178.2k | 112 / 845 | 0.49 | 29.2 | 12 / 16 | 2.2k |
| 20261015-0747-force4-g44-legion-presssafe-A (Legion, pressing) | 12 | 7 win, 4 timeout, 1 loss | 0 | 229.8k | 231 / 661 | 0.77 | 9.8 | 14.5 / 25.5 | 3.9k |
| 20261015-0747-force4-g44-legion-presssafe-B (Legion, safe pressing) | 12 | 7 win, 1 timeout, 4 loss | 1 | 158.0k | 223 / 618 | 0.89 | 15.1 | 11 / 23 | 3.8k |

- Cortex: extractors at 20 min -6.7 [-11.9, -1.6] **worse**, losses 10 -> 16; Legion losses 1 -> 4.
  Off. Holding the army back for home's sake costs more than the raids.
- With the expansion drive on, Cortex with pressing reaches 24 extractors at minute 20 (the regression
  was measured before it). Legion now: 7 / 4 / 1 against BARbarian medium.

## Cortex again, ee612f3 vs now (with the expansion drive), both hosts, 36 pairs — no regression, still weak

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-0813-sbx-g45-cortex-old-vs-new-A (ee612f3) | 24 | 6 timeout, 18 loss | 6 | 99.7k | 122 / 579 | 0.59 | 22.9 | 12 / 10 | 2.5k |
| 20261015-0813-sbx-g45-cortex-old-vs-new-B (now) | 24 | 3 win, 4 timeout, 17 loss | 7 | 128.4k | 147 / 580 | 0.58 | 29.1 | 12 / 13 | 1.8k |
| 20261015-0813-force4-g45-cortex-old-vs-new-A (ee612f3) | 12 | 4 timeout, 8 loss | 0 | 144.0k | 156 / 804 | 0.69 | 23.5 | 12 / 14.5 | 3.1k |
| 20261015-0813-force4-g45-cortex-old-vs-new-B (now) | 12 | 3 timeout, 9 loss | 1 | 146.0k | 132 / 828 | 0.51 | 39.0 | 12.5 / 13.5 | 2.3k |

- Pooled: score +0.04 [-0.04, +0.13] can't tell, extractors at 20 min +2.2 [-1.4, +5.9], mid metal lost
  +8.5k [+4.6k, +12.5k] worse (constructors lost 23 -> 29-39). The earlier "worse" (g40) doesn't hold.
- Cortex wins 3 of 72 against Armada medium (Legion 13-16 of 24-36): Cortex needs its own work (its
  constructors and expansions die in BARbarian's mid-game raids).

## Army parity (no new constructors while our army is under 0.6x theirs) — not kept

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-0909-sbx-g46-cortex-parity-A (Cortex) | 24 | 5 win, 3 timeout, 16 loss | 3 | 153.8k | 152 / 761 | 0.56 | 29.1 | 12.5 / 18.5 | 2.3k |
| 20261015-0909-sbx-g46-cortex-parity-B (Cortex, parity) | 24 | 5 win, 3 timeout, 16 loss | 3 | 170.9k | 167 / 777 | 0.54 | 28.0 | 12 / 17 | 2.1k |
| 20261015-0908-force4-g46-legion-parity-A (Legion) | 12 | 7 win, 4 timeout, 1 loss | 0 | 256.9k | 265 / 977 | 0.66 | 14.6 | 10.5 / 24 | 3.5k |
| 20261015-0908-force4-g46-legion-parity-B (Legion, parity) | 12 | 9 win, 1 timeout, 2 loss | 0 | 159.9k | 226 / 494 | 0.76 | 8.3 | 13 / 18 | 3.4k |

- Cortex: no change (army at 12 min the same). Legion: mid and late losses better, extractors at 20 min
  -8.3 [-13.6, -3.4] worse. Off.
- Cortex spends nearly as much on turrets as on its army at minutes 10-14 (1.6k v 1.9k; Legion 1.8k v
  5.9k at 10-19): next, a smaller turret budget for it.

## Cortex with half the turret budget (both hosts, 36 pairs) — worse, not kept

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-0935-sbx-g47-cortex-turrets-half-A (full) | 24 | 3 win, 6 timeout, 15 loss | 5 | 144.6k | 121 / 628 | 0.56 | 22.9 | 12 / 17 | 2.1k |
| 20261015-0935-sbx-g47-cortex-turrets-half-B (half) | 24 | 1 win, 5 timeout, 18 loss | 2 | 109.1k | 117 / 710 | 0.58 | 35.2 | 12 / 13 | 2.2k |
| 20261015-0935-force4-g47-cortex-turrets-half-A (full) | 12 | 5 timeout, 7 loss | 1 | 175.5k | 119 / 826 | 0.49 | 25.7 | 12.5 / 8 | 1.8k |
| 20261015-0935-force4-g47-cortex-turrets-half-B (half) | 12 | 2 timeout, 10 loss | 1 | 83.7k | 84 / 607 | 0.52 | 35.0 | 10.5 / 11 | 1.8k |

- Pooled: score -0.04 [-0.15, +0.07], extractors at 20 min -3.7 [-8.8, +1.4], army at 12 min +0.2k;
  losses 22 -> 28, constructors lost ~24 -> 35. The turret metal didn't become army; the turrets were
  what kept Cortex's constructors alive. Cortex's early army gap is elsewhere (unit choice or
  production), for a per-faction look.

## Faction overlays, first tests

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1013-sbx-g48-cortex-overlay-A (Cortex, classifier fix) | 24 | 3 win, 3 timeout, 18 loss | 11 | 121.3k | 106 / 581 | 0.61 | 21.7 | 11.5 / 14.5 | 2.2k |
| 20261015-1013-sbx-g48-cortex-overlay-B (+ Cortex overlay) | 24 | 3 win, 5 timeout, 16 loss | 8 | 134.8k | 111 / 659 | 0.60 | 23.5 | 12 / 17.5 | 1.9k |
| 20261015-1013-force4-g48-legion-classifier-A (Legion, before) | 12 | 8 win, 1 timeout, 3 loss | 0 | 166.0k | 214 / 553 | 0.79 | 13.2 | 13 / 21 | 3.6k |
| 20261015-1013-force4-g48-legion-classifier-B (Legion, classifier fix) | 12 | 5 win, 3 timeout, 4 loss | 0 | 221.9k | 235 / 770 | 0.72 | 15.7 | 10.5 / 16 | 3.4k |

- Cortex overlay: score +0.02 [-0.11, +0.16], but **no Tzar was built in either arm**: Cortex goes the
  bot route, and only a construction vehicle (corcv) can build the T2 vehicle plant (corvp's cheapest
  constructor is the Trapper mine layer). Overlay now keeps one corcv; re-testing, counting Tzars.
- Classifier fix on Legion: score -0.21 [-0.50, +0.06] (wins 8 -> 5); re-testing with 24 pairs.

## Armada cloak overlay, first test (both hosts, 36 pairs) — no Gremlins built

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1038-sbx-g49-armada-cloak-A (no overlay) | 24 | 13 win, 5 timeout, 6 loss | 0 | 149.9k | 217 / 553 | 0.84 | 15.5 | 13 / 18 | 5.0k |
| 20261015-1038-sbx-g49-armada-cloak-B (overlay) | 24 | 15 win, 1 timeout, 8 loss | 2 | 144.0k | 201 / 460 | 0.89 | 13.9 | 12.5 / 20 | 4.9k |
| 20261015-1038-force4-g49-armada-cloak-A (no overlay) | 12 | 8 win, 1 timeout, 3 loss | 0 | 164.8k | 264 / 480 | 0.85 | 10.8 | 13.5 / 22 | 4.3k |
| 20261015-1038-force4-g49-armada-cloak-B (overlay) | 12 | 7 win, 2 timeout, 3 loss | 1 | 148.0k | 181 / 496 | 0.93 | 11.8 | 13.5 / 22 | 4.6k |

- Pooled score -0.01 [-0.19, +0.18]: no Gremlin was built (they come from the T2 vehicle plant, which
  only a construction vehicle builds; our games go the bot route), only Sharpshooters were kept cloaked.
  Overlay now keeps one armcv and the plant from 50 metal/s; re-testing.
- Armada vs Cortex medium now: 21 wins, 6 alive, 9 lost of 36 (no overlay).

## Cortex overlay re-test with a construction vehicle (sandboxes, 24 pairs) — still no Tzar

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1102-sbx-g50-cortex-tzar-A (no overlay) | 24 | 3 win, 7 timeout, 14 loss | 3 | 204.0k | 142 / 889 | 0.52 | 27.6 | 12 / 19 | 2.6k |
| 20261015-1102-sbx-g50-cortex-tzar-B (overlay + corcv) | 24 | 6 win, 6 timeout, 12 loss | 3 | 218.5k | 161 / 959 | 0.59 | 27.0 | 12 / 25 | 2.2k |

- Score +0.12 [-0.06, +0.31], can't tell, and **0 Tzars, 0 T2 vehicle plants**: the corcv was built
  but belonged to the Army, whose plan only repairs; and `Jobs.techVehicles` asked `canSpend`, whose
  cap (220 + 18 x income: 1120 at 50 metal/s) is under the plant's 2600, so no faction got the plant
  below 132 metal/s. Fixed (no cap, like the T2 lab; the Army's constructor builds it); re-tests
  g52 (Armada) and g53 (Cortex) queued with the fix in both arms.

## Strategic structures, smoke tests 4-5 (force, Legion, every feature on)

- Smoke 4: after letting strategic builds past the cost cap, Legion's T2 constructor started a
  **Starfall** (63000 metal) as its "long-range cannon" 26 times (the lrpc flag covers range 3000-20000;
  the pick sorted by range). Now the cheapest gun under `lrpc.maxCost` 8000 (the Olympus). Resurrection
  bots never resurrected: they have a radar, so Intel.thinkUnit kept them on radar posts. Now left to
  `Engine.strategicControl`. Juno: "can't place" 6x at the crowded base centre: now placed behind it.

## Classifier "armoured long-range units are heavies", Legion re-test (pooled force 12 + sandboxes 24)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| pool-lcls-A (before) | 36 | 21 win, 8 timeout, 7 loss | 0 | 210.5k | 258 / 766 | 0.74 | 14.2 | 12 / 21.5 | 4.0k |
| pool-lcls-B (heavy rule) | 36 | 16 win, 6 timeout, 14 loss | 3 | 184.0k | 207 / 675 | 0.70 | 16.2 | 11 / 16 | 3.6k |

- Score -0.15 [-0.31, +0.02] (sandboxes alone -0.11, force -0.21): both leaning worse. The rule made
  Legion's Incinerator (2300 metal, range 725) and Javelin heavies, so they stopped kiting. **Reverted**;
  the Tzar stays a skirmisher (the Cortex overlay's preference works within any category).

## Strategic structures, smoke test 5 (force, Legion, 8 games, every feature on)

- 3 win, 3 alive, 2 lost. Started: Olympus 7 (5 games), Juno 6, Aegis 8, Soteria 19 (max 1: re-started
  after losing it, or several builders), and resurrection works: 49 wrecks raised (Karkinos, Fatboy,
  Archangel, Pluto...). No sign yet that a cannon finished or fired, or a Juno shot: logs for finished
  strategic structures and each cannon target added for smoke 6.

## Strategic structures, smoke test 6 (force, Legion, 8 games, every feature on)

- **7 win, 1 loss.** Everything works end to end: 7 Olympus finished and fired (on Sentries 138x,
  extractors 54x, Beamers, Overwatch: whatever static of theirs they knew in range), a Juno fired on 2
  radar/jammers, Aegis and Soteria built. "new Blindfold" 79x: Legion's Blindfold gunship has a Juno
  weapon and was counted as our Juno (fixed: `junoSilo`). Note the status block reprints each
  sub-commander's last log line every 30 s: count events by distinct frames, not lines.
- Whole-game A/B started: force-g54-strategic (Legion, all off vs all on, 24 pairs).

## Armada overlay with the T2 vehicle plant fix (sandboxes, 24 pairs, vs Cortex medium)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1148-sbx-g52-armada-overlay3-A (no overlay) | 24 | 10 win, 8 timeout, 6 loss | 0 | 168.1k | 204 / 637 | 0.82 | 18.5 | 12 / 15 | 3.8k |
| 20261015-1148-sbx-g52-armada-overlay3-B (overlay) | 24 | 14 win, 5 timeout, 5 loss | 0 | 145.9k | 210 / 443 | 0.94 | 13.2 | 13 / 20 | 4.5k |

- Score +0.12 [-0.10, +0.33]; enemy metal killed mid-game **better** +4.9k [+0.6k, +9.4k]; extractors
  at 20 min **better** +5.7 [+2.3, +9.7]. Gremlins now in 12 of 24 games (T2 vehicle plant in 7, the
  armcv in 19); none in A (no arm ever built the plant without the overlay). Leaning better: kept.

## Cortex overlay with the T2 vehicle plant fix (sandboxes, 24 pairs, vs Armada medium)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1203-sbx-g53-cortex-overlay3-A (no overlay) | 24 | 4 win, 1 timeout, 19 loss | 5 | 118.4k | 133 / 596 | 0.65 | 30.4 | 11 / 13 | 2.0k |
| 20261015-1203-sbx-g53-cortex-overlay3-B (overlay) | 24 | 3 win, 4 timeout, 17 loss | 5 | 122.2k | 107 / 575 | 0.57 | 23.0 | 11 / 13 | 1.5k |

- Score -0.04 [-0.17, +0.10]; army at 12 min -459 [-1.1k, +160]. Tzars in only 3 of 24 games (plant in
  4): Cortex rarely reaches 50 metal/s before it is losing. **Cortex overlay off**; Cortex's gap is the
  early game (19 of 24 lost; army a third of BARbarian's at 12 min), the next thing to look at.

## Legion overlay (sandboxes, 24 pairs, vs Armada medium): Mantis drone carriers and Cleavers

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1221-sbx-g55-legion-overlay-A (no overlay) | 24 | 9 win, 10 timeout, 5 loss | 0 | 243.8k | 244 / 774 | 0.67 | 13.7 | 12 / 18.5 | 4.2k |
| 20261015-1221-sbx-g55-legion-overlay-B (overlay) | 24 | 12 win, 7 timeout, 5 loss | 1 | 224.4k | 250 / 969 | 0.79 | 12.2 | 12 / 19.5 | 4.0k |

- Overlay (in the arm only, not on main): T2 vehicle plant from 50 metal/s, one legcv, 4 Mantis
  (legvcarry), the Cleaver (legamcluster) preferred. Score +0.08 [-0.18, +0.33], can't tell; late
  enemy metal killed +17.8k [-4.9k, +39k], mid metal lost +3.1k [-0.3k, +6.5k]. Mantis in 11 games,
  Cleavers in 9, the plant in 9. 24 more pairs queued on force (force-g57) to pool.

## Strategic structures, whole-game A/B (force, Legion vs Armada medium, 24 pairs): all off vs all on

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1157-force-g54-strategic-A (off) | 24 | 18 win, 5 timeout, 1 loss | 1 | 259.1k | 271 / 874 | 0.72 | 11.5 | 12 / 24 | 4.2k |
| 20261015-1157-force-g54-strategic-B (all on) | 24 | 10 win, 7 timeout, 7 loss | 1 | 221.8k | 251 / 691 | 0.78 | 14.1 | 11 / 22 | 3.4k |

- **Worse**: score -0.27 [-0.46, -0.08]; late enemy metal killed -30k [-54k, -5k]. Everything worked
  (Olympus finished in 11 games and fired in 16, Juno fired in 10, resurrection in 17) and was bought
  late (median minute: Juno 23, Olympus 28, Aegis 30, Soteria 36): ~15k metal and the T2
  constructors' time out of the late army. BARbarian medium showed a nuke silo in 3 games of 24, yet
  the anti-nuke and shield came on timers. Next: a reactive package (anti-nuke only on a seen silo,
  shield only on their cannons or air, no long-range cannons, Juno and resurrection on).

## Second factory from 18 metal/s at balanced autonomy, Cortex (sandboxes, 24 pairs, vs Armada medium)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1243-sbx-g56-cortex-secondlab-A (overflow only) | 24 | 1 win, 7 timeout, 16 loss | 2 | 209.8k | 135 / 1175 | 0.48 | 44.7 | 12 / 20.5 | 2.8k |
| 20261015-1243-sbx-g56-cortex-secondlab-B (from 18 metal/s) | 24 | 3 win, 9 timeout, 12 loss | 0 | 215.5k | 169 / 1057 | 0.56 | 28.0 | 12 / 17 | 3.5k |

- **Better**: score +0.10 [+0.00, +0.21]; army at 12 min +1.4k [+0.7k, +2.2k]; mid metal lost -9.4k
  [-14.7k, -3.7k]. Vehicle plant by minute 12 in 24 of 24 games (8 in A). On in the Cortex overlay;
  the Armada test (force-g56) decides the default.

## Second factory from 18 metal/s, Armada (force, 24 pairs, vs Cortex medium; Armada overlay in both)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1251-force-g56-armada-secondlab-A (overflow only) | 24 | 11 win, 7 timeout, 6 loss | 0 | 202.1k | 220 / 627 | 0.78 | 17.2 | 12 / 23.5 | 4.1k |
| 20261015-1251-force-g56-armada-secondlab-B (from 18 metal/s) | 24 | 10 win, 7 timeout, 7 loss | 0 | 169.3k | 227 / 503 | 0.87 | 10.1 | 13 / 16 | 5.3k |

- Score -0.02 [-0.27, +0.22], can't tell. Army at 12 min **better** +1.15k [+0.3k, +2.0k], opening
  kills and mid metal lost **better**, but extractors at 20 min **worse** -6.9 [-10.7, -2.9] and total
  metal 169k vs 202k: the two plants drain metal into the army (46 units by minute 25) and expansion
  starves (constructors alive at minute 20: 5.6 vs 11.2). Kept for Cortex only; for Armada (which
  already wins most of these) the trade is a wash. A second lab that leaves the economy its share is
  the follow-up.

## Strategic, reactive package (sandboxes, Legion vs Armada medium, 24 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1311-sbx-g58-strategic-reactive-A (off) | 24 | 10 win, 9 timeout, 5 loss | 2 | 230.3k | 219 / 903 | 0.72 | 20.5 | 11.5 / 18 | 3.6k |
| 20261015-1311-sbx-g58-strategic-reactive-B (anti-nuke/shield on a seen threat, Juno, resurrection) | 24 | 9 win, 6 timeout, 9 loss | 1 | 217.6k | 215 / 785 | 0.65 | 20.5 | 11 / 17 | 3.3k |

- Score -0.07 [-0.29, +0.16], can't tell; late enemy metal killed -28k [-62k, +6k] (leaning worse, as
  in g54). Juno built in 10 games, fired in 7; resurrection in 17; anti-nuke 1, shield 0. **Default:**
  the reactive anti-nuke and shield on (they only answer a seen silo / cannons / air); Juno,
  resurrection and long-range cannons off until one shows a gain alone.

## Second factory from 18 metal/s, Legion (sandboxes, 24 pairs, vs Armada medium)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1345-sbx-g59-legion-secondlab-A (overflow only) | 24 | 13 win, 7 timeout, 4 loss | 1 | 254.2k | 263 / 794 | 0.73 | 12.4 | 13.5 / 22 | 4.0k |
| 20261015-1345-sbx-g59-legion-secondlab-B (from 18 metal/s) | 24 | 4 win, 12 timeout, 8 loss | 0 | 223.3k | 230 / 801 | 0.71 | 16.4 | 12 / 17 | 4.2k |

- **Worse**: -0.27 [-0.47, -0.05], wins 13 -> 4; extractors at 20 min **worse** -6.4 [-9.2, -3.5],
  late enemy metal killed -39k. Same as Armada: the early plant starves expansion. Cortex only.

## Forward firebases, smoke test (sandboxes, Legion vs Armada **hard**, 8 games, firebases on)

- 8 losses (hard beat us in 24 of 24 recent games: g39, g41). Mechanics work: 2-4 firebases a game,
  layers built in order (light, radar, heavy, long-range; no anti-air: hard's air stayed under 10%),
  the first founded at minute 4-8 and usually holding most of the game, later ones overrun when hard
  pushes (minute 14-36). A/B started: sbx-g61-firebase-hard (24 pairs).

## Legion overlay, second round (force, 24 pairs) and pooled (48 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1343-force-g57-legion-overlay-A | 24 | 7 win, 8 timeout, 9 loss | 2 | 200.0k | 232 / 678 | 0.67 | 16.4 | 12 / 18 | 3.5k |
| 20261015-1343-force-g57-legion-overlay-B | 24 | 18 win, 3 timeout, 3 loss | 1 | 187.7k | 209 / 713 | 0.82 | 8.6 | 13 / 24.5 | 3.8k |
| pool-legov-A (no overlay) | 48 | 16 win, 18 timeout, 14 loss | 2 | 221.9k | 238 / 726 | 0.67 | 15.1 | 12 / 18 | 3.7k |
| pool-legov-B (overlay) | 48 | 30 win, 10 timeout, 8 loss | 2 | 206.1k | 229 / 841 | 0.80 | 10.4 | 12.5 / 21.5 | 3.9k |

- Force alone **better** +0.38 [+0.18, +0.56]. Pooled **better** +0.23 [+0.07, +0.39], wins 16 -> 30;
  late enemy metal killed **better** +20k [+4k, +37k]. **Shipped** (Mantis drone carriers, Cleavers,
  T2 vehicle plant from 50 metal/s with a construction vehicle).

## Forward firebases vs hard (sandboxes, Legion vs Armada hard, 24 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1430-sbx-g61-firebase-hard-A (off) | 24 | 24 loss | 3 | 71.6k | 65 / 445 | 0.51 | 25.4 | 11 / 20 | 3.4k |
| 20261015-1430-sbx-g61-firebase-hard-B (on) | 24 | 24 loss | 5 | 61.4k | 67 / 401 | 0.50 | 25.0 | 12 / 14 | 3.4k |

- Score +0.00 [-0.02, +0.02]: every game lost either way; mid trades 0.44 vs 0.33, extractors at 20
  min -2.2 (can't tell). Against hard the score is saturated. Re-testing against medium (g62).

## Forward firebases v1 vs medium (sandboxes, Legion vs Armada medium, 24 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1442-sbx-g62-firebase-medium-A (off) | 24 | 14 win, 4 timeout, 6 loss | 1 | 208.8k | 241 / 781 | 0.72 | 10.6 | 13 / 21 | 3.7k |
| 20261015-1442-sbx-g62-firebase-medium-B (on) | 24 | 13 win, 2 timeout, 9 loss | 1 | 175.2k | 227 / 780 | 0.77 | 14.7 | 11.5 / 18 | 3.5k |

- Score -0.05 [-0.32, +0.22], can't tell. Constructors lost 10.6 -> 14.7 (minutes 15-19: 71 vs 46;
  30-39: 100 vs 37), total metal -16%: Defense's constructors built firebases where the army wasn't.
  v2: only where the army covers the site (its squad within 1000 or further forward), none founded
  while the team defends.
- Harness bug found: the scripted player's "first lab never started" clock ran from frame 0, so at 60 s
  it re-ordered the lab elsewhere while the commander was still walking to it, in every test game
  (lab done ~1:30, first combat units ~2:30; at minute 3 we had 3 extractors and 74 army value against
  strong players' 4-6 and 250-500). Fixed in zz_sctest.lua: batches from here on open faster, so
  compare only arms run together.

## Construction turrets per lab 5 -> 8, Armada vs Cortex **hard** (force, 24 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1430-force-g60-armada-nanos8-hard-A (5) | 24 | 2 win, 22 loss | 1 | 140.3k | 161 / 749 | 0.58 | 31.4 | 13 / 19 | 3.8k |
| 20261015-1430-force-g60-armada-nanos8-hard-B (8, as BARbarian hard) | 24 | 1 win, 23 loss | 3 | 95.4k | 89 / 586 | 0.50 | 30.1 | 13 / 19 | 4.5k |

- Score -0.07 [-0.21, +0.05], can't tell; late enemy metal killed **worse** -17k [-29k, -6k]. Not
  kept (5). First wins against hard: Armada 3 of 48 (with the old, slow harness opening).

## The first lab in every test game: found and fixed (diagnostic runs sbx-labdiag1-5)

- Tracing the commander's commands: the player's lab order arrived, and 15 frames later our Economy's
  wind turbine order (sent before it had seen the player's) arrived and replaced it. The widget's guard
  for that race only recognised its own orders within 45 frames of sending; at test speed the network
  delay was longer, so our order passed for the player's and the lab was lost (re-ordered at 60 s by
  the harness's buggy clock, or after 20 s+ with it fixed). Widget fix: our build orders are recognised
  by what and where, however late, and one landing after a player's order puts theirs back. 4 of 4
  games then built the first lab on the first order, done at 1:00-1:07 (was ~1:30, ~2:10 at worst).
  Real games are exposed to the same race at lower latency.
- Batches from here on open ~30 s faster: compare only arms run together. g63 (firebases v2 vs medium,
  run with the half-fixed harness: lab at ~2:10) is not comparable to earlier baselines.

## Forward firebases v2 vs medium (sandboxes, 24 pairs; half-fixed harness, lab ~2:10)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1503-sbx-g63-firebase2-medium-A (off) | 24 | 9 win, 3 timeout, 12 loss | 0 | 147.9k | 167 / 657 | 0.70 | 19.6 | 9 / 14.5 | 3.1k |
| 20261015-1503-sbx-g63-firebase2-medium-B (v2) | 24 | 5 win, 9 timeout, 10 loss | 3 | 187.6k | 161 / 1099 | 0.73 | 19.5 | 9 / 18 | 3.0k |

- Score -0.08 [-0.31, +0.16], can't tell; mid metal lost **better** -3.3k [-6.5k, -0.3k]; constructors
  lost equal (v1 had +4). Late metal lost +79k with 9 games to the time limit. Re-run with the fixed
  opening: g65.

## Forward firebases off vs v2, Armada vs Cortex **hard** (force, 24 pairs; old harness opening)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1508-force-g64-armada-firebase2-hard-A (off) | 24 | 1 win, 23 loss | 3 | 133.8k | 124 / 725 | 0.51 | 31.3 | 12 / 20 | 3.8k |
| 20261015-1508-force-g64-armada-firebase2-hard-B (v2) | 24 | 2 timeout, 22 loss | 2 | 113.6k | 111 / 620 | 0.57 | 30.5 | 12 / 14.5 | 3.2k |

- Score -0.02 [-0.13, +0.06], can't tell; late metal lost **better** -67k; extractors at 20 min **worse**
  -5.6 [-10, -1.2]; army at 12 min **worse** -0.56k [-1.15k, -0.03k]. Firebase turrets come on top of
  the zone-front turrets (up to 1.5x the budget) and out of expansion and army. v3 (running) lets the
  economy expand under firebases; v4 candidate: firebases replace the front-line turrets instead of
  adding to them.

## Firebases v2 vs v3 (sandboxes, Legion vs Armada medium; 16 of 24 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1551-sbx-g66-firebase-v2-v3-A (v2) | 16 | 10 win, 1 timeout, 5 loss | 1 | 203.0k | 255 / 641 | 0.82 | 9.9 | 12.5 / 23 | 3.1k |
| 20261015-1551-sbx-g66-firebase-v2-v3-B (v3: metal sites, covered expansion) | 16 | 11 win, 1 timeout, 4 loss | 1 | 187.2k | 233 / 760 | 0.78 | 12.4 | 11.5 / 22.5 | 4.1k |

- 32 of 48 ran: sandboxes 4-7 became unreachable together ("connection refused" at one host address:
  a sandbox host went down), losing games 17-32 as whole pairs; the 16 pairs left are intact. Score
  +0.07 [-0.24, +0.38], can't tell; army at 12 min +775 [-35, +1.6k] (leaning better). v3 stays in the
  line (v4, v5 build on it).
- LLM review of v1's games (g62-B, 6 games, 11 s): the creep stalled after 1-3 sites in 6 of 6: the cap
  of 3 standing firebases. Fixed in v5 (one unfinished at a time, 8 standing).

## Firebases v3 vs v4 (force, Armada vs Cortex medium, 24 pairs) and v4 vs v5 (sandboxes, Legion vs Armada medium, 24 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1549-force-g67-armada-firebase-v3-v4-A (v3) | 24 | 16 win, 5 timeout, 3 loss | 1 | 203.8k | 238 / 540 | 0.83 | 12.1 | 12 / 20 | 3.9k |
| 20261015-1549-force-g67-armada-firebase-v3-v4-B (v4: replace the front line) | 24 | 12 win, 6 timeout, 6 loss | 0 | 166.0k | 206 / 501 | 0.76 | 14.8 | 12 / 20 | 4.0k |
| 20261015-1615-sbx-g69-firebase-v4-v5-A (v4) | 24 | 16 win, 1 timeout, 7 loss | 3 | 135.2k | 210 / 548 | 0.84 | 12.5 | 11.5 / 23 | 3.1k |
| 20261015-1615-sbx-g69-firebase-v4-v5-B (v5: 1 unfinished, 8 standing, army ratio) | 24 | 9 win, 8 timeout, 7 loss | 3 | 174.2k | 207 / 799 | 0.79 | 16.8 | 11 / 15 | 3.0k |

- v4: -0.12 [-0.28, +0.03], can't tell; late enemy metal killed **worse** -44k. v5: **worse** -0.19
  [-0.38, -0.00], mid kills and late losses worse. Feature table: firebases 2.5k spent, ~850 lost a
  game; kills 0 because kill attribution was broken (widgets aren't told an enemy unit's killer; now the
  widget credits its own operations).
- LLM review of both arms (24 games each, ~40 s): the creep stalls in 20+ of 24 (a site counts as done
  only with every layer, the last needing minute 8 and 30 metal/s; v5's one-unfinished cap let one stuck
  site freeze the line: why v5 lost); sites die to single raiders (the cover check took a squad anywhere
  further forward as cover). Its "1 standing = one unit of cover" reading was wrong (that's the count of
  firebases): checked against the code. -> v6.
- The new kill attribution also showed **our nukes killing our own units** (57 in g69: by=legsilo);
  fixed (nothing of ours worth over max(300, a tenth of the target) under 1.2x the blast).
- g66 completed with `batch.py --only 17-32 --into` (the 8 pairs the dead host lost): 24 pairs, v3
  +0.08 [-0.15, +0.30], can't tell (15 -> 17 wins, army at 12 min 3.1k -> 4.2k).

## Firebases v4 vs v6, the first sequential test (sandboxes, Legion vs Armada medium; scripts/seqtest.py)

| Challenger vs v4 | Pairs | Score difference | Verdict |
|---|---|---|---|
| v6 without the local-cover check (core established, heavy second, 2 unfinished, 6 standing, army ratio 0.75) | 8 | +0.54 [+0.17, +0.87] (99%) | **better**, stopped after round 1 |
| v6 with the local-cover check (500 metal of our combat units within 900) | 32 | -0.00 [-0.24, +0.23] (95%) | can't tell after 4 rounds |

- The local-cover requirement cancels v6's gains: **v6 ships without it** (coverValue = false).
  Batches 20261015-1658-seq-fb-v4-v6-b / -c, tracked as bar-seq-fb-v4-v6-b / -c.

## Strategic v1 vs v2 (force, Legion vs Armada medium, 24 pairs): cannons v2, nukes v1 (no friendly fire), Juno v2, resurrection

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1647-force-g70-strategic-v1-v2-A (off) | 24 | 17 win, 3 timeout, 4 loss | 0 | 160.5k | 233 / 569 | 0.88 | 11.2 | 12 / 20.5 | 3.6k |
| 20261015-1647-force-g70-strategic-v1-v2-B (on) | 24 | 16 win, 3 timeout, 5 loss | 0 | 166.8k | 242 / 713 | 0.90 | 14.3 | 11 / 17.5 | 3.6k |

Each feature on its own (arm B, per game it was used in):

| Feature | Games | Spent | Killed | Lost | Return |
|---|---|---|---|---|---|
| resurrection | 13-14 | bots 492 | raised **4.3k** metal | 262 | ~9x the bots |
| nuke | 6 | 7.6k | 5.2k | 1.5k | 0.69 |
| long-range cannon | 4 | 8.1k | 3.3k | **5.2k** | 0.41 |
| Juno | 18 | 926 | 333 | 206 | 0.36 |
| firebase | 23 | 3.0k | 4.9k | 1.5k | 1.62 (A, no strategic weapons: 0.52) |

- Score -0.04 [-0.26, +0.18], can't tell. Resurrection pays clearly; the cannons lose most of their
  cost (destroyed). Anti-nuke and shield never triggered (medium rarely builds nukes or cannons).

## Firebases v4 vs v6 against **hard** (force, Legion vs Armada hard, 24 pairs; both arms the same code)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1812-force-g71-firebase-v4-v6-hard-A (v4) | 24 | 24 loss | 2 | 65.3k | 92 / 427 | 0.49 | 26.3 | 12 / 11 | 3.7k |
| 20261015-1812-force-g71-firebase-v4-v6-hard-B (v6) | 24 | 24 loss | 7 | 68.9k | 72 / 445 | 0.51 | 24.8 | 12.5 / 15 | 3.8k |

- Score -0.01 (all lost: saturated). Firebases on their own: v6 return **2.01** (spent 850, killed 1.7k,
  lost 1.2k) vs v4 0.78. But mid metal lost **worse** +8.1k [+3.2k, +14.1k] and 7 games lost by minute 25
  (v4: 2): against a stronger army v6 over-extends. Extractors at 20 min +4.2 (leaning better).
- Strategic weapons against hard: long-range cannons destroyed with no kills (9.8-12.9k lost a game they
  were built), a nuke silo destroyed (9.1k), Juno nothing. Hard pushes into us: expensive structures in
  reach of the front die. Next: firebases v7 (creep scaled to how we stand), cannons placed by safety.

## Strategic v2 vs v3 (sequential, sandboxes, Legion vs Armada medium, 32 pairs)

- Score +0.11 [-0.07, +0.28] (95%), can't tell, leaning better. On their own (v3 arm): nukes return
  1.06 (v2 0.86, 13.7 kills a game they fire), resurrection raises 5.9k metal a game for ~600 of bots,
  firebases 1.24, Juno 0.58, cannons still built in only 9 of 32 games (return 0.13). The cannons' main
  blocker now: no tier 2 constructor ("no constructor here can build it" 99x in 22 games; partly noise,
  logged by tier 1 builders while a T2 one existed). Fixed: the T2 lab makes one more constructor when a
  strategic structure is due and nobody on the team can build it; the log says which case.

## Firebases v6 vs v7 against hard (force, Legion vs Armada hard, 24 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1850-force-g72-firebase-v6-v7-hard-A (v6) | 24 | 24 loss | 4 | 82.5k | 84 / 509 | 0.61 | 27.8 | 12.5 / 15 | 4.0k |
| 20261015-1850-force-g72-firebase-v6-v7-hard-B (v7: creep scaled to strength) | 24 | 1 timeout, 23 loss | 6 | 97.1k | 85 / 572 | 0.60 | 28.1 | 13 / 18.5 | 3.5k |

- Score +0.01, can't tell (saturated). Opening metal lost **better** -403 [-766, -19]; firebases spent
  more (1.6k vs 1.0k) at a lower return (0.67 vs 0.95). The strength gate rarely bites (their known army
  is often unknown or small early). Waiting for the medium seqtest (fb-v6-v7) before deciding.

## The player's-game fixes against hard (force, Cortex vs Armada hard, 24 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1922-force-g73-player-fixes-hard-A (before: b8a7b41) | 24 | 24 loss | 5 | 51.8k | 61 / 365 | 0.48 | 20.5 | 12 / 12 | 4.0k |
| 20261015-1922-force-g73-player-fixes-hard-B (factories, anti-nuke v2, march leash, anti-air behind, T2 constructor on demand) | 24 | 24 loss | 7 | 51.2k | 45 / 382 | 0.43 | 24.8 | 11 / 13 | 3.1k |

- Score -0.00 (saturated). Mobile anti-air lost **308 -> 185** (the anti-air fix works; "covering the army
  from behind" 360x, "waiting for the army" 93x). But army at 12 min **worse** -701 [-1.26k, -0.13k],
  mid kills leaning worse. Which part costs early army: the three-way seqtest (player-fixes: pre-fix /
  factory + anti-nuke / all) will separate the factory changes from the march and anti-air ones.

## The factory fixes and anti-nuke v2 alone against hard (force, Cortex vs Armada hard, 24 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1953-force-g74-factory-fix-hard-A (before) | 24 | 24 loss | 4 | 53.1k | 56 / 360 | 0.45 | 23.5 | 11.5 / 12 | 3.1k |
| 20261015-1953-force-g74-factory-fix-hard-B (reserve, queue ahead, non-blocking model, anti-nuke v2) | 24 | 24 loss | 5 | 47.2k | 47 / 346 | 0.47 | 22.5 | 11.5 / 15 | 3.7k |

- Army at 12 min +454 [-112, +1.1k] (leaning better): not the factory fixes that cost early army in
  g73. Score -0.03 [-0.05, -0.01] worse (all lost; B lasted slightly less), late kills -2.0k worse (the
  preemptive anti-nuke's 1500 metal in a losing game?). Noise against hard is large: the same "before"
  arm had 4.0k army at 12 min in g73 and 3.1k here. The three-way seqtest against medium decides.

## Firebases v6 vs v7 against medium (sequential, sandboxes, Legion vs Armada, 32 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-1924-seq-fb-v6-v7-b-A (v6) | 32 | 23 win, 5 timeout, 4 loss | 2 | 160.7k | 225 / 628 | 0.91 | 14.4 | 12.5 / 22 | 3.8k |
| 20261015-1924-seq-fb-v6-v7-b-B (v7) | 32 | 19 win, 3 timeout, 10 loss | 2 | 155.6k | 214 / 675 | 0.82 | 15.8 | 11 / 17 | 3.6k |

- v7 -0.13 [-0.31, +0.06], leaning worse; extractors at 20 min **worse** -4.0 [-7.9, -0.1]. With no gain
  against hard either, **v7's strength scaling is off** (firebases back to v6; the knobs stay).

## The player's-game fixes, Armada vs Cortex medium (force, 24 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-2024-force-g75-player-fixes-armada-A (before) | 24 | 11 win, 5 timeout, 8 loss | 1 | 124.9k | 170 / 512 | 0.89 | 20.2 | 11.5 / 14 | 4.4k |
| 20261015-2024-force-g75-player-fixes-armada-B (all fixes) | 24 | 17 win, 5 timeout, 2 loss | 0 | 194.5k | 243 / 465 | 0.84 | 12.5 | 13 / 21 | 4.5k |

- Score +0.21 [-0.01, +0.41] (just short of better); wins 11 -> 17, losses 8 -> 2; constructors lost
  20.2 -> 12.5; extractors at 20 min +4.4; metal 125k -> 194k. Mobile anti-air lost 389 -> 167 ("waiting
  for the army" 295x). Cannons with T2 constructors on demand: return 0.03 -> 0.33, lost 7.4k -> 2.0k.

## The player's-game fixes, Legion (force) and Cortex (three-way seqtest), medium

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-2108-force-g76-player-fixes-legion-A (before) | 24 | 14 win, 1 timeout, 9 loss | 0 | 137.9k | 201 / 532 | 0.83 | 14.7 | 13 / 19 | 3.3k |
| 20261015-2108-force-g76-player-fixes-legion-B (all fixes) | 24 | 16 win, 2 timeout, 6 loss | 2 | 181.0k | 239 / 744 | 0.82 | 17.5 | 11 / 17.5 | 3.3k |

- Legion: +0.07 [-0.18, +0.32], can't tell; late enemy metal killed **better** +39.6k [+13k, +66k];
  mobile anti-air lost 229 -> 137.
- Cortex, seqtest player-fixes (32 pairs each): factory fixes + anti-nuke v2 -0.06 [-0.24, +0.13],
  everything -0.03 [-0.23, +0.16]: can't tell.
- Across the factions (Armada +0.21, Legion +0.07, Cortex -0.03; against hard the early-army drop did
  not hold up as the factory fixes alone, g74): **kept**.

## Hardened expansions against hard (force, Cortex vs Armada hard, 24 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-2153-force-g77-harden-hard-A (off) | 24 | 24 loss | 4 | 43.9k | 64 / 330 | 0.48 | 22.3 | 12 / 10 | 3.5k |
| 20261015-2153-force-g77-harden-hard-B (raided spots get two turrets first) | 24 | 24 loss | 6 | 48.3k | 60 / 332 | 0.47 | 19.8 | 11.5 / 11 | 3.9k |

- Score 0.00 (all lost: saturated). Extractors lost in minutes 10-25 968 -> 783; "hardening a raided
  metal spot" 306x. Economy pace at minute 25: income 16.1 -> 30.5, extractors 5.5 -> 11, army 3.8k ->
  6.2k (the economy holds into the mid game). Opening kills -199 worse (noise far from where it acts).
  **Kept.** Against hard every game is still lost: the score needs a measure that isn't saturated
  (survival time, the economy at 25 min) to rank changes there.
- Correction with the new unsaturated verdicts: minutes survived 31.6 -> 31.2 (can't tell), metal
  income at 20 min +2.5 [-9.2, +13.6]. The minute-25 pace above is a median over the games still alive
  then (biased). Hardening cuts extractor losses but doesn't keep us alive longer against hard; kept for
  the losses it saves, not as a fix for hard.

## Why our army loses its fights against hard (LLM review of g77-B, checked against the logs)

- Our engagements against groups at 1-5x odds: in 32 of 124 the odds fell under 0.7x within a minute
  ("engaging ... 3.9x their strength" -> "holding: intruders is too strong here (0.5x)"): we commit on
  what we see, and hard's army is in the fog. Also pushes called off at peak strength ("the base needs
  us"), and the army keeps building while the economy collapses. The review's "129-1549x suicide charges"
  was a misreading (those are our odds against single intruders).
- Next: fog-aware odds (count their groups seen near the target lately, not just what's visible now),
  and no calling off a winning push unless our structures are falling.

## Fog-aware odds against hard (force, Legion vs Armada hard, 24 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-2227-force-g78-reinforce-hard-A (off) | 24 | 24 loss | 1 | 67.6k | 73 / 444 | 0.46 | 28.4 | 11.5 / 16.5 | 3.9k |
| 20261015-2227-force-g78-reinforce-hard-B (their forces within 1600 count 0.6) | 24 | 24 loss | 4 | 70.0k | 76 / 497 | 0.57 | 28.8 | 11 / 15 | 3.2k |

- Minutes survived 32.4 -> 31.9, income at 20 min 46.5 -> 46.9: no difference. Dealt/taken 0.46 -> 0.57,
  late enemy metal killed +9.9k [-1.9k, +30.5k] (leaning better). Neutral against hard; medium seqtest
  next (more caution may cost wins there).

## First Optuna study: firebase geometry (sandboxes, Legion vs Armada medium, 72 games, 3 generations)

- `scripts/tune.py --key fb-legion-medium --params firebase_step,firebase_spacing,firebase_reach,
  firebase_metal_weight` (TPE, one rule set per game). Generation means 0.82, 0.62, 0.75 (exploring).
- Top trials cluster around the defaults: step 480-625, spacing 960-1110, reach 0.49-0.54; the doctrine's
  own set (450 / 900 / 0.55 / 0.5) scored 1.093, in the top five. Importance: step 0.36, spacing 0.28,
  reach 0.21, metal weight 0.15. The creep's geometry isn't the bottleneck; a nudge (step 550, spacing
  1000, reach 0.52) is a candidate for a seqtest, not a change on this evidence.

## A higher bar for "the base is under attack" against hard (force, Legion vs Armada hard, 24 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-2301-force-g79-defendbase-hard-A (max(600, 8% of our army)) | 24 | 24 loss | 2 | 90.0k | 92 / 554 | 0.55 | 32.8 | 13 / 21 | 3.4k |
| 20261015-2301-force-g79-defendbase-hard-B (max(1000, 15%)) | 24 | 1 win, 23 loss | 2 | 76.9k | 89 / 463 | 0.55 | 31.0 | 12 / 14.5 | 4.1k |

- The first win against hard (1 of 24). Army at 12 min **better** +675 [+303, +1.1k], opening kills
  **better** +302; income at 20 min -8.5 and extractors -2.4 (can't tell: raids do more at home with
  the army away). Survival 34.2 -> 33.0. "Defend: the base is under attack" entries 1697 -> 1265. Mixed:
  a medium seqtest decides. Context (game 2, minute 17): the response squad and the economy's guards
  answered the raid; the plan flips push / defend about once a minute because entering defend for the
  base skips the hold; Defense's constructors sometimes stand "nothing to do" with threats in its zone.

## Defense answers intruders with a turret, against hard (force, Legion vs Armada hard, 24 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-2336-force-g80-defenseguard-hard-A (off) | 24 | 1 timeout, 23 loss | 2 | 89.3k | 76 / 507 | 0.62 | 30.0 | 12.5 / 15 | 3.6k |
| 20261015-2336-force-g80-defenseguard-hard-B (Jobs.guardTurret in Defense's plan) | 24 | 24 loss | 2 | 57.4k | 92 / 402 | 0.54 | 28.6 | 10.5 / 16 | 3.5k |

- Opening metal lost **worse** +750 [+423, +1.1k]; the rest can't tell; Defense "nothing to do" with
  threats 33 -> 49 (not fixed: the idling has another cause, likely the builders' safety or a spent
  turret budget). **Off** (doctrine.turrets.defenseGuard = false).

## Why rich games time out against medium (g75, g76, seq player-fixes)

- 2-5 timeouts per 24-32 games. Two kinds: barely alive (no factories, no army: the enemy can't finish
  us either) and rich but not finishing: e.g. 251 metal/s and a 115k army at minute 60 against medium,
  or 227 metal/s with metal storage full 1842 s. Attack and raid targets were only structures seen in the
  last 10 minutes: their base, unscouted that long late in a game, dropped out, and the army spent itself
  on extractors and raids at home. Finisher v1 (their factories stay targets until seen gone, their start
  as "their base" for the army's attack when none is known): testing (force-g81).
- The Cortex review (24 games) misread holds ("too strong here, 0.4x") as engagements and single-intruder
  odds (660-8141x) as charges again; its "never converts mass into a decisive push" checked out.

## Fog-aware odds against medium (sequential, sandboxes, Legion vs Armada, 32 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261015-2312-seq-reinforce-b-A (off) | 32 | 17 win, 6 timeout, 9 loss | 2 | 172.8k | 205 / 685 | 0.82 | 17.0 | 10.5 / 18 | 3.5k |
| 20261015-2312-seq-reinforce-b-B (on) | 32 | 19 win, 5 timeout, 8 loss | 0 | 201.2k | 240 / 810 | 0.87 | 19.8 | 11 / 18 | 3.8k |

- +0.07 [-0.13, +0.26], can't tell; army at 12 min **better** +599 [+151, +1.1k], mid metal lost
  -3.0k (leaning better). Neutral against hard (g78): **kept on**.

## Finisher v1 (force, Armada vs Cortex medium, 24 pairs)

| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |
|---|---|---|---|---|---|---|---|---|---|
| 20261016-0014-force-g81-finisher-armada-A (off) | 24 | 14 win, 5 timeout, 5 loss | 0 | 189.5k | 215 / 468 | 0.79 | 18.0 | 13 / 21 | 4.6k |
| 20261016-0014-force-g81-finisher-armada-B (factories remembered, their base as a target) | 24 | 16 win, 4 timeout, 4 loss | 0 | 171.7k | 228 / 464 | 0.92 | 17.6 | 12 / 19.5 | 4.1k |

- +0.09 [-0.07, +0.25], can't tell; mid enemy metal killed **better** +4.9k [+0.3k, +9.5k], late +31.5k
  (leaning better); "engaging enemy factory" 37 -> 189; timeouts 5 -> 4. **Kept on.**
