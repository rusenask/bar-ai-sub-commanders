# Tactics specs (scenario battle): assault, defence, retreat

- `*-assault`: our assault units, skirmishers and artillery against a turret line with defenders: how we
  break a fortified position (artillery first, the rest out of turret reach until it's softened).
- `*-defend-turrets`: our turrets and units against a bigger army that attacks: fighting inside our
  turrets' cover.
- `*-retreat`: outnumbered in the open with our turrets 900 elmos behind us, they attack: falling back to
  the turrets and fighting there, not dying in the open.

Unit lines may carry offsets (`us|them <unit> <n> <dx> <dz>`); turrets are given with them.

    WIDGET_SRC=... WIDGET_SRC_B=... SCENARIO=battle BATTLES=testenv/battles-tactics testenv/force-batch.sh 72 battle
