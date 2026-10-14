package analysis

import (
	"fmt"
	"io"
	"math"
	"math/rand/v2"
	"sort"

	"github.com/rusenask/bar-ai-sub-commanders/internal/learn"
)

// Verdict: is an arm really different from the baseline, and in which stage of the game? Each metric is
// a per-game number; the difference of the arms' means gets a 95% bootstrap interval (resampling each
// arm's games), and only an interval that leaves out zero says "better" or "worse". At 12 games a side
// most single metrics say "can't tell": that is the honest answer, and the cue to run more games.

// Stages of a game, by minute: an idea can pay in one and cost in another.
var Stages = []struct {
	Name     string
	From, To int // minutes [From, To)
}{
	{"opening", 0, 10},
	{"mid", 10, 25},
	{"late", 25, 1000},
}

// metric is one per-game number and which way is better.
type metric struct {
	name   string
	higher bool // higher is better
	value  func(g *Game) (float64, bool)
}

func stageSum(deaths []Death, from, to int) float64 {
	t := 0.0
	for _, d := range deaths {
		if d.Minute >= from && d.Minute < to {
			t += float64(d.Cost)
		}
	}
	return t
}

// StageNet is enemy metal killed minus metal lost in a stage (minutes [from, to)), and whether the game
// lasted into it: what a rule learned for that stage is scored on (cmd/learn update -score <stage>).
func StageNet(g *Game, from, to int) (float64, bool) {
	return stageSum(g.Killed, from, to) - stageSum(g.Lost, from, to), reached(g, from)
}

// reached: the game lasted into the stage (a game lost at minute 8 says nothing about the late game)
func reached(g *Game, from int) bool { return g.Seconds >= from*60 }

func verdictMetrics() []metric {
	ms := []metric{
		{"score (win 1+, alive 0.5, loss by time; trades)", true, func(g *Game) (float64, bool) {
			if g.Result == "" {
				return 0, false
			}
			s := Summarize(g)
			return learn.Score(g.Result, s.Minutes, s.DealtTaken, 60), true
		}},
	}
	for _, st := range Stages {
		from, to := st.From, st.To
		ms = append(ms,
			metric{st.Name + ": metal lost", false, func(g *Game) (float64, bool) {
				return stageSum(g.Lost, from, to), reached(g, from)
			}},
			metric{st.Name + ": enemy metal killed", true, func(g *Game) (float64, bool) {
				return stageSum(g.Killed, from, to), reached(g, from)
			}},
		)
	}
	ms = append(ms,
		metric{"extractors at 20 min", true, func(g *Game) (float64, bool) {
			e := At(g.Eco, 20)
			if e == nil {
				return 0, false
			}
			return e.Value("mex"), true
		}},
		metric{"army at 12 min", true, func(g *Game) (float64, bool) {
			e := At(g.Eco, 12)
			if e == nil {
				return 0, false
			}
			return e.Value("army"), true
		}},
	)
	return ms
}

func values(games []*Game, m metric) []float64 {
	var out []float64
	for _, g := range games {
		if v, ok := m.value(g); ok {
			out = append(out, v)
		}
	}
	return out
}

func meanOf(v []float64) float64 {
	if len(v) == 0 {
		return math.NaN()
	}
	t := 0.0
	for _, x := range v {
		t += x
	}
	return t / float64(len(v))
}

// diffInterval: the 95% bootstrap interval of mean(b) - mean(a).
func diffInterval(a, b []float64, rng *rand.Rand) (lo, hi float64) {
	const n = 2000
	d := make([]float64, n)
	ra, rb := make([]float64, len(a)), make([]float64, len(b))
	for i := range d {
		for j := range ra {
			ra[j] = a[rng.IntN(len(a))]
		}
		for j := range rb {
			rb[j] = b[rng.IntN(len(b))]
		}
		d[i] = meanOf(rb) - meanOf(ra)
	}
	sort.Float64s(d)
	return d[n*25/1000], d[n*975/1000]
}

// VerdictRow is one metric of one arm against the baseline.
type VerdictRow struct {
	Metric  string  `json:"metric"`
	Base    float64 `json:"base"`
	Arm     float64 `json:"arm"`
	Lo      float64 `json:"lo"`
	Hi      float64 `json:"hi"`
	NBase   int     `json:"nBase"`
	NArm    int     `json:"nArm"`
	Verdict string  `json:"verdict"` // better, worse, can't tell
}

// Verdicts compares each arm with the first (the baseline).
func Verdicts(arms []Arm) map[string][]VerdictRow {
	out := map[string][]VerdictRow{}
	if len(arms) < 2 {
		return out
	}
	rng := rand.New(rand.NewPCG(7, 11)) // fixed: the same batches give the same verdict
	base := arms[0]
	for _, arm := range arms[1:] {
		var rows []VerdictRow
		for _, m := range verdictMetrics() {
			a, b := values(base.Games, m), values(arm.Games, m)
			row := VerdictRow{Metric: m.name, NBase: len(a), NArm: len(b), Verdict: "can't tell"}
			if len(a) < 3 || len(b) < 3 {
				row.Verdict = "too few games"
				rows = append(rows, row)
				continue
			}
			row.Base, row.Arm = meanOf(a), meanOf(b)
			row.Lo, row.Hi = diffInterval(a, b, rng)
			switch {
			case row.Lo > 0:
				row.Verdict = map[bool]string{true: "better", false: "worse"}[m.higher]
			case row.Hi < 0:
				row.Verdict = map[bool]string{true: "worse", false: "better"}[m.higher]
			}
			rows = append(rows, row)
		}
		out[arm.Label] = rows
	}
	return out
}

// WriteVerdicts prints each arm's verdicts against the baseline.
func WriteVerdicts(w io.Writer, arms []Arm) {
	vs := Verdicts(arms)
	for _, arm := range arms[1:] {
		rows := vs[arm.Label]
		fmt.Fprintf(w, "\n### %s vs %s (95%% intervals of the difference; \"can't tell\" = the interval holds 0)\n\n", arm.Label, arms[0].Label)
		fmt.Fprintln(w, "| Metric | Baseline | Arm | Difference [95%] | Games | Verdict |")
		fmt.Fprintln(w, "|---|---|---|---|---|---|")
		for _, r := range rows {
			if r.Verdict == "too few games" {
				fmt.Fprintf(w, "| %s | | | | %d / %d | too few games |\n", r.Metric, r.NBase, r.NArm)
				continue
			}
			fmt.Fprintf(w, "| %s | %s | %s | %+.3g [%+.3g, %+.3g] | %d / %d | **%s** |\n", r.Metric, fmtNum(r.Base), fmtNum(r.Arm),
				r.Arm-r.Base, r.Lo, r.Hi, r.NBase, r.NArm, r.Verdict)
		}
	}
}
