package analysis

import (
	"fmt"
	"io"
	"math"
	"sort"
	"strconv"
	"strings"
)

// Battles: one engagement in isolation (the harness's battle scenario, testenv/battles/): our Army
// sub-commander against an army that stands and fights back. What they measure is micro: targeting,
// focus fire, approach, kiting, retreats.

// Battle is one engagement's outcome.
type Battle struct {
	Spec      string  `json:"spec"`
	Result    string  `json:"result"` // WIN, LOSS, DRAW
	Seconds   float64 `json:"seconds"`
	UsStart   float64 `json:"usStart"`
	UsLeft    float64 `json:"usLeft"`
	ThemStart float64 `json:"themStart"`
	ThemLeft  float64 `json:"themLeft"`
}

func parseBattle(s string) *Battle {
	kv := map[string]string{}
	for _, f := range strings.Fields(s) {
		if k, v, ok := strings.Cut(f, "="); ok {
			kv[k] = v
		}
	}
	num := func(k string) float64 { v, _ := strconv.ParseFloat(kv[k], 64); return v }
	return &Battle{Spec: kv["spec"], Result: kv["result"], Seconds: num("seconds"), UsStart: num("us_start"), UsLeft: num("us_left"),
		ThemStart: num("them_start"), ThemLeft: num("them_left")}
}

// Efficiency: the share of their army destroyed over the share of ours lost (2 = we traded twice as
// well; fair when the armies' values differ). A lossless win counts as 8.
func (b *Battle) Efficiency() float64 {
	if b.UsStart <= 0 || b.ThemStart <= 0 {
		return 0
	}
	them := (b.ThemStart - b.ThemLeft) / b.ThemStart
	us := (b.UsStart - b.UsLeft) / b.UsStart
	if us <= 0.01 && them <= 0.01 {
		return 1 // nobody lost anything (a strike called off): even
	}
	if us <= 0.01 {
		return 8
	}
	return math.Min(8, them/us)
}

// BattlesText: per spec, battles, wins, mean efficiency (geometric), our and their share lost, seconds.
func BattlesText(w io.Writer, games []*Game) {
	by := map[string][]*Battle{}
	for _, g := range games {
		if g.Battle != nil {
			by[g.Battle.Spec] = append(by[g.Battle.Spec], g.Battle)
		}
	}
	specs := make([]string, 0, len(by))
	for s := range by {
		specs = append(specs, s)
	}
	sort.Strings(specs)
	fmt.Fprintln(w, "| Spec | Battles | Won / drawn / lost | Efficiency (geomean) | Our share lost | Their share lost | Seconds |")
	fmt.Fprintln(w, "|---|---|---|---|---|---|---|")
	for _, s := range specs {
		bs := by[s]
		var won, drawn, lost int
		var logEff, usLost, themLost, secs float64
		for _, b := range bs {
			switch b.Result {
			case "WIN":
				won++
			case "LOSS":
				lost++
			default:
				drawn++
			}
			logEff += math.Log2(math.Max(b.Efficiency(), 0.125))
			usLost += (b.UsStart - b.UsLeft) / b.UsStart
			themLost += (b.ThemStart - b.ThemLeft) / b.ThemStart
			secs += b.Seconds
		}
		n := float64(len(bs))
		fmt.Fprintf(w, "| %s | %d | %d / %d / %d | %.2f | %.0f%% | %.0f%% | %.0f |\n", s, len(bs), won, drawn, lost,
			math.Pow(2, logEff/n), 100*usLost/n, 100*themLost/n, secs/n)
	}
}
