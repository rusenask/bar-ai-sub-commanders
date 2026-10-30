package analysis

import (
	"fmt"
	"io"
	"regexp"
	"sort"
	"strings"
)

// PaceMinutes are the minutes the report compares economies at.
var PaceMinutes = []int{3, 5, 8, 10, 12, 15, 20, 25, 30, 40}

// Finding is a weakness worth working on, most severe first.
type Finding struct {
	Severity float64 `json:"severity"` // rough: 1 = clearly hurting games
	Area     string  `json:"area"`     // economy, army, defense, losses, sub-commanders, harness
	Text     string  `json:"text"`
}

// Summary is one game's headline numbers.
type Summary struct {
	Source                 string
	Result                 string
	Minutes                float64
	Metal                  float64
	Killed, Died           float64
	DealtTaken             float64
	BuildersLost, LabsLost int
}

// Summarize returns a game's headline numbers.
func Summarize(g *Game) Summary {
	s := Summary{Source: g.Source, Result: g.Result, Minutes: float64(g.Seconds) / 60, Metal: g.Stats["metalProduced"],
		Killed: g.Stats["unitsKilled"], Died: g.Stats["unitsDied"]}
	if s.Result == "" {
		s.Result = "unfinished"
	}
	if t := g.Stats["damageReceived"]; t > 0 {
		s.DealtTaken = g.Stats["damageDealt"] / t
	}
	for _, d := range g.Lost {
		switch d.Kind {
		case "constructor":
			s.BuildersLost++
		case "factory":
			s.LabsLost++
		}
	}
	return s
}

// pace is our median of a metric at a minute over the games that reached it with full eco lines.
func pace(games []*Game, minute int, metric string) (float64, int) {
	var v []float64
	for _, g := range games {
		e := At(g.Eco, minute)
		if e == nil || (e.Partial && metric != "metalIncome" && metric != "energyIncome") {
			continue
		}
		v = append(v, e.Value(metric))
	}
	return median(v), len(v)
}

// a sub-commander message that points at a problem
var reProblem = regexp.MustCompile(`(?i)gave up|couldn't|can't|cannot|destroyed|stuck|blocked|failed|no free|metal is short|^lost `)

// Findings lists the weaknesses of a set of games, against the benchmark when there is one.
func Findings(games []*Game, b *Benchmark) []Finding {
	var out []Finding
	n := float64(len(games))
	if n == 0 {
		return nil
	}
	// the widget crashed: BAR removed it and the game went on without sub-commanders; nothing else in
	// these games means anything until it's fixed
	crashed := 0
	for _, g := range games {
		if len(g.Crashed) > 0 {
			if crashed == 0 {
				out = append(out, Finding{10, "crash", "widget error: " + g.Crashed[0]})
			}
			crashed++
		}
	}
	if crashed > 0 {
		out = append(out, Finding{10, "crash", fmt.Sprintf("the Sub-Commanders widget crashed in %d of %d games: those results are invalid", crashed, len(games))})
	}
	// caught errors (sc_guard.lua): the step was skipped and the game ran on, but something didn't happen
	caught, first := 0, ""
	for _, g := range games {
		if len(g.Caught) > 0 {
			if caught == 0 {
				first = g.Caught[0]
			}
			caught++
		}
	}
	if caught > 0 {
		out = append(out, Finding{2, "widget-error", fmt.Sprintf("caught widget errors in %d of %d games (the step was skipped; make errors): %s", caught, len(games), first)})
	}
	// economy pace: the worst minute per metric, where we're below the strong players' lower quartile
	for _, m := range []string{"mex", "metalIncome", "factories", "builders", "army", "energyIncome"} {
		var worst *Finding
		for _, minute := range []int{5, 8, 12, 15} {
			band, ok := b.Band(minute, m)
			ours, have := pace(games, minute, m)
			if !ok || have == 0 || band.P50 <= 0 || ours >= band.P25 {
				continue
			}
			sev := (band.P25 - ours) / band.P50
			if worst == nil || sev > worst.Severity {
				worst = &Finding{Severity: sev, Area: "economy", Text: fmt.Sprintf("%s at %d min: %s, strong players %s-%s (median %s)",
					MetricNames[m], minute, fmtNum(ours), fmtNum(band.P25), fmtNum(band.P75), fmtNum(band.P50))}
			}
		}
		if worst != nil {
			if m == "army" {
				worst.Area = "army"
			}
			out = append(out, *worst)
		}
	}
	var builders, labs, commanders, early, lostGames, energyStall, overflow, dealt, taken float64
	for _, g := range games {
		s := Summarize(g)
		builders += float64(s.BuildersLost)
		labs += float64(s.LabsLost)
		for _, d := range g.Lost {
			if d.Kind == "commander" {
				commanders++
			}
			if d.Minute < 6 && d.Kind != "turret" {
				early += float64(d.Cost)
			}
		}
		if g.Result == "LOSS" {
			lostGames++
		}
		if len(g.Eco) > 0 {
			last := g.Eco[len(g.Eco)-1]
			energyStall += float64(last.EnergyStalled)
			overflow += float64(last.MetalOverflow)
		}
		dealt += g.Stats["damageDealt"]
		taken += g.Stats["damageReceived"]
	}
	if lostGames > 0 {
		out = append(out, Finding{lostGames / n, "results", fmt.Sprintf("lost %d of %d games", int(lostGames), len(games))})
	}
	if builders/n > 4 {
		out = append(out, Finding{builders / n / 15, "losses", fmt.Sprintf("%.1f constructors lost per game: protect them or keep them out of raid paths", builders/n)})
	}
	if labs/n > 0.3 {
		out = append(out, Finding{labs / n / 2, "losses", fmt.Sprintf("%.1f factories lost per game", labs/n)})
	}
	if commanders > 0 {
		out = append(out, Finding{commanders / n, "losses", fmt.Sprintf("commander died in %d of %d games", int(commanders), len(games))})
	}
	if early/n > 300 {
		out = append(out, Finding{early / n / 1500, "defense", fmt.Sprintf("%.0f metal of units and buildings lost before minute 6 per game (early raids)", early/n)})
	}
	if energyStall/n > 60 {
		out = append(out, Finding{energyStall / n / 300, "economy", fmt.Sprintf("energy near empty %.0f s per game", energyStall/n)})
	}
	if overflow/n > 60 {
		out = append(out, Finding{overflow / n / 300, "economy", fmt.Sprintf("metal storage full %.0f s per game (income wasted: more build power or factories)", overflow/n)})
	}
	if taken > 0 && dealt/taken < 1 {
		out = append(out, Finding{1 - dealt/taken, "army", fmt.Sprintf("damage dealt / taken %.2f: losing trades", dealt/taken)})
	}
	for _, p := range problems(games, 8) {
		if p.perGame >= 3 {
			out = append(out, Finding{p.perGame / 40, "sub-commanders", fmt.Sprintf("%q %.1f times per game", p.msg, p.perGame)})
		}
	}
	errs := 0
	for _, g := range games {
		errs += len(g.Errors)
	}
	if errs > 0 {
		out = append(out, Finding{2, "harness", fmt.Sprintf("%d harness errors (see the logs)", errs)})
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Severity > out[j].Severity })
	return out
}

type problem struct {
	msg     string
	perGame float64
}

// problems are the most frequent sub-commander messages that point at a problem.
func problems(games []*Game, limit int) []problem {
	counts := map[string]int{}
	for _, g := range games {
		for msg, c := range g.Logs {
			// with loss lines (newer harness) losses are counted from those
			if reProblem.MatchString(msg) && !(len(g.Lost) > 0 && strings.HasPrefix(msg, "lost ")) {
				counts[msg] += c
			}
		}
	}
	var out []problem
	for msg, c := range counts {
		out = append(out, problem{msg, float64(c) / float64(len(games))})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].perGame != out[j].perGame {
			return out[i].perGame > out[j].perGame
		}
		return out[i].msg < out[j].msg
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

func fmtNum(v float64) string {
	switch {
	case v >= 1000:
		return fmt.Sprintf("%.1fk", v/1000)
	case v == float64(int(v)):
		return fmt.Sprintf("%d", int(v))
	default:
		return fmt.Sprintf("%.1f", v)
	}
}

// Report writes a markdown report of a set of games.
func Report(w io.Writer, title string, games []*Game, b *Benchmark) {
	fmt.Fprintf(w, "# %s\n\n", title)
	fmt.Fprintln(w, "| Game | Result | Minutes | Metal | Killed / lost | Dealt / taken | Constructors lost | Factories lost |")
	fmt.Fprintln(w, "|---|---|---|---|---|---|---|---|")
	var metal, killed, died, ratio float64
	for _, g := range games {
		s := Summarize(g)
		fmt.Fprintf(w, "| %s | %s | %.0f | %s | %.0f / %.0f | %.2f | %d | %d |\n", s.Source, s.Result, s.Minutes, fmtNum(s.Metal), s.Killed, s.Died, s.DealtTaken, s.BuildersLost, s.LabsLost)
		metal += s.Metal
		killed += s.Killed
		died += s.Died
		ratio += s.DealtTaken
	}
	if n := float64(len(games)); n > 1 {
		fmt.Fprintf(w, "| **average** | %s | | %s | %.0f / %.0f | %.2f | | |\n", resultCounts(games), fmtNum(metal/n), killed/n, died/n, ratio/n)
	}

	fmt.Fprintln(w, "\n## Economy pace")
	if b != nil {
		fmt.Fprintf(w, "\nOurs (median over games) vs %s: lower quartile-upper quartile. `!` = below the lower quartile.\n\n", b.Description)
	} else {
		fmt.Fprintln(w, "\nOurs (median over games); no benchmark loaded.")
	}
	fmt.Fprint(w, "| Minute |")
	for _, m := range Metrics[:6] {
		fmt.Fprintf(w, " %s |", MetricNames[m])
	}
	fmt.Fprint(w, "\n|---|")
	for range Metrics[:6] {
		fmt.Fprint(w, "---|")
	}
	fmt.Fprintln(w)
	for _, minute := range PaceMinutes {
		var row strings.Builder
		fmt.Fprintf(&row, "| %d |", minute)
		any := false
		for _, m := range Metrics[:6] {
			ours, have := pace(games, minute, m)
			cell := "-"
			if have > 0 {
				any = true
				cell = fmtNum(ours)
			}
			if band, ok := b.Band(minute, m); ok {
				flag := ""
				if have > 0 && ours < band.P25 {
					flag = " !"
				}
				cell = fmt.Sprintf("%s%s (%s-%s)", cell, flag, fmtNum(band.P25), fmtNum(band.P75))
			}
			row.WriteString(" " + cell + " |")
		}
		if any {
			fmt.Fprintln(w, row.String())
		}
	}

	fmt.Fprintln(w, "\n## Losses by kind (per game)")
	fmt.Fprintln(w)
	type kindLoss struct {
		kind        string
		count, cost float64
	}
	byKind := map[string]*kindLoss{}
	for _, g := range games {
		for _, d := range g.Lost {
			k := byKind[d.Kind]
			if k == nil {
				k = &kindLoss{kind: d.Kind}
				byKind[d.Kind] = k
			}
			k.count++
			k.cost += float64(d.Cost)
		}
	}
	if len(byKind) == 0 {
		fmt.Fprintln(w, "No loss lines in these logs (older harness).")
	} else {
		var ks []*kindLoss
		for _, k := range byKind {
			ks = append(ks, k)
		}
		sort.Slice(ks, func(i, j int) bool { return ks[i].cost > ks[j].cost })
		n := float64(len(games))
		fmt.Fprintln(w, "| Kind | Units | Metal |")
		fmt.Fprintln(w, "|---|---|---|")
		for _, k := range ks {
			fmt.Fprintf(w, "| %s | %.1f | %s |\n", k.kind, k.count/n, fmtNum(k.cost/n))
		}
	}

	if len(byKind) > 0 {
		fmt.Fprintln(w, "\n## Trades by phase (metal per game)")
		fmt.Fprintln(w)
		fmt.Fprintln(w, "| Phase | Lost | Killed | Killed / lost |")
		fmt.Fprintln(w, "|---|---|---|---|")
		n := float64(len(games))
		for _, ph := range phases {
			var lost, killed float64
			for _, g := range games {
				for _, d := range g.Lost {
					if d.Minute >= ph.from && d.Minute < ph.to {
						lost += float64(d.Cost)
					}
				}
				for _, d := range g.Killed {
					if d.Minute >= ph.from && d.Minute < ph.to {
						killed += float64(d.Cost)
					}
				}
			}
			ratio := "-"
			if lost > 0 {
				ratio = fmt.Sprintf("%.2f", killed/lost)
			}
			fmt.Fprintf(w, "| %s | %s | %s | %s |\n", ph.label, fmtNum(lost/n), fmtNum(killed/n), ratio)
		}
	}

	FeatureTable(w, []Arm{{Label: "these games", Games: games}})

	if ps := problems(games, 10); len(ps) > 0 {
		fmt.Fprintln(w, "\n## Sub-commanders' recurring problems (per game)")
		fmt.Fprintln(w)
		for _, p := range ps {
			fmt.Fprintf(w, "- %.1f× %s\n", p.perGame, p.msg)
		}
	}

	fmt.Fprintln(w, "\n## Findings, most severe first")
	fmt.Fprintln(w)
	fs := Findings(games, b)
	if len(fs) == 0 {
		fmt.Fprintln(w, "Nothing stands out.")
	}
	for i, f := range fs {
		fmt.Fprintf(w, "%d. [%s, %.2f] %s\n", i+1, f.Area, f.Severity, f.Text)
	}
}

func resultCounts(games []*Game) string {
	c := map[string]int{}
	for _, g := range games {
		r := g.Result
		if r == "" {
			r = "unfinished"
		}
		c[r]++
	}
	var parts []string
	for _, r := range []string{"WIN", "TIMEOUT", "LOSS", "unfinished"} {
		if c[r] > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", c[r], strings.ToLower(r)))
		}
	}
	return strings.Join(parts, ", ")
}

// Arm is a labelled set of games (an A/B test arm).
type Arm struct {
	Label string
	Games []*Game
}

// Compare writes a side-by-side table of test arms.
func Compare(w io.Writer, arms []Arm) {
	// extractors at 8 and 20 minutes: the opening, and whether expansion holds (v24: Cortex had more than
	// Legion at 15 and half as many at 20, raided down)
	fmt.Fprintln(w, "| Arm | Games | Results | Lost by 25 min | Metal | Killed / lost | Dealt / taken | Constructors lost | Extractors at 8 / 20 min | Army at 12 min |")
	fmt.Fprintln(w, "|---|---|---|---|---|---|---|---|---|---|")
	for _, a := range arms {
		var metal, killed, died, dealt, taken, builders float64
		lost25 := 0
		for _, g := range a.Games {
			s := Summarize(g)
			// comparable across game lengths (older arms ran 25 minutes)
			if g.Result == "LOSS" && g.Seconds <= 25*60 {
				lost25++
			}
			metal += s.Metal
			killed += s.Killed
			died += s.Died
			dealt += g.Stats["damageDealt"]
			taken += g.Stats["damageReceived"]
			builders += float64(s.BuildersLost)
		}
		n := float64(len(a.Games))
		if n == 0 {
			continue
		}
		ratio := 0.0
		if taken > 0 {
			ratio = dealt / taken
		}
		mex, haveMex := pace(a.Games, 8, "mex")
		mex20, haveMex20 := pace(a.Games, 20, "mex")
		army, haveArmy := pace(a.Games, 12, "army")
		cell := func(v float64, have int) string {
			if have == 0 {
				return "-"
			}
			return fmtNum(v)
		}
		fmt.Fprintf(w, "| %s | %d | %s | %d | %s | %.0f / %.0f | %.2f | %.1f | %s | %s |\n", a.Label, len(a.Games), resultCounts(a.Games), lost25,
			fmtNum(metal/n), killed/n, died/n, ratio, builders/n, cell(mex, haveMex)+" / "+cell(mex20, haveMex20), cell(army, haveArmy))
	}
	FeatureTable(w, arms)
}
