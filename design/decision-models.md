# Design: our own decision models (combat, production, defense)

Status: in progress. Results are filled in at the end as the phases complete.

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

(to be filled in)
