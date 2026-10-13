# Learning from strong players' replays

Status: pipeline working, 26 games logged; benchmark, playbook and strategist knowledge built from them; imitation models not trained yet.

## What BAR offers

- Every multiplayer game is recorded. The public replay API (`https://api.bar-rts.com/replays`) lists them
  with filters (`preset=duel`, `hasBots=false`, `endedNormally=true`), and `/replays/<id>` gives each
  player's rating (OpenSkill "skill"), faction, the winners, map, game version and engine version.
- The replay files are public on BAR's storage
  (`https://storage.uk.cloud.ovh.net/v1/AUTH_10286efc0d334efd917d476d7183232e/BAR/demos/<fileName>`).
- About a quarter of recent human duels have both players rated 28+ (68 of 300 sampled), and most of
  them run on the engine we have installed (2026.07.04), so they play back locally. The game version a
  replay needs is fetched with BAR's own pr-downloader from BAR's content network.

## Pipeline

1. `uv run --with certifi python testenv/pro_replays.py --pages 10 --min-skill 30 --max 25` scans recent
   duels, keeps those with both players at `--min-skill` or above, on our engine, longer than 8 minutes,
   downloads replay, map and game version, and writes `testenv/demos/pro/manifest.json`.
2. `testenv/replays.sh` plays each replay in the `replay` harness scenario (full view, speed 20; a
   25-minute game takes about four minutes) with the data logger (`zz_datalog.lua`, version 3) and keeps
   `testenv/data/pro/<id>.jsonl`.
3. `go run ./cmd/decidedata -in testenv/data/pro -out <sets>` builds training sets, as for the
   BARbarian data, plus the imitation tasks below.

The logger records, for both players:

| Record | What | Use |
|---|---|---|
| `fight` | groups in contact and the value each side lost in the next 25 s | fight model, more varied fights than BARbarian's |
| `unit`, `turret` | what each unit/turret dealt vs its cost | value models |
| `build` | a factory starting a combat unit: the options it had, the situation | imitation: production |
| `turretbuild` | a constructor starting a turret: options, situation, place | imitation: turret choice |
| `eco` | every minute: income, extractors, generators, factories, builders, army, turrets | benchmarks for the rules |

## Imitation tasks

`produce` and `turretpick` (internal/decider/tasks.go) ask one System One `choice` question: "which of
these would a strong player build next?", with the same situation text as the value tasks. The label is
what the player actually started. This avoids the unit value model's failure (it learnt that cheap units
"pay for themselves" and built 505 Satyrs): a player's choice already accounts for the plan, timing and
counters.

Caveats:

- Players choose with information we don't log (scouting, intent, the enemy's tech). Expect accuracy
  well below 100%; the useful measure is whether the model's top pick is among the player's choices for
  that situation, and whether games improve.
- Strong players micro their units; our executor doesn't. Compositions that rely on micro (raider
  harassment) may be worth less to us.
- Factions: Legion is rare in rated duels; Armada and Cortex dominate. Our sub-commanders mostly play
  Legion, so production imitation helps directly only when we play Armada/Cortex, unless candidates are
  described by traits (they are: kind, cost, range, speed, dps) and the model generalises.

## What 26 strong players' games show

25 rated duels (both players 30+, 8-29 minutes, mostly Cortex and Armada, 15 maps) plus the first test
replay. The full numbers are generated into [docs/research/pro-playbook.md](../docs/research/pro-playbook.md)
by `make benchmarks`; the economy quartiles are built into the binary
(`internal/analysis/benchmarks/pro-duel.json`) for `gamereport` and the strategist's Pace line.

- Economy: +20 metal/s and 9 extractors at 5 minutes, +35/s and 15 at 8, +47/s and 20 at 12; one
  factory until about minute 8-10, two by 12, three by 15; 5-8 constructors.
- Defence: every player had a turret by about minute 3 and ~5 by minute 6.
- Army: cheap raiders and light assault in numbers first, assault and heavies after minute 6; tech 2 is
  rare and late (median minute 19); air is 5-10% of the metal.

Against this, our rules-only games fall below the lower quartile of metal income from about minute 8 and
lag far behind on energy by minute 15 (batch 20261013-old-F).

## Next steps

1. Fetch 100-200 replays (one evening of playback), build `produce` / `turretpick` sets.
2. Train GBT baselines first (top-1 / top-3 accuracy against the player's choice), then Kev the same way
   as the other tasks (`deploy/decider/train_bar.sh`).
3. Retrain the fight model on BARbarian + pro fights.
4. Turn the economy curves into targets for the economy rules (extractors and factories by minute) and
   into strategist knowledge (`strategist/` skills).
5. A/B in fast games: rules vs rules + imitation production.
