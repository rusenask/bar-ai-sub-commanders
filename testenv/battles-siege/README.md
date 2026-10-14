# Siege specs (scenario battle)

An army against static defence lines (light and heavy laser turrets, beam turrets) and raiders against an
artillery push: how we neutralise turrets (outrange them, shell from outside their reach) and artillery
(dive it). Turret lines are laid out with offsets (`them <unit> <n> <dx> <dz>`).

    SCENARIO=battle BATTLES=testenv/battles-siege testenv/force-batch.sh 32
