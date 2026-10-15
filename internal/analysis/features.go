package analysis

import (
	"fmt"
	"io"
	"sort"
)

// FeatureStats is how one of our features (firebases, long-range cannons, nukes, anti-nukes, shields,
// Juno, resurrection) did across a set of games, judged on its own rather than by the games' results:
// what it cost, what it killed, what of it was lost. From the harness's "features" ledger and the
// feature= tags on "killed" / "lost" lines.
type FeatureStats struct {
	Name   string  `json:"name"`
	Games  int     `json:"games"`  // games where we built it (or it raised something)
	Spent  float64 `json:"spent"`  // metal spent on it per game it was used in (rez: metal raised)
	Count  float64 `json:"count"`  // structures / units per game it was used in
	Killed float64 `json:"killed"` // enemy metal it killed per game it was used in
	KillsN float64 `json:"kills"`  // enemy units it killed per game
	Lost   float64 `json:"lost"`   // metal of it we lost per game it was used in
}

// Return is enemy metal killed per metal spent (for rez: metal raised per metal of bots, see Raised).
func (f FeatureStats) Return() float64 {
	if f.Spent <= 0 {
		return 0
	}
	return f.Killed / f.Spent
}

// Features: per-feature stats over the games (only games that used the feature count in its averages).
func Features(games []*Game) []FeatureStats {
	type acc struct {
		games                         map[*Game]bool
		spent, count, killed, n, lost float64
	}
	by := map[string]*acc{}
	get := func(name string) *acc {
		a := by[name]
		if a == nil {
			a = &acc{games: map[*Game]bool{}}
			by[name] = a
		}
		return a
	}
	for _, g := range games {
		for name, l := range g.Features {
			a := get(name)
			a.games[g] = true
			a.spent += l.Metal
			a.count += float64(l.Count)
		}
		for _, d := range g.Killed {
			if d.Feature != "" {
				a := get(d.Feature)
				a.games[g] = true
				a.killed += float64(d.Cost)
				a.n++
			}
		}
		for _, d := range g.Lost {
			if d.Feature != "" {
				a := get(d.Feature)
				a.games[g] = true
				a.lost += float64(d.Cost)
			}
		}
	}
	var out []FeatureStats
	for name, a := range by {
		n := float64(len(a.games))
		out = append(out, FeatureStats{Name: name, Games: len(a.games), Spent: a.spent / n, Count: a.count / n,
			Killed: a.killed / n, KillsN: a.n / n, Lost: a.lost / n})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Spent+out[i].Killed > out[j].Spent+out[j].Killed })
	return out
}

// FeatureTable writes each feature's own account per arm: games used, metal spent (rez: raised),
// enemy metal it killed, its losses, and killed per metal spent.
func FeatureTable(w io.Writer, arms []Arm) {
	type row struct {
		arm string
		f   FeatureStats
	}
	var rows []row
	for _, a := range arms {
		for _, f := range Features(a.Games) {
			rows = append(rows, row{a.Label, f})
		}
	}
	if len(rows) == 0 {
		return
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].f.Name < rows[j].f.Name })
	fmt.Fprintln(w, "\n## Features, each on its own (per game it was used in)")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "Spent: metal of its structures (rez: metal raised from wrecks; rezbot: the bots). Killed: enemy metal its")
	fmt.Fprintln(w, "units killed. Lost: metal of it destroyed. Return: killed per metal spent.")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "| Feature | Arm | Games | Built | Spent | Killed (units) | Lost | Return |")
	fmt.Fprintln(w, "|---|---|---|---|---|---|---|---|")
	for _, r := range rows {
		ret := "-"
		if r.f.Spent > 0 && r.f.Name != "rez" {
			ret = fmt.Sprintf("%.2f", r.f.Return())
		}
		fmt.Fprintf(w, "| %s | %s | %d of %d | %.1f | %s | %s (%.1f) | %s | %s |\n", r.f.Name, r.arm, r.f.Games, armGames(arms, r.arm),
			r.f.Count, fmtNum(r.f.Spent), fmtNum(r.f.Killed), r.f.KillsN, fmtNum(r.f.Lost), ret)
	}
}

func armGames(arms []Arm, label string) int {
	for _, a := range arms {
		if a.Label == label {
			return len(a.Games)
		}
	}
	return 0
}
