package decider

// Tasks: the decisions our own models make (design/decision-models.md). The widget and the data logger
// send features (numbers and counts by kind); this file turns them into System One state text and
// questions. Training data (cmd/decidedata) and live requests go through the same functions, so the text a
// model sees in play is exactly the text it was trained on.

import (
	"cmp"
	"encoding/json"
	"fmt"
	"math"
	"slices"
	"strings"
)

// Task names, also the keys of per-task model routes.
const (
	TaskFight  = "fight"  // combat: does our group come out ahead of this fight?
	TaskUnit   = "unit"   // production: would this unit pay for itself?
	TaskTurret = "turret" // defense: would this turret pay for itself?

	// imitation of strong players (pro replays): what would they build from these options?
	TaskProduce    = "produce"    // a factory's next combat unit
	TaskTurretPick = "turretpick" // a constructor's next turret
)

// Group is a set of units summarised: counts by kind, total metal value, average health %, aircraft.
type Group struct {
	Kinds  map[string]int `json:"kinds"`
	Value  int            `json:"value"`
	Health int            `json:"health"`
	Count  int            `json:"count"`
	Air    int            `json:"air"`
	DPS    int            `json:"dps"`   // total damage per second
	HP     int            `json:"hp"`    // total hit points left
	Range  int            `json:"range"` // weapon range, averaged by value
}

// UnmarshalJSON accepts the Lua encoder's [] for an empty kinds table.
func (g *Group) UnmarshalJSON(b []byte) error {
	var raw struct {
		Kinds  json.RawMessage `json:"kinds"`
		Value  float64         `json:"value"`
		Health float64         `json:"health"`
		Count  int             `json:"count"`
		Air    int             `json:"air"`
		DPS    float64         `json:"dps"`
		HP     float64         `json:"hp"`
		Range  float64         `json:"range"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	g.Value, g.Health, g.Count, g.Air = int(raw.Value), int(raw.Health), raw.Count, raw.Air
	g.DPS, g.HP, g.Range = int(raw.DPS), int(raw.HP), int(raw.Range)
	g.Kinds = map[string]int{}
	if len(raw.Kinds) > 0 && raw.Kinds[0] == '{' {
		return json.Unmarshal(raw.Kinds, &g.Kinds)
	}
	return nil
}

// FightFeatures describe a fight from one side.
type FightFeatures struct {
	Own          Group `json:"own"`
	OwnTurrets   Group `json:"ownTurrets"`
	Enemy        Group `json:"enemy"`
	EnemyTurrets Group `json:"enemyTurrets"`
	Minute       int   `json:"minute"`     // game time
	HeightDiff   int   `json:"heightDiff"` // our average height minus theirs, elmos
	OwnStart     int   `json:"ownStart"`   // distance from our start, elmos (-1 unknown)
	EnemyStart   int   `json:"enemyStart"` // distance from the nearest enemy start
}

// UnitTraits describe a unit type a factory or constructor could build.
type UnitTraits struct {
	Name   string `json:"name"`
	Human  string `json:"human"`
	Kind   string `json:"kind"`
	Cost   int    `json:"cost"`
	Range  int    `json:"range"`
	Speed  int    `json:"speed"`
	Health int    `json:"health"`
	DPS    int    `json:"dps"`
	Air    bool   `json:"air"`
	AAOnly bool   `json:"aaOnly"`
	Tech   int    `json:"tech"`
}

// Situation is what a team fields and faces.
type Situation struct {
	Own         Group   `json:"own"`
	Enemy       Group   `json:"enemy"`
	MetalIncome float64 `json:"metalIncome"`
}

// Place is where a turret would stand.
type Place struct {
	TurretsNear  int `json:"turretsNear"`
	OwnStart     int `json:"ownStart"`
	EnemyStart   int `json:"enemyStart"`
	NearestEnemy int `json:"nearestEnemy"` // -1: none within 3000
}

// ValueFeatures are the input of the unit and turret tasks: the situation, where (turrets only), and the
// candidate types to judge.
type ValueFeatures struct {
	Minute     int          `json:"minute"`
	Situation  Situation    `json:"situation"`
	Place      *Place       `json:"place,omitempty"`
	Candidates []UnitTraits `json:"candidates"`
}

// Question is one System One question.
type Question struct {
	Type         string `json:"type"`
	Instructions string `json:"instructions"`
	Criteria     any    `json:"criteria,omitempty"`
	Label        any    `json:"label,omitempty"` // training data only
}

// FightOutcomes are the levels of the fight's outcome score question.
var FightOutcomes = []string{"we lose badly", "we lose", "about even", "we win", "we win decisively"}

const (
	qAhead   = "Will our group come out ahead in this fight (the enemy loses more value than we do in the next 25 seconds)?"
	qOutcome = "How will this fight go for our group over the next 25 seconds?"
)

func kindsText(k map[string]int) string {
	type kv struct {
		k string
		n int
	}
	var list []kv
	for name, n := range k {
		if n > 0 {
			list = append(list, kv{name, n})
		}
	}
	slices.SortFunc(list, func(a, b kv) int {
		return cmp.Or(cmp.Compare(b.n, a.n), cmp.Compare(a.k, b.k))
	})
	parts := make([]string, len(list))
	for i, e := range list {
		parts[i] = fmt.Sprintf("%d %s", e.n, e.k)
	}
	if len(parts) == 0 {
		return "none"
	}
	return strings.Join(parts, ", ")
}

func groupText(g Group) string {
	if g.Count == 0 {
		return "none"
	}
	return fmt.Sprintf("%d units worth %d metal (%s), health %d%%, firepower %d damage per second, %d hit points, typical range %d",
		g.Count, g.Value, kindsText(g.Kinds), g.Health, g.DPS, g.HP, g.Range)
}

func distText(d int) string {
	if d < 0 {
		return "unknown"
	}
	return fmt.Sprintf("%d elmos", d)
}

// FightState renders a fight's state text.
func FightState(f FightFeatures) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Beyond All Reason RTS, a fight from our side, %d minutes into the game.\n", f.Minute)
	fmt.Fprintf(&b, "Our group: %s.\n", groupText(f.Own))
	fmt.Fprintf(&b, "Our turrets nearby: %s.\n", groupText(f.OwnTurrets))
	fmt.Fprintf(&b, "Enemy units: %s.\n", groupText(f.Enemy))
	fmt.Fprintf(&b, "Enemy turrets: %s.\n", groupText(f.EnemyTurrets))
	switch {
	case f.HeightDiff > 30:
		fmt.Fprintf(&b, "We hold higher ground by %d elmos.\n", f.HeightDiff)
	case f.HeightDiff < -30:
		fmt.Fprintf(&b, "The enemy holds higher ground by %d elmos.\n", -f.HeightDiff)
	default:
		b.WriteString("Ground is level.\n")
	}
	fmt.Fprintf(&b, "Distance from our start: %s; from the enemy start: %s.", distText(f.OwnStart), distText(f.EnemyStart))
	return b.String()
}

// FightQuestions are the fight task's questions.
func FightQuestions() map[string]Question {
	return map[string]Question{
		"ahead":   {Type: "noul", Instructions: qAhead},
		"outcome": {Type: "score", Instructions: qOutcome, Criteria: FightOutcomes},
	}
}

// FightOutcome labels a fight from the value each side lost: ahead, and the outcome level (index into
// FightOutcomes). ok is false when nothing was lost on either side (no fight happened).
func FightOutcome(ownLost, enemyLost int) (ahead bool, level int, ok bool) {
	if ownLost+enemyLost == 0 {
		return false, 0, false
	}
	r := float64(enemyLost-ownLost) / float64(enemyLost+ownLost)
	switch {
	case r <= -0.6:
		level = 0
	case r <= -0.2:
		level = 1
	case r < 0.2:
		level = 2
	case r < 0.6:
		level = 3
	default:
		level = 4
	}
	return enemyLost > ownLost, level, true
}

func unitText(u UnitTraits) string {
	var extra []string
	if u.Air {
		extra = append(extra, "aircraft")
	}
	if u.AAOnly {
		extra = append(extra, "shoots aircraft only")
	}
	if u.Tech >= 2 {
		extra = append(extra, fmt.Sprintf("tech %d", u.Tech))
	}
	s := fmt.Sprintf("%s (%s): %s, cost %d metal, health %d, range %d, speed %d, damage per second %d", u.Human, u.Name, u.Kind, u.Cost, u.Health, u.Range, u.Speed, u.DPS)
	if len(extra) > 0 {
		s += ", " + strings.Join(extra, ", ")
	}
	return s
}

// ValueState renders the state of the unit and turret tasks (the candidates go in the questions).
func ValueState(task string, f ValueFeatures) string {
	var b strings.Builder
	if task == TaskTurret {
		fmt.Fprintf(&b, "Beyond All Reason RTS, %d minutes into the game, our constructor is choosing a turret to build.\n", f.Minute)
	} else {
		fmt.Fprintf(&b, "Beyond All Reason RTS, %d minutes into the game, our factory is choosing a unit to build.\n", f.Minute)
	}
	fmt.Fprintf(&b, "Our army and turrets: %s.\n", groupText(f.Situation.Own))
	fmt.Fprintf(&b, "The enemy's army and turrets: %s.\n", groupText(f.Situation.Enemy))
	fmt.Fprintf(&b, "Our metal income: %.1f per second.", f.Situation.MetalIncome)
	if p := f.Place; p != nil {
		fmt.Fprintf(&b, "\nWhere it would stand: %d of our turrets within 600 elmos; %s from our start, %s from the enemy start; nearest enemy %s away.",
			p.TurretsNear, distText(p.OwnStart), distText(p.EnemyStart), map[bool]string{true: "more than 3000 elmos", false: distText(p.NearestEnemy)}[p.NearestEnemy < 0])
	}
	return b.String()
}

// ValueQuestions asks, per candidate (keyed by unit name), whether it would pay for itself.
func ValueQuestions(task string, f ValueFeatures) map[string]Question {
	what := "unit built now"
	if task == TaskTurret {
		what = "turret built here"
	}
	qs := map[string]Question{}
	for _, c := range f.Candidates {
		qs[c.Name] = Question{Type: "noul", Instructions: fmt.Sprintf("Would this %s deal more damage, in metal value, than it costs before it dies? %s.", what, unitText(c))}
	}
	return qs
}

// ChoiceState renders the imitation tasks' state: the same situation as the value tasks.
func ChoiceState(task string, f ValueFeatures) string {
	if task == TaskTurretPick {
		return ValueState(TaskTurret, f)
	}
	return ValueState(TaskUnit, f)
}

// ChoiceQuestions asks which candidate a strong player would build, as one choice question.
func ChoiceQuestions(task string, f ValueFeatures) map[string]Question {
	criteria := map[string]string{}
	for _, c := range f.Candidates {
		criteria[c.Name] = unitText(c)
	}
	instr := "Which unit would a strong player have this factory build next?"
	if task == TaskTurretPick {
		instr = "Which turret would a strong player build next?"
	}
	return map[string]Question{"pick": {Type: "choice", Instructions: instr, Criteria: criteria}}
}

// Render turns a task's features (as the widget sends them) into state and questions.
func Render(task string, features json.RawMessage) (string, map[string]Question, error) {
	switch task {
	case TaskFight:
		var f FightFeatures
		if err := json.Unmarshal(features, &f); err != nil {
			return "", nil, fmt.Errorf("fight features: %w", err)
		}
		return FightState(f), FightQuestions(), nil
	case TaskUnit, TaskTurret:
		var f ValueFeatures
		if err := json.Unmarshal(features, &f); err != nil {
			return "", nil, fmt.Errorf("%s features: %w", task, err)
		}
		if len(f.Candidates) == 0 {
			return "", nil, fmt.Errorf("%s: no candidates", task)
		}
		return ValueState(task, f), ValueQuestions(task, f), nil
	case TaskProduce, TaskTurretPick:
		var f ValueFeatures
		if err := json.Unmarshal(features, &f); err != nil {
			return "", nil, fmt.Errorf("%s features: %w", task, err)
		}
		if len(f.Candidates) < 2 {
			return "", nil, fmt.Errorf("%s: need at least two candidates", task)
		}
		return ChoiceState(task, f), ChoiceQuestions(task, f), nil
	}
	return "", nil, fmt.Errorf("unknown task %q", task)
}

// Flat numeric features, for models that take numbers instead of text (logistic regression, gradient
// boosting: cmd/decidedata writes them for training, the router sends them with every task request).

func flatGroup(prefix string, g Group, f map[string]float64) {
	f[prefix+".value"] = float64(g.Value)
	f[prefix+".count"] = float64(g.Count)
	f[prefix+".health"] = float64(g.Health)
	f[prefix+".air"] = float64(g.Air)
	f[prefix+".dps"] = float64(g.DPS)
	f[prefix+".hp"] = float64(g.HP)
	f[prefix+".range"] = float64(g.Range)
	for k, n := range g.Kinds {
		f[prefix+".kind."+k] = float64(n)
	}
}

// FlatFight flattens a fight.
func FlatFight(s FightFeatures) map[string]float64 {
	f := map[string]float64{"heightDiff": float64(s.HeightDiff), "ownStart": float64(s.OwnStart), "enemyStart": float64(s.EnemyStart), "minute": float64(s.Minute)}
	flatGroup("own", s.Own, f)
	flatGroup("ownTurrets", s.OwnTurrets, f)
	flatGroup("enemy", s.Enemy, f)
	flatGroup("enemyTurrets", s.EnemyTurrets, f)
	f["logRatio"] = math.Log((float64(s.Own.Value+s.OwnTurrets.Value) + 1) / (float64(s.Enemy.Value+s.EnemyTurrets.Value) + 1))
	return f
}

// FlatValue flattens the unit/turret situation for one candidate.
func FlatValue(v ValueFeatures, u UnitTraits) map[string]float64 {
	f := map[string]float64{
		"metalIncome": v.Situation.MetalIncome, "unit.cost": float64(u.Cost), "unit.range": float64(u.Range),
		"unit.speed": float64(u.Speed), "unit.health": float64(u.Health), "unit.dps": float64(u.DPS),
		"unit.tech": float64(u.Tech), "unit.kind." + u.Kind: 1, "minute": float64(v.Minute),
	}
	if u.Air {
		f["unit.air"] = 1
	}
	if u.AAOnly {
		f["unit.aaOnly"] = 1
	}
	flatGroup("own", v.Situation.Own, f)
	flatGroup("enemy", v.Situation.Enemy, f)
	if p := v.Place; p != nil {
		f["place.turretsNear"], f["place.ownStart"], f["place.enemyStart"], f["place.nearestEnemy"] = float64(p.TurretsNear), float64(p.OwnStart), float64(p.EnemyStart), float64(p.NearestEnemy)
	}
	return f
}

// Flat returns the flat features of a task request, one set per question key.
func Flat(task string, features json.RawMessage) (map[string]map[string]float64, error) {
	switch task {
	case TaskFight:
		var f FightFeatures
		if err := json.Unmarshal(features, &f); err != nil {
			return nil, err
		}
		flat := FlatFight(f)
		return map[string]map[string]float64{"ahead": flat, "outcome": flat}, nil
	case TaskUnit, TaskTurret, TaskProduce, TaskTurretPick:
		var v ValueFeatures
		if err := json.Unmarshal(features, &v); err != nil {
			return nil, err
		}
		out := map[string]map[string]float64{}
		for _, c := range v.Candidates {
			out[c.Name] = FlatValue(v, c)
		}
		return out, nil
	}
	return nil, fmt.Errorf("unknown task %q", task)
}
