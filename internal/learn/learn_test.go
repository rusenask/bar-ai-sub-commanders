package learn

import (
	"math"
	"math/rand/v2"
	"strings"
	"testing"
)

func TestParamsFromDoctrine(t *testing.T) {
	ps, err := ParamsFromDoctrine("../../widget/LuaUI/Include/sc_doctrine.lua")
	if err != nil {
		t.Fatal(err)
	}
	by := map[string]Param{}
	for _, p := range ps {
		by[p.Name] = p
	}
	if p := by["engage_attack"]; p.Min != 0.8 || p.Max != 2.5 || p.Default <= 0 {
		t.Errorf("engage_attack %+v", p)
	}
	if p := by["max_factories"]; !p.Int || p.Default != 5 {
		t.Errorf("max_factories %+v", p)
	}
	if p := by["response_weight"]; p.Default != 0.6 {
		t.Errorf("response_weight %+v", p)
	}
	if len(ps) < 15 {
		t.Errorf("only %d params", len(ps))
	}
}

func TestScore(t *testing.T) {
	if Score("WIN", 30, 1, 60) <= Score("WIN", 59, 1, 60) {
		t.Error("an early win is worth more")
	}
	if Score("TIMEOUT", 60, 1, 60) <= Score("LOSS", 59, 1, 60) {
		t.Error("alive beats lost")
	}
	if Score("LOSS", 50, 1, 60) <= Score("LOSS", 10, 1, 60) {
		t.Error("surviving longer counts")
	}
	if Score("TIMEOUT", 60, 2, 60) <= Score("TIMEOUT", 60, 0.5, 60) {
		t.Error("trades count")
	}
}

// A toy problem: the score peaks at x = 0.8 of the range for one rule; the search should find it.
func TestSearchConverges(t *testing.T) {
	s := New("toy", []Param{{Name: "x", Min: 0, Max: 10, Default: 2}, {Name: "y", Min: 0, Max: 1, Default: 0.5}})
	rng := rand.New(rand.NewPCG(1, 2))
	for range 25 {
		var trials []Trial
		for _, r := range s.Sample(24, rng) {
			score := 1 - math.Abs(r["x"]-8)/10 + rng.NormFloat64()*0.05
			trials = append(trials, Trial{Rules: r, Score: score})
		}
		s.Update(trials)
	}
	if math.Abs(s.Mean["x"]-8) > 1 {
		t.Errorf("x mean %.2f, want ~8", s.Mean["x"])
	}
	if s.Generation != 25 || len(s.History) != 25 || s.History[24].MeanTrials < 0 {
		t.Errorf("history %+v", s.History[len(s.History)-1])
	}
	if len(s.Changes()) == 0 {
		t.Error("changes")
	}
}

func TestSampleIncludesTheMean(t *testing.T) {
	s := New("k", []Param{{Name: "n", Min: 1, Max: 5, Default: 3, Int: true}})
	rs := s.Sample(12, rand.New(rand.NewPCG(3, 4)))
	if !s.IsMean(rs[0]) || !s.IsMean(rs[6]) {
		t.Error("every sixth sample is the mean")
	}
	for _, r := range rs {
		if r["n"] != math.Round(r["n"]) || r["n"] < 1 || r["n"] > 5 {
			t.Errorf("bad int sample %v", r["n"])
		}
	}
}

func TestLoadAddsNewParams(t *testing.T) {
	dir := t.TempDir()
	s := New("k", []Param{{Name: "a", Min: 0, Max: 1, Default: 0.5}})
	if err := s.Save(dir); err != nil {
		t.Fatal(err)
	}
	s2, err := Load(dir, "k", []Param{{Name: "a", Min: 0, Max: 1, Default: 0.5}, {Name: "b", Min: 0, Max: 2, Default: 1}})
	if err != nil || s2.Mean["b"] != 1 || len(s2.Params) != 2 {
		t.Fatalf("%v %+v", err, s2)
	}
}

func TestMatchupFindRecord(t *testing.T) {
	if m := Matchup("Cortex", []string{"Armada", "armada", "Legion"}); m != "cortex-vs-armada+legion" {
		t.Errorf("matchup %q", m)
	}
	dir := t.TempDir()
	params := []Param{{Name: "a", Min: 0, Max: 1, Default: 0.5}}
	small, big := New("cortex-vs-armada-easy", params), New("cortex-vs-armada-medium", params)
	big.Trials = []Trial{{Score: 1}, {Score: 0}}
	big.Generation = 2
	small.Save(dir)
	big.Save(dir)
	st, err := Find(dir, "cortex-vs-armada", params)
	if err != nil || st == nil || st.Key != "cortex-vs-armada-medium" {
		t.Fatalf("find %v %+v", err, st)
	}
	if st, _ := Find(dir, "legion-vs-cortex", params); st != nil {
		t.Error("no store for an unplayed matchup")
	}
	if err := st.RecordReal(dir, map[string]any{"won": true, "minutes": 35.0, "dealt": 2.0, "taken": 1.0}, "test"); err != nil {
		t.Fatal(err)
	}
	again, _ := Load(dir, "cortex-vs-armada-medium", params)
	last := again.Trials[len(again.Trials)-1]
	if len(again.Trials) != 3 || last.Result != "WIN" || !last.Mean || last.Score <= 1 || again.Generation != 2 {
		t.Errorf("recorded %+v gen %d", last, again.Generation)
	}
}

func TestMissingRulesAreIgnored(t *testing.T) {
	s := New("k", []Param{{Name: "a", Min: 0, Max: 10, Default: 5}, {Name: "b", Min: 0, Max: 10, Default: 5}})
	// trials drawn before "b" existed
	trials := []Trial{{Rules: map[string]float64{"a": 5}, Score: 1}, {Rules: map[string]float64{"a": 6}, Score: 0.9}, {Rules: map[string]float64{"a": 1}, Score: 0}}
	sum := s.Update(trials)
	if s.Mean["b"] != 5 {
		t.Errorf("b moved to %.2f without data", s.Mean["b"])
	}
	if sum.MeanTrials < 0 {
		t.Error("the first trial is the mean on the rules it had")
	}
}

func TestLessonBook(t *testing.T) {
	dir := t.TempDir()
	b := LoadBook(dir, "cortex-vs-armada")
	b.Apply([]Op{{Op: "create", Stage: "mid", Text: "hold the army at the turret line until minute 15"},
		{Op: "create", Stage: "opening", Text: "first lab before the third extractor"},
		{Op: "create", Stage: "nonsense", Text: "a lesson for any stage"}}, "g1")
	if len(b.Lessons) != 3 || b.Lessons[2].Stage != "all" {
		t.Fatalf("created %+v", b.Lessons)
	}
	b.Apply([]Op{{Op: "confirm", ID: 1}, {Op: "contradict", ID: 2}, {Op: "merge", IDs: []int{2, 3}, Stage: "opening", Text: "merged"}, {Op: "update", ID: 99}}, "g2")
	if len(b.Lessons) != 2 || b.Lessons[0].Confirmed != 2 || b.Lessons[1].Text != "merged" || b.Lessons[1].Contradicted != 1 {
		t.Fatalf("after g2 %+v", b.Lessons)
	}
	// evidence against wins
	b.Apply([]Op{{Op: "contradict", ID: 1}, {Op: "contradict", ID: 1}, {Op: "contradict", ID: 1}}, "g3")
	if b.find(1) >= 0 {
		t.Error("a lesson contradicted 3 times against 2 confirmations is dropped")
	}
	// the cap
	for range MaxLessons + 4 {
		b.Apply([]Op{{Op: "create", Stage: "late", Text: "x"}}, "g4")
	}
	if len(b.Lessons) != MaxLessons {
		t.Errorf("%d lessons, cap %d", len(b.Lessons), MaxLessons)
	}
	if err := b.Save(dir); err != nil {
		t.Fatal(err)
	}
	again := LoadBook(dir, "cortex-vs-armada")
	if len(again.Lessons) != MaxLessons || !strings.Contains(again.Markdown(), "## late") {
		t.Error("saved and rendered")
	}
	if got := again.ForStage("opening", 5); len(got) != 1 || got[0].Text != "merged" {
		t.Errorf("for the opening: %+v", got)
	}
}

func TestStagedRules(t *testing.T) {
	s := New("k", []Param{{Name: "a", Min: 0, Max: 10, Default: 5}, {Name: "b", Min: 0, Max: 10, Default: 4}})
	s.Active = []string{"a@mid", "nope@x"}
	rs := s.Sample(6, rand.New(rand.NewPCG(1, 1)))
	if _, ok := rs[1]["a@mid"]; !ok || rs[0]["a@mid"] != 5 {
		t.Fatalf("staged rule: %v", rs[:2])
	}
	if rs[1]["a"] != 5 || rs[1]["b"] != 4 {
		t.Error("only the staged rule is searched")
	}
	if _, ok := s.MeanOverlay().Rules["a@mid"]; !ok {
		t.Error("the overlay carries it")
	}
}

// The way cmd/learn runs it: sample -only saves the store before it samples, update loads it again; the
// staged rule must still move toward the games that did well.
func TestStagedRulesLearnAcrossSaves(t *testing.T) {
	dir := t.TempDir()
	params := []Param{{Name: "a", Min: 0, Max: 10, Default: 5}}
	s := New("k", params)
	s.Active = []string{"a@mid"}
	if err := s.Save(dir); err != nil {
		t.Fatal(err)
	}
	rs := s.Sample(12, rand.New(rand.NewPCG(3, 4)))
	s2, err := Load(dir, "k", params)
	if err != nil {
		t.Fatal(err)
	}
	var trials []Trial
	for _, r := range rs {
		trials = append(trials, Trial{Rules: r, Score: r["a@mid"]}) // higher is better
	}
	s2.Update(trials)
	if s2.Mean["a@mid"] <= 5 {
		t.Errorf("a@mid mean %v: should move up", s2.Mean["a@mid"])
	}
	if s2.Mean["a"] != 5 {
		t.Errorf("a moved: %v", s2.Mean["a"])
	}
}

func TestActiveRulesOnly(t *testing.T) {
	s := New("k", []Param{{Name: "a", Min: 0, Max: 10, Default: 5}, {Name: "b", Min: 0, Max: 10, Default: 5}})
	s.Active, s.MeanEvery = []string{"a"}, 3
	rs := s.Sample(9, rand.New(rand.NewPCG(5, 6)))
	means := 0
	for _, r := range rs {
		if r["b"] != 5 {
			t.Fatalf("b was searched: %v", r["b"])
		}
		if s.IsMean(r) {
			means++
		}
	}
	if means != 3 {
		t.Errorf("%d mean samples, want every third", means)
	}
}

func TestOnlyValidatedRulesAreServed(t *testing.T) {
	s := New("k", []Param{{Name: "a", Min: 0, Max: 10, Default: 5}})
	if _, ok := s.ServedOverlay(); ok {
		t.Fatal("nothing validated yet")
	}
	s.Mean["a"] = 7
	s.Validate("A/B 12 v 12")
	s.Mean["a"] = 9 // the search moves on
	ov, ok := s.ServedOverlay()
	if !ok || ov.Rules["a"] != 7 {
		t.Errorf("served %+v %v: want the validated 7", ov, ok)
	}
}

func TestParamsFromNestedDoctrine(t *testing.T) {
	ps, err := ParamsFromDoctrine("../../widget/LuaUI/Include/sc_doctrine.lua")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]float64{"skirmisher_kite": 0.6, "skirmisher_hold": 0.72, "artillery_kite": 0.62, "focus_kill_time": 2,
		"focus_overkill": 1.2, "micro_kite_range": 450, "engage_attack": 1.2}
	got := map[string]float64{}
	for _, p := range ps {
		got[p.Name] = p.Default
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s default %v, want %v", k, got[k], v)
		}
	}
}
