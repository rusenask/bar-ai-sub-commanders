package learn

import (
	"math"
	"math/rand/v2"
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
