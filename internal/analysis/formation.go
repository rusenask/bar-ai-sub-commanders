package analysis

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
)

// Formation: how a group stands when it fights, and what that does to the trade, from the data logger's
// fight samples (v8+: ownForm / enemyForm). Set strong players' fights against ours and BARbarian's to
// find what makes them trade even when outmatched.

// Form is one side's formation at a fight's start (zz_datalog.lua formation()).
type Form struct {
	Spread  float64 `json:"spread"`  // value-weighted RMS distance from the group's centre
	Width   float64 `json:"width"`   // RMS across the line to the enemy
	Depth   float64 `json:"depth"`   // RMS along it
	InRange float64 `json:"inRange"` // share of units with an enemy within their own range
	Exposed float64 `json:"exposed"` // share within an enemy weapon's range
	N       int     `json:"n"`
}

// FormSample is one fight's start, both sides.
type FormSample struct {
	Team         int        `json:"team"`
	Own          commitSide `json:"own"`
	OwnTurrets   commitSide `json:"ownTurrets"`
	Enemy        commitSide `json:"enemy"`
	EnemyTurrets commitSide `json:"enemyTurrets"`
	OwnForm      *Form      `json:"ownForm"`
	EnemyForm    *Form      `json:"enemyForm"`
	OwnApproach  float64    `json:"ownApproach"`
	OwnLost      float64    `json:"ownLost"`
	EnemyLost    float64    `json:"enemyLost"`
}

// Ratio is our side's value over theirs, turrets included.
func (f FormSample) Ratio() float64 {
	return (f.Own.Value + f.OwnTurrets.Value) / math.Max(f.Enemy.Value+f.EnemyTurrets.Value, 1)
}

// Advantage: our share of units able to shoot minus theirs.
func (f FormSample) Advantage() float64 { return f.OwnForm.InRange - f.EnemyForm.InRange }

// ReadFormation reads the v8+ fight samples of every JSONL file in dir (team >= 0: only that team's).
func ReadFormation(dir string, team int) ([]FormSample, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.jsonl"))
	if err != nil {
		return nil, err
	}
	var out []FormSample
	for _, f := range files {
		fh, err := os.Open(f)
		if err != nil {
			return nil, err
		}
		s, err := parseFormation(fh, team)
		fh.Close()
		if err != nil {
			return nil, fmt.Errorf("%s: %w", f, err)
		}
		out = append(out, s...)
	}
	return out, nil
}

func parseFormation(r io.Reader, team int) ([]FormSample, error) {
	var out []FormSample
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1<<20), 1<<22)
	for sc.Scan() {
		line := sc.Bytes()
		if !strings.Contains(string(line), `"type":"fight"`) || !strings.Contains(string(line), `"ownForm"`) {
			continue
		}
		var f FormSample
		if json.Unmarshal(line, &f) != nil || f.OwnForm == nil || f.EnemyForm == nil || f.OwnForm.N < 3 || f.EnemyForm.N < 1 {
			continue
		}
		if team >= 0 && f.Team != team {
			continue
		}
		out = append(out, f)
	}
	return out, sc.Err()
}

// trade: their value lost over ours, pooled
func trade(fs []FormSample) float64 {
	var own, enemy float64
	for _, f := range fs {
		own += f.OwnLost
		enemy += f.EnemyLost
	}
	return enemy / math.Max(own, 1)
}


// FormationProfile: medians of a set of fights' formations (even fights: ratio 0.67-1.5) and their trade.
func FormationProfile(label string, fs []FormSample) string {
	var even []FormSample
	for _, f := range fs {
		if r := f.Ratio(); r >= 0.67 && r < 1.5 {
			even = append(even, f)
		}
	}
	col := func(get func(FormSample) float64) float64 {
		var v []float64
		for _, f := range even {
			v = append(v, get(f))
		}
		return microQ(v, 0.5)
	}
	return fmt.Sprintf("| %s | %d / %d | %.2f | %.2f | %.2f | %.0f | %.0f | %.2f | %.2f | %.2f |\n", label, len(even), len(fs),
		col(func(f FormSample) float64 { return f.OwnForm.InRange }),
		col(func(f FormSample) float64 { return f.OwnForm.Exposed }),
		col(func(f FormSample) float64 { return f.Advantage() }),
		col(func(f FormSample) float64 { return f.OwnForm.Spread / math.Sqrt(float64(f.OwnForm.N)) }),
		col(func(f FormSample) float64 { return f.OwnForm.Spread }),
		col(func(f FormSample) float64 { return f.OwnForm.Width / math.Max(f.OwnForm.Depth, 1) }),
		col(func(f FormSample) float64 { return f.OwnApproach }),
		trade(even))
}

// FormationProfileHeader is the table header for FormationProfile rows.
const FormationProfileHeader = "| Who | Even fights / all | Units able to shoot | Units exposed | Shooting advantage (ours - theirs) | Spread per sqrt(units) | Spread | Width / depth | Approach | Trade |\n|---|---|---|---|---|---|---|---|---|---|\n"

// FormationBins: the trade by a feature's bins (bounds), fights at any ratio, with the median ratio in
// each bin so a feature that only tracks strength shows itself.
func FormationBins(fs []FormSample, name string, get func(FormSample) float64, bounds []float64) string {
	var s strings.Builder
	fmt.Fprintf(&s, "| %s | Fights | Median ratio | Trade |\n|---|---|---|---|\n", name)
	for i := 0; i+1 < len(bounds); i++ {
		var in []FormSample
		var ratios []float64
		for _, f := range fs {
			if v := get(f); v >= bounds[i] && v < bounds[i+1] {
				in = append(in, f)
				ratios = append(ratios, f.Ratio())
			}
		}
		hi := fmt.Sprintf("%.2g", bounds[i+1])
		if math.IsInf(bounds[i+1], 1) {
			hi = "up"
		}
		fmt.Fprintf(&s, "| %.2g-%s | %d | %.2f | %.2f |\n", bounds[i], hi, len(in), microQ(ratios, 0.5), trade(in))
	}
	return s.String()
}
