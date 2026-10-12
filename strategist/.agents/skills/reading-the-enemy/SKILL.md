---
name: reading-the-enemy
description: How to read the enemy intel in reports (composition, new kinds, top types, intel structures, defences, sightings) and the BARbarian AI's habits.
---

# Reading the enemy

The report's `Enemy intel` holds:
- `composition`: `[kind, count]` of enemy units seen in the last 5 minutes (mobile units and turrets).
  Kinds: raider, assault, heavy, skirmisher, artillery, scout, mobile anti-air, fighter, bomber, gunship,
  scout plane, air transport, naval, hover ..., turret, anti-air turret, long-range artillery.
- `newKinds`: kinds first seen in the last 3 minutes - **the enemy's current direction**. A new kind is the
  strongest signal to adapt production, defence and posture.
- `topTypes`: the unit types seen most (display names).
- `tech2Units`: T2 units seen - they have teched up; T1 turrets start to fall behind.
- `intelStructures`: their radar, jammers, cameras we know of (targets for an Intelligence sub-commander).
- `defenses` / `defenseCount`: their turrets we know of - don't send raiders into them.
- `recentSightings`: where enemies were seen (clusters, seconds ago) - the direction attacks come from.
- `startPositions`: enemy start; `guess: true` means it's our mirrored position, not confirmed.

## Patterns

- Many raiders early = they will hit extractors and expansions: cheap turrets at outlying extractors, army
  near the economy.
- Skirmishers / artillery growing = they'll siege lines: turrets alone won't hold, the army must engage.
- First bombers/gunships = air is coming in numbers: anti-air now, before the second wave.
- T2 units = time for T2 on our side too, or the gap grows.
- Nothing seen for minutes = we're blind, not safe: scout (Intelligence) and radar.

## BARbarian AI (the usual test opponent)

- Expands fast and raids extractors with small groups early; then attacks with mixed ground armies along
  the shortest path to our base.
- It replaces losses quickly, so trading evenly isn't winning: win fights decisively (defend at our turrets,
  then counter-push while its army is down).
- Hard profile reaches T2 and air sooner; watch `newKinds` for air and T2 from ~8 minutes on.
