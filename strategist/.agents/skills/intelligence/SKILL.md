---
name: intelligence
description: Playbook for an Intelligence sub-commander in Beyond All Reason - radar coverage, cameras, jammers, sonar, scouting and hunting enemy radar and jammers.
---

# Intelligence playbook

What your units already do:
- **Constructors**: a radar network that covers each zone's centre and its edge toward the enemy, on the
  highest ground available; cheap cloaked cameras at the front edge; a jammer over the most valuable cluster
  (factories, big structures) once energy income allows; sonar where a zone has water.
- **Factory** (if the player gives you one): a few scouts (cheap, fast, long sight), one mobile radar or
  jammer when available, then fast raiders.
- **Scouts** cycle through the enemy start and the metal spots we haven't seen lately. They move, they don't
  fight.
- **Raiders** hunt known enemy radar, jammers and cameras (`intelStructures` in the enemy intel) that no
  known enemy turret covers, then guard the zone.

## What you steer

- **Zones decide what gets watched.** Put a zone over the approaches the enemy uses (between their start
  and our base, chokepoints on the map picture, our expansions). The radar net covers each zone's edge
  toward the enemy, so a zone a bit forward of the base gives early warning.
- **Posture**: `spend` early (radar is cheap and information is worth a lot) and when the enemy keeps
  surprising us; `balanced` once the approaches are covered; jammers are expensive in energy - conserve if
  energy is short.
- **Focus** (`set_focus`) on scout types if you want more eyes, or on a specific raider for hunting.

## Why it matters (say it to the player when relevant)

- Radar shows units coming long before turrets see them; long-range turrets and artillery can fire at radar
  dots.
- A jammer hides our base from enemy radar, so their artillery and bombers have to scout first.
- Killing enemy radar blinds their artillery; fresh enemy cameras near our base mean they're watching.
- Track `newKinds`: the enemy switching to air, artillery or T2 is the most important thing you can report.
  When you see it, tell the player (once) what's coming and from where.

## Juno

A Juno (T1, ~650 metal, any constructor) fires a stockpiled missile anywhere on the map whose blast (700
radius) destroys radar, jammers, cameras and mines without hurting units. When the doctrine turns it on,
your constructors build one once two of their intel structures are known, and it fires at their densest
cluster: their artillery and bombers go blind, their hidden army shows up on our radar. Say so to the
player when their jammers hide an army.


## Eyes for the cannons and bombers, and counter-intelligence (since 2026-10-16)

- **Spotters**: cloaking spies (Ghost / Spectre / Eidolon, from the tier 2 bot lab, which makes them for you)
  and, where none can be made, scouts hold watch near what the team is hitting: the long-range cannons'
  and the bombers' targets, the army's target, their factories (their start if none is known). They
  cloak, stand back ~400 from the target, and lost ones are replaced (2 + 1 per 50 metal/s, up to 5).
  Without eyes the cannons and strikes have nothing to aim at.
- **Counter-intelligence**: your armed units hunt their scouts, spies and cameras in our areas first,
  then their radar and jammers; a seismic detector at home from minute 8 reveals cloaked units moving;
  the mobile jammer follows the army to hide it.
