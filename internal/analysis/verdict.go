package analysis

import (
	"fmt"
	"io"
	"math"
	"math/rand/v2"
	"path/filepath"
	"sort"
	"strings"

	"github.com/rusenask/bar-ai-sub-commanders/internal/learn"
)

// Verdict: is an arm really different from the baseline, and in which stage of the game? Each metric is
// a per-game number; the difference of the arms' means gets a bootstrap interval (95%: Confidence) (resampling each
// arm's games), and only an interval that leaves out zero says "better" or "worse". At 12 games a side
// most single metrics say "can't tell": that is the honest answer, and the cue to run more games.

// Confidence is the intervals' level (gamereport -confidence): 0.95 for a fixed-size test; a sequential
// test (scripts/seqtest.py) looks several times and asks for more at the interim looks.
var Confidence = 0.95

// quantiles: the interval's ends in sorted bootstrap differences, at Confidence
func quantiles(d []float64) (lo, hi float64) {
	n := len(d)
	tail := (1 - Confidence) / 2
	i, j := int(float64(n)*tail), int(float64(n)*(1-tail))
	if j >= n {
		j = n - 1
	}
	return d[i], d[j]
}

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

// reached: the game lasted into the stage (a game lost at minute 8 says nothing about the late game);
// battles have no stages
func reached(g *Game, from int) bool { return g.Battle == nil && g.Seconds >= from*60 }

func verdictMetrics() []metric {
	ms := []metric{
		// battles (scenario battle): how well we traded, as log2 so 2x better and 2x worse weigh the same
		{"battle efficiency (log2)", true, func(g *Game) (float64, bool) {
			if g.Battle == nil {
				return 0, false
			}
			return math.Log2(math.Max(g.Battle.Efficiency(), 0.125)), true
		}},
		{"battle: our share lost", false, func(g *Game) (float64, bool) {
			if g.Battle == nil || g.Battle.UsStart <= 0 {
				return 0, false
			}
			return (g.Battle.UsStart - g.Battle.UsLeft) / g.Battle.UsStart, true
		}},
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
			if e == nil || g.Battle != nil {
				return 0, false
			}
			return e.Value("mex"), true
		}},
		metric{"army at 12 min", true, func(g *Game) (float64, bool) {
			e := At(g.Eco, 12)
			if e == nil || g.Battle != nil {
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

// strata groups a metric's values by battle spec ("" for games): specs differ far more from each other
// than an arm changes them, so battles are compared within each spec
func strata(games []*Game, m metric) map[string][]float64 {
	out := map[string][]float64{}
	for _, g := range games {
		if v, ok := m.value(g); ok {
			key := ""
			if g.Battle != nil {
				key = g.Battle.Spec
			}
			out[key] = append(out[key], v)
		}
	}
	return out
}

// stratifiedInterval: the mean over strata (in both arms) of mean(b) - mean(a), with a 95% bootstrap
// interval resampling within each stratum.
func stratifiedInterval(a, b map[string][]float64, rng *rand.Rand) (diff, lo, hi float64, ok bool) {
	var keys []string
	for k := range a {
		if len(a[k]) > 0 && len(b[k]) > 0 {
			keys = append(keys, k)
		}
	}
	if len(keys) == 0 {
		return 0, 0, 0, false
	}
	sort.Strings(keys)
	est := func(pick func([]float64) float64) float64 {
		t := 0.0
		for _, k := range keys {
			t += pick(b[k]) - pick(a[k])
		}
		return t / float64(len(keys))
	}
	diff = est(meanOf)
	const n = 2000
	d := make([]float64, n)
	for i := range d {
		d[i] = est(func(v []float64) float64 {
			r := 0.0
			for range v {
				r += v[rng.IntN(len(v))]
			}
			return r / float64(len(v))
		})
	}
	sort.Float64s(d)
	lo, hi = quantiles(d)
	return diff, lo, hi, true
}

// pairs: the two arms of an interleaved batch (testenv/sandbox/batch.py --widgets-b: <batch>-A and
// <batch>-B, game k of each played the same spec on the same machine at about the same time) give the
// metric's difference per pair; nil when the arms aren't the two halves of one batch.
func pairs(armA, armB Arm, m metric) []float64 {
	la, lb := filepath.Base(armA.Label), filepath.Base(armB.Label)
	if !(strings.HasSuffix(la, "-A") && strings.HasSuffix(lb, "-B") && strings.TrimSuffix(la, "-A") == strings.TrimSuffix(lb, "-B")) {
		return nil
	}
	a, b := armA.Games, armB.Games
	byName := map[string]*Game{}
	for _, g := range a {
		byName[filepath.Base(g.Source)] = g
	}
	var out []float64
	for _, g := range b {
		o := byName[filepath.Base(g.Source)]
		if o == nil {
			continue
		}
		vb, okb := m.value(g)
		va, oka := m.value(o)
		if oka && okb {
			out = append(out, vb-va)
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
	return quantiles(d)
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
			if len(a) == 0 && len(b) == 0 {
				continue // not this kind of batch (battle rows for games, game rows for battles)
			}
			if len(a) < 3 || len(b) < 3 {
				row.Verdict = "too few games"
				rows = append(rows, row)
				continue
			}
			row.Base, row.Arm = meanOf(a), meanOf(b)
			sa, sb := strata(base.Games, m), strata(arm.Games, m)
			if d := pairs(base, arm, m); len(d) >= 3 {
				// an interleaved batch: the difference within each pair, resampled
				row.Arm = row.Base + meanOf(d)
				row.Lo, row.Hi = diffInterval(make([]float64, len(d)), d, rng)
				row.Metric += " (paired)"
			} else if len(sa) > 1 || len(sb) > 1 {
				// battles: within each spec, then averaged (Arm = Base + the stratified difference)
				diff, lo, hi, ok := stratifiedInterval(sa, sb, rng)
				if ok {
					row.Arm, row.Lo, row.Hi = row.Base+diff, lo, hi
					row.Metric += " (within specs)"
				}
			} else {
				row.Lo, row.Hi = diffInterval(a, b, rng)
			}
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
		pct := int(math.Round(Confidence * 100))
		fmt.Fprintf(w, "\n### %s vs %s (%d%% intervals of the difference; \"can't tell\" = the interval holds 0)\n\n", arm.Label, arms[0].Label, pct)
		fmt.Fprintf(w, "| Metric | Baseline | Arm | Difference [%d%%] | Games | Verdict |\n", pct)
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
