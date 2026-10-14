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
