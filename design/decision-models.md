# Design: our own decision models (combat, production, defense)

Status: done (v2 models serving on `force`, optional and off by default). Results and conclusions below.

## Goal

Train small, fast "System One" decision models for the choices the sub-commanders make every few seconds,
from what actually happens in Beyond All Reason games, and use them in place of hand-written rules where
they measurably do better:

| Model | Decision it informs | Asked by |
|---|---|---|
| **combat** | engage this enemy group, or hold / fall back? | Army (and any combat units) when a fight is possible |
| **production** | which unit should this factory build next? | Army / Air Defense factories |
| **defense** | which turret type should go on this line? | Defense constructors |

Each answers in tens of milliseconds (no text generation), runs on the `force` GPU host, and is optional:
without it the widget's rules decide, as today.

## Why train our own

The off-the-shelf decision models (Kev, Clef; see the README benchmark) only know what the option
descriptions say, and in game A/B tests they didn't change results. They have no idea how BAR fights
actually go. A model trained on BAR outcomes can know that, for example, five skirmishers on high ground
beat eight raiders, or that a light laser turret pays for itself against raiders but not against artillery.

## Approach

Kev's recipe ([jaredpalmer/kev](https://github.com/jaredpalmer/kev)): a Qwen3.5 base with a rank-16 LoRA
adapter and a pointer head that scores answer options, trained with cross-entropy on JSONL records shaped
like API requests plus labels. We fine-tune from the released **Kev-0.8B** (`--init_from
jaredpalmer/kev-0.8b`), so each model keeps Kev's general decision skill and adds BAR. 0.8B keeps serving
fast and lets three models share the 24 GB card on `force`.

### Labels from outcomes, not opinions

Labels come from what happened in the game, never from an LLM's opinion:

- **combat**: at a fight (two armed groups within reach of each other), snapshot both sides; 25 game seconds
  later, compare the metal value each side lost among the units that were there. Label: *we came out ahead*
  (enemy lost more value than we did), plus a 5-level score of how decisive it was.
- **production**: when a unit is built, snapshot what its team faces and fields; follow the unit until it
  dies (or 8 minutes, or the game ends) and add up the damage it dealt, valued at the victims' metal cost
  per hit point. Label: *it paid for itself* (dealt at least its own cost).
- **defense**: the same for turrets, with where it stands (distance to the front, turrets around it).

At inference the production and defense models get one yes/no question per candidate ("would a Hive
built now pay for itself?") and the widget takes the most likely; the combat model answers "engage?" and
the widget engages above a threshold.

### Where the data comes from

1. **BARbarian vs BARbarian, spectated** (main source). Two BARbarian AIs (hard, random factions, several
   maps) play while a logging widget watches with full information and logs both sides. At 15x a 25-minute
   game takes about two minutes, so a few hours give tens of thousands of fights, unit lives and turret
   lives from competent play. Labels are measured exactly because the spectator sees everything.
2. Our own duel games against BARbarian can be logged the same way later (only what our team sees).

The features describe what a player would know (unit counts and value by kind, health, turrets nearby,
distances, terrain height); at inference the widget computes them from its own (partial) view.

### One renderer for train and serve

Text drift between training and serving silently ruins such models, so the text is produced in one place:

- the **widget** (and the logging widget) produce *features* (numbers and counts by kind, no prose). Both
  use the same unit classification, moved to `widget/LuaUI/Include/sc_unitkinds.lua`;
- the **bridge** (`internal/decider`) renders features into the System One state and questions for each
  task, routes the request to that task's model and returns the answer;
- `cmd/decidedata` uses the same Go renderer and labelling to turn logged features into training records.

### Data hygiene

- Train / dev / test split **by game** (no fight from a test game is seen in training).
- Balance: combat outcomes and "paid for itself" are imbalanced; we keep the natural rate in dev/test and
  report it, and downsample the majority class in train to at most 2:1.
- Baselines on the same test split, so we know whether the model earns its place:
  1. **rules**: what the widget does now (power ratio for combat; cost/role heuristics for picks);
  2. **Kev-0.8B zero-shot** (released weights, same text);
  3. **logistic regression** on the raw features (cheap, strong; if it wins, we say so).
- Metrics: accuracy, Brier score, and for the pick models how often the top pick paid for itself.

## Phases

1. **Logging**: shared unit kinds; logging widget; spectator scenario and script; batch collection.
2. **Rendering and data**: decider tasks and routing in the bridge; `cmd/decidedata` (features → JSONL,
   labels, split, balance).
3. **Training** on a Lightning studio (H100): three Kev-0.8B fine-tunes; held-out evaluation against the
   baselines; temperature fitted on dev.
4. **Serving**: three `kev.serve` processes on `force` (ports 8011-8013), bridge flags for per-task routes,
   widget integration behind the decider switch (combat engage checks, production picks, turret picks).
5. **In-game A/B**: fast batches against BARbarian with and without the models.
6. **Write-up**: results here, README section.

## Success criteria

- Offline: each model beats the rules and Kev-0.8B zero-shot on its held-out test games (Brier and
  accuracy, bootstrap over games), or we don't ship it.
- Online: in fast batches against BARbarian medium, better kill/loss and damage ratios than rules-only at
  the same or better survival. Single games vary a lot (see `docs/research/test-games.md`), so batches of
  at least 8 games per arm.

## Risks

- **Spectator view vs player view**: models trained on full information get partial information in play.
  Mitigation: features are counts the widget can know (what it has seen recently); acceptable gap.
- **BARbarian-specific behaviour**: the models learn how BARbarian fights. Our units are driven by our
  rules, so outcomes transfer only approximately; the in-game A/B is the real check.
- **Too little turret data**: turrets are rarer than units. More games or merge into one "value" model.
- **Logistic regression wins**: then we report it, and serve the better one; the System One interface
  doesn't care what's behind it.

## Results

### Phase 1-2: data and labels

- Collection: BARbarian vs BARbarian at 15x, about 2 minutes per game; a hard-vs-hard game on a big map
  yields ~300-900 fights, ~150-250 unit lives and ~10-100 turret lives.
- Widgets don't get the attacker in `UnitDamaged` (BAR's handler drops it), so damage dealt comes from the
  engine's **experience**: each hit adds 0.1 x experienceMult (0.3 in BAR) x victim power / own power x
  damage / victim health, and a kill adds the whole victim. Value dealt = experience / 0.03 x own cost,
  minus the value of its kills (credited from `UnitDestroyed`'s attacker).
- Half of all contacts end with nothing lost in 25 s (skirmishes); fights where less than 150 metal was
  lost in total are left out.
- Smoke run on an L4 studio: Kev-0.8B fine-tune at 0.2 s per record; the pipeline (train, temperature on
  dev, test scores vs the untouched model) works end to end.

### Baselines (38 games, test split by game)

With value and counts by kind only (logger v1), fight outcomes were barely predictable (AUC ~0.65, the value
rule ~0.62). Adding each group's total damage per second, hit points and value-weighted range, and the game
minute (logger v2) changed that:

| Task | Rule today | Logistic regression | Gradient boosting |
|---|---|---|---|
| fight (227 test fights) | acc 0.62, AUC 0.62 | acc 0.78, AUC 0.83, Brier 0.167 | acc 0.78, AUC 0.85, Brier 0.162 |
| unit (500 test units, 26% paid) | - | AUC 0.56 | AUC 0.60 |
| turret (121 test turrets, 14% paid) | - | AUC 0.73 | AUC 0.66 |

Fights are learnable; whether a single unit pays for itself mostly depends on what happens to it later, so
the unit task is weak from the situation alone.

### Phase 3: training (v1, 43 games; Lightning studio, L40S)

H100, H200 and A100 aren't available in the teamspace's cloud account; an L40S trains Kev-0.8B at about
0.11 s per record (fight: 4,738 records x 2 epochs in ~18 minutes). Test split by game, same rows for all:

| Task | Kev-0.8B as released | **Kev-0.8B fine-tuned (ours)** | Logistic regression | Gradient boosting | Rule today |
|---|---|---|---|---|---|
| fight (773) | AUC 0.57, Brier 0.247 | AUC 0.74, Brier 0.207, acc 0.65 | AUC 0.72, Brier 0.214 | **AUC 0.77, Brier 0.195**, acc 0.70 | AUC 0.55 |
| turret (251) | AUC 0.45, Brier 0.238 | AUC 0.71, **Brier 0.143**, acc 0.79 | AUC 0.72, Brier 0.166 | AUC 0.72, Brier 0.161 | - |
| unit (1,125) | AUC 0.51, Brier 0.230 | **AUC 0.59, Brier 0.186** | AUC 0.58, Brier 0.189 | AUC 0.57, Brier 0.199 | - |

Fine-tuning turns Kev-0.8B from no better than chance into a useful model on every task; on fights the
gradient-boosted trees are a little better, on turrets and units the fine-tune is the best calibrated.
Temperatures fitted on dev came out near 1 (fight 1.07, turret 0.98).

### Phase 4: serving

On `force` (RTX 4090): three `kev.serve` processes (fight 8011, unit 8012, turret 8013) and the tree models
behind `serve_gbt.py` (8014), 8.7 GB of GPU memory in total, ~30 ms per request once warm. The bridge
routes per task (`-decider-routes`); in game every request was answered (no failures over 24 games).

### Phase 5: in-game A/B (8 fast rules-only games per arm, BARbarian medium)

| Arm | Lost | Metal | Kills | Losses | Damage dealt / taken |
|---|---|---|---|---|---|
| R: rules only | 2 | 22.9k | 30 | 147 | 0.51 |
| K: our Kev models (fight, unit, turret) | 4 | 38.9k | 48 | 273 | 0.47 |
| G: gradient boosting (all three tasks) | 5 | 32.1k | 40 | 275 | 0.47 |

Better offline scores did **not** mean better play. The production model is the reason: asked "which
candidate will most likely pay for itself?", it picks the cheapest units (K built 505 Satyrs, G mostly
Goblins, the rules mostly Karkinos and Ballista). Cheap units clear that bar individually more often, but
an army of them loses: the label can't see that heavier units protect the rest. The unit task as designed
is a bad policy target.

Follow-ups:

| Arm | Games | Lost | Metal | Kills | Losses | Damage dealt / taken |
|---|---|---|---|---|---|---|
| F: Kev fight + turret models, rules production | 8 | 4 | 31.5k | 41 | 184 | 0.59 |
| L: F + production by combat-model lookahead | 8 | 5 | 18.4k | 31 | 162 | 0.55 |
| R (16 games, two batches) | 16 | **3** | 32.1k | 39 | 156 | 0.61 |
| F (16 games, two batches) | 16 | 7 | 35.7k | 50 | 183 | **0.65** |

- Production by lookahead (add a metal budget of each candidate to our army, ask the fight model whether
  that army would come out ahead against the enemy army seen, build the best) gives sensible armies
  (Karkinos, Toxotai anti-air when air is seen, Ballista) instead of only the cheapest unit.
- With the fight and turret models the army fights more and a little better (more kills, better damage
  ratio) but the team loses more games: 7 of 16 against 3 of 16 (not significant, p ~ 0.25, but no sign of
  improvement). The fight model judges the *local* fight well; "we'd win this fight" then sends the army to
  other zones and on pushes, and the base pays for it. That is a policy problem, not a prediction problem.

### v2 (74 games of logger v2, 3 epochs for fight)

| Task (v2 test) | Kev-0.8B as released | Our v2 fine-tune | Gradient boosting | Logistic regression |
|---|---|---|---|---|
| fight (1,131) | AUC 0.62, Brier 0.241 | AUC 0.81, Brier 0.176, acc 0.72 | AUC 0.82, Brier 0.172, acc 0.73 | AUC 0.75, Brier 0.205 |
| turret (468) | AUC 0.47, Brier 0.235 | AUC 0.74, Brier 0.137, acc 0.81 | AUC 0.78, Brier 0.134 | AUC 0.75, Brier 0.140 |
| unit (1,709) | AUC 0.53, Brier 0.229 | AUC 0.62, Brier 0.188 | AUC 0.63, Brier 0.184 | AUC 0.59, Brier 0.190 |

More data closed the gap: the fine-tuned Kev-0.8B is now level with gradient-boosted trees on every task
(within ~0.01 AUC / 0.004 Brier), and far ahead of the released model and of today's rule. The v2 models
are what `force` serves (`decider.sh start bar v2`).

## Conclusions

1. **We can train our own BAR decision models, and they predict well.** Outcome labels from spectated
   BARbarian games are cheap (two minutes per game at 15x) and honest. A fine-tuned Kev-0.8B predicts fight
   outcomes at AUC 0.81 (today's rule: 0.57-0.62), turret value at 0.74; unit value is hard (0.62).
2. **Kev-style fine-tunes match gradient-boosted trees** once there's enough data, at ~30 ms per decision
   on a 4090; the trees are cheaper but need the numbers, the Kev models also take free text. Both are
   servable behind the same API (`kev.serve`, `serve_gbt.py`), routed per task by the bridge.
3. **Better predictions didn't win more games.** "Will this unit pay for itself?" is a bad production
   target (cheap units); "will we win this fight?" is a good prediction but a bad policy on its own
   (local wins pull the army away from home). What decides games is the policy that uses the predictions.
4. So the models stay **optional and off by default**; the rules remain the default policy.

## What would likely help next

- Decide *where the army should be*, not only whether a fight is winnable: e.g. engage only fights inside
  or next to our zones, or weigh "away from base" against the win probability.
- A label about the team, not the unit: "does adding this unit raise the chance our army wins its next
  fight" (the lookahead is a first step), or game-level value (win/loss) with many more games.
- Learn from our own team's games (the logger works as a player too), so the models see our rules' units
  and positioning, not only BARbarian's.
- More data for turrets and units, and BARbarian vs BARbarian on more maps.

## Reproduce

```sh
testenv/collect.sh 60                                     # BARbarian vs BARbarian, logged (2 min / game)
go run ./cmd/decidedata -in testenv/data/raw -out testenv/data/sets
uv run --with scikit-learn python deploy/decider/baselines.py testenv/data/sets
lightning studio start --name bar-decider-train --create --machine L40S
scp -r testenv/data/sets bar-decider-train:bar-sets; scp deploy/decider/*.{sh,py} bar-decider-train:bar-deploy/
ssh bar-decider-train bar-deploy/train_bar.sh v2           # fine-tune, calibrate, score vs Kev-0.8B
# copy ~/kev/runs/bar-<task>-v2 to the GPU host's ~/bar-decider/runs/, then
ssh gpu-host sh bar-decider/deploy/decider.sh start bar v2   # fight :8011, unit :8012, turret :8013
# bridge: SCBRIDGE_DECIDER_ROUTES=fight=http://gpu-host:8011,unit=http://gpu-host:8012,turret=http://gpu-host:8013
```
