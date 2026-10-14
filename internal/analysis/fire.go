package analysis

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Fire: how a team's units in contact split their fire, from the data logger's "fire" samples (v6+): per
// target, how many shoot it and their dps against its health, and how many units hold a set target (BAR's
// target-on-the-move, the players' focus-fire tool). The fire control's killTime / overkill (sc_doctrine.lua
// D.micro.focus) are judged against these.

// FireTarget is one enemy unit being shot at one moment.
type FireTarget struct {
	HP     float64 `json:"hp"`
	MaxHP  float64 `json:"maxHp"`
	Cost   float64 `json:"cost"`
	Armed  bool    `json:"armed"`
	Mobile bool    `json:"mobile"`
	N      int     `json:"n"`   // units shooting it
	DPS    float64 `json:"dps"` // their dps together
	Set    int     `json:"set"` // of them, with it as their set target
}

// FireSample is one team's fire in one scan.
type FireSample struct {
	Contact   int          `json:"contact"`   // armed units within 1.2x range of an armed enemy
	Shooting  int          `json:"shooting"`  // of them, with a unit target
	SetTarget int          `json:"setTarget"` // of them, holding a set target
	Targets   []FireTarget `json:"targets"`
}

// ReadFire reads the fire samples of every JSONL file in dir.
func ReadFire(dir string) ([]FireSample, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.jsonl"))
	if err != nil {
		return nil, err
	}
	var out []FireSample
	for _, f := range files {
		fh, err := os.Open(f)
		if err != nil {
			return nil, err
		}
		s, err := parseFire(fh)
		fh.Close()
		if err != nil {
			return nil, fmt.Errorf("%s: %w", f, err)
		}
		out = append(out, s...)
	}
	return out, nil
}

func parseFire(r io.Reader) ([]FireSample, error) {
	var out []FireSample
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1<<20), 1<<22)
	for sc.Scan() {
		line := sc.Bytes()
		if !strings.Contains(string(line), `"type":"fire"`) {
			continue
		}
		var f FireSample
		if json.Unmarshal(line, &f) == nil {
			out = append(out, f)
		}
	}
	return out, sc.Err()
}

// FireStats sums up fire samples. Coverage of a target = its shooters' dps x killTime / its health: over
// `over` it is overkill (the shots beyond what kills it are wasted).
type FireStats struct {
	Samples        int     `json:"samples"`
	Contact        int     `json:"contact"`
	SetTargetShare float64 `json:"setTargetShare"` // units in contact holding a set target
	ShootingShare  float64 `json:"shootingShare"`  // units in contact shooting a unit
	ShootersPerTgt float64 `json:"shootersPerTarget"`
	// SoloShare: shots at a target nobody else shoots; Top3Share: shots at the 3 most-shot targets of the scan
	SoloShare float64 `json:"soloShare"`
	Top3Share float64 `json:"top3Share"`
	// CoverageMedian: median coverage (shot-weighted) at killTime; OverShare: shots at targets covered
	// more than `over`
	CoverageMedian float64 `json:"coverageMedian"`
	OverShare      float64 `json:"overShare"`
	// OverShareSet: the same for shots from set targets alone (what players chose)
	OverShareSet float64 `json:"overShareSet"`
	ArmedShare   float64 `json:"armedShare"` // shots at armed targets
}

// FireSummary computes FireStats at a kill window (seconds) and overkill threshold.
func FireSummary(samples []FireSample, killTime, over float64) FireStats {
	st := FireStats{Samples: len(samples)}
	var shooting, set, targets, shots, solo, top3, overShots, setShots, overSet, armed int
	var cov []float64
	for _, s := range samples {
		st.Contact += s.Contact
		shooting += s.Shooting
		set += s.SetTarget
		ns := make([]int, 0, len(s.Targets))
		for _, t := range s.Targets {
			if t.N <= 0 {
				continue
			}
			targets++
			shots += t.N
			ns = append(ns, t.N)
			if t.N == 1 {
				solo++
			}
			if t.Armed {
				armed += t.N
			}
			c := t.DPS * killTime / max(t.HP, 1)
			for range t.N {
				cov = append(cov, c)
			}
			if c > over {
				overShots += t.N
				overSet += t.Set
			}
			setShots += t.Set
		}
		// the three most-shot targets
		for k := 0; k < 3 && len(ns) > 0; k++ {
			bi := 0
			for i, n := range ns {
				if n > ns[bi] {
					bi = i
				}
			}
			top3 += ns[bi]
			ns = append(ns[:bi], ns[bi+1:]...)
		}
	}
	frac := func(a, b int) float64 {
		if b == 0 {
			return 0
		}
		return float64(a) / float64(b)
	}
	st.SetTargetShare = frac(set, st.Contact)
	st.ShootingShare = frac(shooting, st.Contact)
	st.ShootersPerTgt = frac(shots, targets)
	st.SoloShare = frac(solo, shots)
	st.Top3Share = frac(top3, shots)
	st.OverShare = frac(overShots, shots)
	st.OverShareSet = frac(overSet, setShots)
	st.ArmedShare = frac(armed, shots)
	if len(cov) > 0 {
		st.CoverageMedian = microQ(cov, 0.5)
	}
	return st
}

// FireText renders fire stats.
func FireText(s FireStats, killTime, over float64) string {
	return fmt.Sprintf(`Fire (%d scans, %d unit-moments in contact):
- holding a set target: %.1f%%; shooting a unit: %.0f%%
- shooters per target: %.2f; shots at a target alone: %.0f%%; at the scan's 3 most-shot targets: %.0f%%
- coverage (dps x %gs / health), shot-weighted median: %.2f; shots at targets covered over %.1fx: %.0f%% (set targets: %.0f%%)
- shots at armed targets: %.0f%%
`, s.Samples, s.Contact, 100*s.SetTargetShare, 100*s.ShootingShare, s.ShootersPerTgt, 100*s.SoloShare, 100*s.Top3Share,
		killTime, s.CoverageMedian, over, 100*s.OverShare, 100*s.OverShareSet, 100*s.ArmedShare)
}
