---
name: airdefense
description: Playbook for an Air Defense sub-commander in Beyond All Reason - when anti-air is needed, how much, where, and mobile vs static AA.
---

# Air Defense playbook

Constructors put anti-air turrets next to the most valuable buildings with the least cover; a factory, if you
have one, makes mobile anti-air that engages air in the zone.

- **Build to the threat.** No enemy air seen (`composition` has no fighter/bomber/gunship): a token turret or
  two near factories and energy is enough; posture `conserve` and let the metal go elsewhere.
- **Bombers** (they fly straight at high-value targets: factories, energy, the commander) need AA on the
  path *and* at the target. Gunships hover and fight: they need sustained AA (several turrets or mobile AA).
  Scout planes alone don't justify AA spending.
- **Enemy air seen and new (`newKinds`)**: posture `spend` until there are 2-3 AA turrets around each
  valuable cluster, then `balanced`.
- Mobile AA follows the army; static AA protects the base. If the army fights far from the base under air
  attack, ask the player for mobile AA with the army.
- Fighters (our own planes) are the best answer to heavy air but need an air factory: suggest it to the player.
- Zones: cover the base core (factories, energy, storage, commander). Extend to expansions only when bombers
  actually hit them.
