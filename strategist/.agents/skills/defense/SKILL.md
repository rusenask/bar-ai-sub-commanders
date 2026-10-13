---
name: defense
description: Playbook for a Defense sub-commander in Beyond All Reason - choosing turret types against what the enemy fields, placement, radar, and when static defence is the wrong answer.
---

# Defense playbook

Your constructors build a radar, then turrets on the zone edge that faces the enemy, repair, and help builds.
Combat units (from a factory if you have one) guard the zone. You steer zones (where the line is), posture
(how much), and focus (which turret types: `set_focus` with structure names from `get_build_options`,
`by: constructors`, kind `defense turret` or `anti-air turret`).

## Read what the enemy fields first

The report's enemy intel has `composition` (kinds seen in the last 5 minutes), `newKinds` (first seen in the
last 3 minutes - what they are switching to) and `topTypes`. Answer that, not last game's threat:

| Enemy fields | Build |
|---|---|
| raiders, scouts (fast, light) | cheap fast-firing turrets (light lasers / machine guns), several of them, covering extractors and lanes |
| assault / heavy units | high-damage turrets (heavy lasers, plasma), fewer but stronger, behind cheaper ones |
| skirmishers (range 500+) | turrets with at least their range, or they pick turrets apart; mobile units do better |
| artillery (high arc, long range) | static defence loses to artillery - ask Army to hunt it, or the player for air; spread out instead of stacking |
| bombers / gunships | anti-air turrets near the valuable buildings (or ask Air Defense); bombers come in a straight line from their base |
| naval / hover | turrets that reach water (torpedo or long-range); hovers cross water fast |

Name the turret types you want with `set_focus` when the default mix is wrong for the enemy
(e.g. enemy masses raiders: focus the cheap fast-firing turret). Clear it when the enemy changes.

## Lessons from test games

- Early raiders kill lone constructors and unfinished turrets: keep the zone tight around what you
  protect until a few turrets stand, then extend it.
- A line of one turret type gets countered: mix cheap fast-firing turrets with a few high-damage ones once
  heavier units appear (`newKinds`).
- The line holds far better when the Army fights next to it: if the army keeps fighting in the open in
  front of your turrets, tell the player.

## What strong players do (26 rated 1v1 replays)

- **Every** strong player had a turret up by about minute 3, about 5 by minute 6 and 15 by minute 12
  (turret value around 700 metal at 8 minutes, 1.7k at 12). Early turrets are cheap light lasers at
  extractors and approaches; heavier ones (Exploiter, Twin Guard, Beamer-class) come after minute 6.
- Anti-air comes late and only when air shows up: a third of them had any by minute 9. Don't spend on
  anti-air before the enemy has aircraft.

## Placement

- The line belongs where the enemy comes from: between the enemy and what you protect, at chokepoints
  (look at the map picture: cliffs funnel units). Move the zone with `clear_zones` + `add_zone` when the
  enemy's direction changes.
- Turrets in range of each other so they can't be picked off one by one; not so far forward that they're
  isolated; radar coverage over the line (it builds one).
- Don't wall in our own units: the executor keeps lanes and factory exits clear, don't put zones over
  factory exits.

## Posture

- `spend` when enemies keep entering the zone or `newKinds` shows something your turrets don't counter yet,
  and metal allows.
- `balanced` normally; `conserve` only for a long-quiet line whose turrets already cover every approach
  (low metal storage alone is not a reason).
- Static defence doesn't win games: once a line holds, extra turrets are wasted metal. Say so and let the
  metal go to the army or economy.

## Ask the player when

- you have one constructor and the line is under pressure (need more builders),
- artillery or long-range units outrange the line (needs army or air),
- you see bombers and nobody does air defence.
