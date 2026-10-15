---
name: unit-abilities
description: What units in Beyond All Reason can do beyond shooting, per faction (Armada, Cortex, Legion) - cloaking, stealth, EMP, shields, anti-nukes, nukes, resurrection, capture, mines, decoys, Juno, drones, cluster and flame weapons, amphibious units, transports - and which of these our sub-commanders already use. Use when choosing focus units, reading what the enemy fields, or answering the player about a unit.
---

# Unit abilities

The full catalogue (every unit, its cost, health, range and abilities, from the game's own data) is
`docs/research/units.md` in the repo. The essentials:

## Our faction's strengths (the doctrine plays these)

- **Armada: the clandestine faction.** Gremlin (armgremlin, T2 bots, 230 metal, cloaks) and Sharpshooter
  (armsnipe, cloaking sniper, range 900) stay cloaked; Gremlins raid economy. Lightning weapons (Jaguar,
  Welder, Thor) and EMP (Webber spider, Stiletto stealth bomber, Paralyzer missile) stop units without
  killing them. Stealthy long-range rockets: Ambassador (armmerl).
- **Cortex: the heavy-armour faction.** The Tzar (corgol, T2 vehicles, 1650 metal, 7800 health, range 650)
  is its decisive unit; later Karganeth, Shiva, Juggernaut, Behemoth. Flamethrowers (Fiend, Demon,
  Dragon's Maw) melt clumped units. Shuriken (corbw) gunships carry EMP.
- **Legion: the swarm and siege faction.** Drone carriers (Hive, Mantis, Hecatoncheir, Rampart), cluster
  artillery (Cleaver, Amputator, Eviscerator, Olympus), strong skirmishers (Barrage, legbar).

## Every faction has (and we don't use yet)

- **Anti-nuke** (Citadel, Prevailer, Aegis; mobile: Umbrella, Saviour, Hera): one covers a base from nukes
  (Armageddon, Apocalypse, Supernova). Ask for one when the enemy builds a nuke silo.
- **Shields** (Keeper, Overseer, Soteria; 3000+ metal): absorb artillery and missiles over an area.
- **Juno** (armjuno, corjuno, legjuno; Legion's Blindfold): a missile that clears mines, radar and jammers
  in an area without hurting units.
- **Resurrection** (Lazarus, Graverobber, Zagreus): rebuilds wrecks as units for a fraction of their cost.
- **Capture** (commanders): takes enemy units over.
- **Mines** (light / medium / heavy; minesweepers: the mine-laying constructors) and **decoys** (Decoy
  Fusion, Dragon's Claw/Maw/Jaw).
- **Amphibious** units (Crossbow, Duck, Salamander, Telchine...) cross water; **transports** (Stork,
  Hercules, Aeolus) move units over cliffs and water.

## What our sub-commanders already use

Radar, jammers, sonar and seismic detectors (Intelligence), the commander's D-gun, energy converters and
geothermal (Economy), and since 2026-10-15 cloaking (Armada) and the Tzar as Cortex's heavy (the faction
doctrine overlays). On by default (`doctrine.strategic`): an anti-nuke with stockpiled interceptors once
their nuke silo is seen, and a shield over the labs once their long-range cannons or a real air force
are seen. Built and working but off, because they cost more than they won in tests: long-range plasma
cannons with fire control, a Juno silo fired on their radar/jammer clusters, resurrection bots. Suggest
them only for a reason the player sees (their jammers hiding an army: Juno; a stalemate at long range:
cannons). The rest needs a player's order or a focus (`set_focus`) for now; say so when it
would help (an enemy nuke silo: an anti-nuke; mines on their raid paths; resurrection after a big fight).
