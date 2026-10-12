---
name: army
description: Playbook for an Army sub-commander in Beyond All Reason - production mix against the enemy composition, when to hold, when to push, and how to use zones to move the army.
---

# Army playbook

Your factory produces combat units (a mix weighted to the strongest affordable, or exactly the types in
your `focus`). Units fight intruders in your zone, help the other sub-commanders' zones when raids hit them
(only if not badly outnumbered), and patrol otherwise. **The zone is where the army goes**: moving the zone is
how you attack, retreat or hold a position.

## Production: counter what they field

Use `get_build_options` (`by: factory`) and `set_focus` to pick 2-4 unit types. Rules of thumb:

| Enemy fields | Answer |
|---|---|
| raiders / scouts | riot units (short range, high damage, area weapons) and a few raiders of our own |
| assault / heavy | massed cheaper damage dealers, skirmishers that outrange them, or artillery behind a line |
| skirmishers | fast units that close the distance (raiders), or artillery |
| artillery | fast raiders or air to dive it; it is weak up close |
| air | mobile anti-air with the army (a share, not all) |
| static defence lines | artillery / long range units; don't run raiders into turrets |

Keep a mix: pure raiders die to riot units and turrets, pure heavies get outranged and kited.

## Hold or push

- **Hold** (zone on our side, near our turrets and extractors) while we are weaker or still building up.
  An army that trickles across the map one unit at a time loses everything for nothing.
- **Push** when we are clearly stronger *here and now*: our army value well above the enemy units seen near
  the target, ideally right after we beat their attack. Move the zone forward in steps (one zone width at a
  time) onto a target: their expansions (extractors), their radar, then their front. Don't jump the zone onto
  the enemy start at once.
- **Retreat** (move the zone back) after heavy losses, or when `newKinds` shows a counter to our units.
- Raid exposed enemy extractors with a few fast units when the main army holds (needs a separate small zone
  far from the main fight; zones are additive, units go to the nearest).

## Posture

- `spend` when metal piles up (storage > 70%) - units are how metal turns into map control.
- `balanced` normally; `conserve` only when the economy is stalling and no attack is coming.

## Tell the player when

- you have no factory (you can't produce),
- the enemy has air and you have no anti-air option,
- a push opportunity exists (you're much stronger) - suggest it in your sentence and act on it if your
  orders allow attacking.
