---
name: air
description: Playbook for the Air Force sub-commander in Beyond All Reason - air defence and air attack in one: anti-air turrets and mobile anti-air, fighters, gunships, bombers, scouting, covering areas and allies, avoiding or clearing anti-air.
---

# Air Force playbook

The Air Force does both air defence and air attack (the old Air Defense role is part of it).

**What the rules do on their own**
- Constructors: anti-air turrets first while their aircraft are in your areas, then the aircraft plant
  (tier 2 from 70 metal/s), anti-air turrets once their air is 10%+ of what they field (next to the most
  valuable buildings with the least anti-air), then radar for the planes to see by.
- Factories: an aircraft plant makes the wings' mix (fighters up with their air, bombers and gunships for
  the strike); a ground factory you're given makes mobile anti-air.
- Three wings (`airForce` in your report): **fighters** intercept their aircraft over the base, the army
  and any area you cover (covered areas first), else escort a strike, else patrol your first cover area
  (or between base and army); **gunships** hunt raiding parties near the base or in your cover areas when
  their anti-air is weak, else join the strike; **strike** (bombers plus idle gunships) hits their
  extractors, generators, constructors and factories on routes around anti-air, and takes out anti-air it
  can destroy outright. Planes below 45% health fly home to repair.
- Other sub-commanders post a `cover` request when their aircraft fly over them: you cover that spot.

**Covering areas and allies (the player's orders)**
- "Cover X" / "keep air off Y": `cover_area` (x, z, radius) on yourself; `clear_zones` returns to automatic.
- "Defend the ally" / "help our ally": `cover_ally` (their bases are in `Our allies' bases` of your report).
- Another sub-commander needing air cover: `request_help` kind `cover` (x, z) reaches you.

**Judgement**
- **Build anti-air to the threat.** No enemy air seen: a token turret near factories and energy is enough.
  Bombers fly straight at factories, energy and the commander: anti-air on the path and at the target.
  Gunships hover and fight: sustained anti-air (several turrets, mobile anti-air, fighters). Scout planes
  alone don't justify it.
- **Air is won by numbers.** Small wings die to a single anti-air turret. Let the strike wing gather (800
  metal); `spend` posture when metal piles up and their anti-air is thin.
- **Their anti-air decides where you strike.** Lots of it (mobile anti-air with their army, flak): their
  outlying extractors and constructors, not the base. They field fighters: more of ours (`set_focus`
  fighter types from `get_build_options`).
- **Gunships are the best answer to raids** that walk around the army: keep them home while raids hit the
  base (`set_focus` gunships, or cover the raided area).
- **Bombers** kill buildings and slow units; they're wasted on fast raiders.
- Tier 2 air (stronger bombers, gunships) carries strikes into defended areas.
