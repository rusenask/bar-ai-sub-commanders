---
name: economy
description: Playbook for an Economy sub-commander in Beyond All Reason - metal and energy balance, expansion, converters, storage, build power, when to tech up, and what to steer with posture, zones and focus.
---

# Economy playbook

Your constructors already do the building: metal extractors on free spots (also safe spots just outside your
zones), energy when short, storage when full, converters on surplus energy, helping builds, reclaiming wreckage.
Your job is to steer *where* (zones) and *how hard* (posture), and to ask the player for what rules can't do.

## The numbers that matter

- **Metal is the limit in almost every game.** Metal income comes from extractors (1-3 metal/s each on most
  maps), reclaim and converters. Count `freeMetalSpots` in your zones and in the map picture: free spots
  on our side of the map are the cheapest growth there is.
- **Energy should run ahead of metal, not far ahead.** Early T1: roughly 10-20 energy income per 1 metal
  income. Energy storage near empty while metal piles up = energy short. Energy income above ~25x metal
  income with full energy storage = too much energy: the surplus should go into converters, not more
  generators.
- **Wind vs solar**: wind turbines pay off when the map's average wind is above ~7 (the report gives the
  wind range). Below that, solar.
- **Converters** turn surplus energy into metal at a poor rate (T1 about 70 energy -> 1 metal). They are the
  right use of energy that would overflow, never a reason to build energy. They switch off by themselves
  when energy runs low.
- **Storage**: only when resources overflow. Metal at the cap means income is wasted: spend it (posture
  `spend`, more factories/army, or tell the player).
- **Build power**: about 2 constructors (or 1 construction turret) per 100 energy/s and per 5 metal/s of
  income keeps resources spent. Unused metal piling up with nothing to do = too little build power or no
  factories to spend it in; tell the player.
- **Pull** is what everything is trying to spend per second. Pull well above income drains storage: when
  metal or energy storage is falling and pull > income, the team is overspending (conserve, or more income).

## Pace of strong players (26 rated 1v1 replays)

Reports carry a **Pace** line: our metal and energy income against strong players' at the same minute
(their middle half). Medians from their games:

| Minute | Metal income | Extractors | Factories | Constructors | Energy income |
|---|---|---|---|---|---|
| 5 | +20/s | 9 | 1 | 5 | ~215 |
| 8 | +35/s | 15 | 1-2 | 5 | ~360 |
| 12 | +47/s | 20 | 2 | 7 | ~720 |
| 15 | +58/s | 27 | 3 | 8 | ~900 |

- Below their lower band at 8 minutes almost always means too few extractors: expand (zones over free
  spots on our half) and ask for constructors before anything else.
- They stay on **one factory until about minute 8-10** and add the second around minute 10-12: factories
  follow income, not the other way round.
- Energy grows steeply after minute 10 (fusion, converters): when metal income is at pace but energy is far
  below it, energy is what holds the next step back.
- Maps differ; treat the numbers as a guide, not a target to hit at any cost.

## The first minutes (lessons from test games)

- **The commander is the game**: in the default mode its death loses everything (in one test game a 64-unit
  team died with it). The executor only uses it inside your zones and pulls it back from enemies; keep the
  economy zone that holds it at home, and expand with other constructors.
- Enemy raiders usually reach our extractors around 3 minutes. The executor keeps a small guard from the
  factory and puts a cheap turret by raided extractors; on `conserve` the guard is a single unit, so don't
  conserve early.
- An energy stall (energy at zero) slows *everything*, including the player's builds: when energy hits zero,
  the executor builds cheap generators first. If it keeps happening, ask for more constructors.
- Your factory also replaces lost constructors for Defense, Air Defense and Intelligence sub-commanders.

## Expansion

- Extend or add zones over clusters of free metal spots on our half of the map (look at the map picture:
  yellow rings). Keep each zone 600-2500 elmos across.
- Don't expand toward the enemy start or where red sightings are fresh: raiders kill lone extractors.
  Expansions near the front need a Defense or Army zone next to them - ask the player or say so.
- Lost extractors get rebuilt automatically; if the same spots keep dying, give them up (clear that zone)
  and tell the player they need defending.

## Tech 2

- T2 (advanced extractors give ~4x metal, fusion, T2 units) costs roughly 4000 metal in total. It is worth it
  when the T1 spots are taken, income is stable (around +20 metal and +500 energy) and the front is quiet.
- The rule engine upgrades extractors when it has T2 constructors; getting a T2 lab is the player's call -
  suggest it with tell_player when the conditions hold.

## Posture

- `spend` when metal or energy storage is above ~80% and rising, or the player asked for a fast build-up.
- `balanced` normally.
- `conserve` only when the team is stalling on metal and your building isn't what fixes it (you usually *are*
  the fix: an economy sub-commander rarely needs to conserve).

## Ask the player (tell_player) when

- metal overflows and there's nothing to spend it on (needs a factory or more roles),
- you need more constructors (fewer than ~3 while many free spots remain),
- expansions keep dying (needs defence),
- T2 conditions hold.
