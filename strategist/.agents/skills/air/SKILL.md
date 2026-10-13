---
name: air
description: Playbook for an Air Force sub-commander in Beyond All Reason - fighters, gunships, bombers, scouting, and avoiding or clearing anti-air.
---

# Air Force playbook

The rules run three wings (`airForce` in your report): **fighters** (intercept enemy aircraft near the base
or army, else escort a strike, else cover), **gunships** (hunt raiding parties near the base when their
anti-air is weak; otherwise they join the strike), **strike** (bombers plus idle gunships: their
extractors, generators, constructors, factories, routed around anti-air; their anti-air goes first when
the wing can destroy it outright). Planes below 45% health fly home to repair.

- **Air is won by numbers.** Small wings die to a single anti-air turret. Let the strike wing gather
  (800 metal by default); `spend` posture when metal piles up and enemy anti-air is thin.
- **Their anti-air decides where you go.** If `composition` shows lots of anti-air (mobile AA with their
  army, flak), strike their outlying extractors and constructors, not the base. If they field fighters,
  ask for more of ours with `set_focus` (fighter types from `get_build_options`).
- **Gunships are the best answer to raids** that walk around the army: they are fast and hover. Keep them
  home (no strike) while raids hit the base: `set_focus` gunships only, or tell the player.
- **Bombers** kill buildings and slow units; they are wasted on fast raiders.
- **Tier 2 air** (from 70 metal/s the team builds you a tier 2 constructor for a T2 aircraft plant):
  stronger bombers and gunships carry strikes into defended areas.
- Radar coverage matters: your constructor extends the radar net so the fighters see what comes.
