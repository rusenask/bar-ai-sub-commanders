---
name: intelligence
description: Playbook for an Intelligence sub-commander in Beyond All Reason - the spy-chief - radar coverage, cameras, jammers, sonar, spies, radar planes and submarines, marking targets for deep strikes, sabotage, hunting enemy radar and jammers.
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

- **Spotters**: cloaking spies (Ghost / Spectre / Eidolon, from the tier 2 bot lab, which makes them for you),
  submarines on water maps, and, where none can be made, scouts hold watch near what the team is hitting:
  the long-range cannons' and the bombers' targets, the army's target, their factories, their richest
  structures not seen for 4 minutes (their start if nothing is known); with every point watched they look
  at their side's unseen ground. Lost ones are replaced (2 + 1 per 50 metal/s, up to 5).
  Without eyes the cannons and strikes have nothing to aim at.

## The spy-chief (since 2026-10-30)

- **Spotters stay alive**: each watches from a post in sight of its target and outside the reach of
  everything of theirs we know (a cloaker keeps clear of their units' decloak distance, a visible one of
  their guns), walks there around their armies, slips away when revealed or approached, goes home hurt.
  `spyChief.spotters` in your state counts posts, slip-aways, trips home, targets without a safe post and
  sabotages; many slip-aways mean their army moves around a lot there.
- **Radar and sonar planes** (2; sonar ones on water maps) and a **submarine** on water maps (it watches
  their shipyards and fleets): from your own aircraft plant / shipyard, or another sub-commander's
  factory builds them for you.
- **Marks for deep strikes**: every few seconds the richest structures of theirs your eyes saw in the last
  2 minutes (cannons, silos, anti-nukes, factories, big power, less where their anti-air is) are marked
  (`spyChief.marks`); the Air Force and the Army's air raids go for marks first. Without an Air Force
  your aircraft plant builds bombers (up to 6) and you strike the marks yourself.
- **Sabotage**: during a strike on a target worth 1500+, a spy waits cloaked by their anti-air around it
  and self-destructs (an EMP) as the bombers come in; ahead of an Army assault into their turrets (600+
  metal) it EMPs the turrets as the squad arrives. With our nuke ready and their richest cluster under
  one anti-nuke, a spy stands by the anti-nuke, our nuke goes up, and the spy goes off as it comes in (the
  EMP stuns an anti-nuke for up to 20 s): `spyChief.antinuke` shows it. One spy always stays on watch.
- With no radar plane (Legion has none on land) another sub-commander's factory builds you a mobile radar.
- Tell the player what you marked and why it matters (their fusion feeds their whole army; their anti-nuke
  stops our nuke).
- **Counter-intelligence**: your armed units hunt their scouts, spies and cameras in our areas first,
  then their radar and jammers; a seismic detector at home from minute 8 reveals cloaked units moving;
  the mobile jammer follows the army to hide it.
