package analysis

import (
	"fmt"
	"sort"
	"strings"
)

// The report and a game's timeline as data, for agents (gamereport -json, -timeline). The markdown
// report (Report) shows the same numbers.

// ReportData is a batch's report as structured data.
type ReportData struct {
	Title    string             `json:"title"`
	Games    []GameSummary      `json:"games"`
	Pace     []PaceRow          `json:"pace"`
	Losses   []KindLoss         `json:"lossesPerGame"`
	Trades   []PhaseTrade       `json:"tradesPerGame"`
	Problems []ProblemCount     `json:"recurringProblemsPerGame"`
	Findings []Finding          `json:"findings"`
	Averages map[string]float64 `json:"averages"`
}

// GameSummary is one game's headline numbers.
type GameSummary struct {
	Game             string  `json:"game"`
	Result           string  `json:"result"`
	Minutes          float64 `json:"minutes"`
	Metal            float64 `json:"metal"`
	Killed           float64 `json:"killed"`
	Lost             float64 `json:"lost"`
	DealtTaken       float64 `json:"dealtTaken"`
	ConstructorsLost int     `json:"constructorsLost"`
	FactoriesLost    int     `json:"factoriesLost"`
	CommanderDied    bool    `json:"commanderDied"`
}

// PaceRow is our median of each metric at a minute, with the benchmark's band.
type PaceRow struct {
	Minute  int                  `json:"minute"`
	Metrics map[string]PaceValue `json:"metrics"`
}

// PaceValue is ours against strong players' quartiles (zero when unknown).
type PaceValue struct {
	Ours  float64 `json:"ours"`
	Games int     `json:"games"`
	P25   float64 `json:"p25,omitempty"`
	P50   float64 `json:"p50,omitempty"`
	P75   float64 `json:"p75,omitempty"`
	Below bool    `json:"belowStrongPlayers,omitempty"`
}

// KindLoss is units and metal lost per game of a kind.
type KindLoss struct {
	Kind  string  `json:"kind"`
	Units float64 `json:"units"`
	Metal float64 `json:"metal"`
}

// PhaseTrade is metal lost and killed per game in a phase of the game.
type PhaseTrade struct {
	Phase  string  `json:"phase"`
	Lost   float64 `json:"lost"`
	Killed float64 `json:"killed"`
}

// ProblemCount is a recurring sub-commander problem message and how often it appears per game.
type ProblemCount struct {
	Message string  `json:"message"`
	PerGame float64 `json:"perGame"`
}

// BuildReport computes the report's numbers.
func BuildReport(title string, games []*Game, b *Benchmark) ReportData {
	r := ReportData{Title: title, Averages: map[string]float64{}}
	n := float64(len(games))
	var dealt, taken float64
	for _, g := range games {
		s := Summarize(g)
		gs := GameSummary{Game: s.Source, Result: s.Result, Minutes: s.Minutes, Metal: s.Metal, Killed: s.Killed, Lost: s.Died,
			DealtTaken: round2(s.DealtTaken), ConstructorsLost: s.BuildersLost, FactoriesLost: s.LabsLost}
		for _, d := range g.Lost {
			gs.CommanderDied = gs.CommanderDied || d.Kind == "commander"
		}
		r.Games = append(r.Games, gs)
		r.Averages["metal"] += s.Metal / n
		r.Averages["killed"] += s.Killed / n
		r.Averages["lost"] += s.Died / n
		r.Averages["constructorsLost"] += float64(s.BuildersLost) / n
		if g.Result == "LOSS" {
			r.Averages["lossRate"] += 1 / n
		}
		dealt += g.Stats["damageDealt"]
		taken += g.Stats["damageReceived"]
	}
	if taken > 0 {
		r.Averages["dealtTaken"] = round2(dealt / taken)
	}
	for _, minute := range PaceMinutes {
		row := PaceRow{Minute: minute, Metrics: map[string]PaceValue{}}
		for _, m := range Metrics[:6] {
			ours, have := pace(games, minute, m)
			v := PaceValue{Ours: ours, Games: have}
			if band, ok := b.Band(minute, m); ok {
				v.P25, v.P50, v.P75 = band.P25, band.P50, band.P75
				v.Below = have > 0 && ours < band.P25
			}
			if have > 0 || v.P50 > 0 {
				row.Metrics[m] = v
			}
		}
		if len(row.Metrics) > 0 {
			r.Pace = append(r.Pace, row)
		}
	}
	kinds := map[string]*KindLoss{}
	for _, g := range games {
		for _, d := range g.Lost {
			k := kinds[d.Kind]
			if k == nil {
				k = &KindLoss{Kind: d.Kind}
				kinds[d.Kind] = k
			}
			k.Units += 1 / n
			k.Metal += float64(d.Cost) / n
		}
	}
	for _, k := range kinds {
		k.Units, k.Metal = round2(k.Units), round2(k.Metal)
		r.Losses = append(r.Losses, *k)
	}
	sort.Slice(r.Losses, func(i, j int) bool { return r.Losses[i].Metal > r.Losses[j].Metal })
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
		r.Trades = append(r.Trades, PhaseTrade{Phase: ph.label, Lost: round2(lost / n), Killed: round2(killed / n)})
	}
	for _, p := range problems(games, 10) {
		r.Problems = append(r.Problems, ProblemCount{Message: p.msg, PerGame: round2(p.perGame)})
	}
	r.Findings = Findings(games, b)
	for i := range r.Findings {
		r.Findings[i].Severity = round2(r.Findings[i].Severity)
	}
	return r
}

func round2(v float64) float64 {
	return float64(int(v*100+0.5)) / 100
}

// Minute is one minute of a game's timeline.
type Minute struct {
	Minute      int            `json:"minute"`
	Eco         *Eco           `json:"eco,omitempty"`
	Lost        map[string]int `json:"lost,omitempty"`   // kind -> units we lost this minute
	Killed      map[string]int `json:"killed,omitempty"` // kind -> enemy units that died in view
	LostMetal   int            `json:"lostMetal,omitempty"`
	KilledMetal int            `json:"killedMetal,omitempty"`
	Events      []Event        `json:"events,omitempty"` // decisions and the player's actions (squad, raid, factory, ...)
}

// timelineWorthy: the sub-commander messages that explain a game (decisions and alarms), not the
// routine build log
func timelineWorthy(e Event) bool {
	if e.Sub == "player" {
		return true
	}
	for _, p := range []string{"engaging", "regrouping", "holding", "falling back", "raid:", "pushing", "push called off",
		"destroyed", "commander pulled back", "constructor pulled back", "covering", "tuned", "autonomy", "raids ",
		"another factory", "our first factory", "is being built for me", "gave up", "metal is overflowing"} {
		if strings.Contains(e.Text, p) {
			return true
		}
	}
	return strings.HasPrefix(e.Text, "AI:")
}

// Timeline lays a game out minute by minute: economy, losses and kills by kind, and the decisions.
func Timeline(g *Game) []Minute {
	byMin := map[int]*Minute{}
	get := func(m int) *Minute {
		if byMin[m] == nil {
			byMin[m] = &Minute{Minute: m}
		}
		return byMin[m]
	}
	for i := range g.Eco {
		e := g.Eco[i]
		get(e.Minute).Eco = &e
	}
	for _, d := range g.Lost {
		m := get(d.Minute)
		if m.Lost == nil {
			m.Lost = map[string]int{}
		}
		m.Lost[d.Kind]++
		m.LostMetal += d.Cost
	}
	for _, d := range g.Killed {
		m := get(d.Minute)
		if m.Killed == nil {
			m.Killed = map[string]int{}
		}
		m.Killed[d.Kind]++
		m.KilledMetal += d.Cost
	}
	for _, e := range g.Events {
		if timelineWorthy(e) {
			m := get(e.Second / 60)
			m.Events = append(m.Events, e)
		}
	}
	var out []Minute
	for _, m := range byMin {
		out = append(out, *m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Minute < out[j].Minute })
	return out
}

// "3 economy, 1 raider", most first
func kindList(m map[string]int) string {
	type kv struct {
		k string
		v int
	}
	var list []kv
	for k, v := range m {
		list = append(list, kv{k, v})
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].v != list[j].v {
			return list[i].v > list[j].v
		}
		return list[i].k < list[j].k
	})
	var parts []string
	for _, e := range list {
		parts = append(parts, fmt.Sprintf("%d %s", e.v, e.k))
	}
	return strings.Join(parts, ", ")
}

// TimelineText renders a timeline compactly, one block per minute.
func TimelineText(g *Game) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s: %s %s at %d:%02d\n", g.Source, g.Result, g.Detail, g.Seconds/60, g.Seconds%60)
	for _, m := range Timeline(g) {
		fmt.Fprintf(&b, "%2d min", m.Minute)
		if m.Eco != nil {
			fmt.Fprintf(&b, " | metal +%.1f energy +%.0f mex %d factories %d builders %d army %s turrets %s",
				m.Eco.MetalIncome, m.Eco.EnergyIncome, m.Eco.Mex, m.Eco.Factories, m.Eco.Builders, fmtNum(m.Eco.Army), fmtNum(m.Eco.Turrets))
		}
		if m.LostMetal > 0 || m.KilledMetal > 0 {
			fmt.Fprintf(&b, " | lost %d metal (%s) | killed %d metal (%s)", m.LostMetal, kindList(m.Lost), m.KilledMetal, kindList(m.Killed))
		}
		b.WriteString("\n")
		for _, e := range m.Events {
			fmt.Fprintf(&b, "       %d:%02d %s: %s\n", e.Second/60, e.Second%60, e.Sub, e.Text)
		}
	}
	return b.String()
}
