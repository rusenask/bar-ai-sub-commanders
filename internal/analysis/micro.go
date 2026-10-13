package analysis

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Micro: how strong players' combat units move and shoot near enemies, by kind, from the data logger's
// "micro" samples (testenv/force-replays.sh). The per-kind doctrine of sc_micro.lua (hold, kite, siege,
// behind) and the retreat health come from these.

// MicroSample is one combat unit near an armed enemy at one moment.
type MicroSample struct {
	Name     string  `json:"name"`
	Kind     string  `json:"kind"`
	Tech     int     `json:"tech"`
	Range    float64 `json:"range"`
	Dist     float64 `json:"dist"`
	ERange   float64 `json:"eRange"`
	EKind    string  `json:"eKind"`
	EStatic  bool    `json:"eStatic"`
	Approach float64 `json:"approach"` // toward (+1) or away from (-1) the enemy, share of top speed
	HP       float64 `json:"hp"`
	Firing   bool    `json:"firing"`
	TStatic  *bool   `json:"tStatic"` // its weapon's unit target is a structure (nil: no unit target)
	Ahead    float64 `json:"ahead"`   // elmos ahead (+) or behind (-) its group, toward the enemy
	Group    int     `json:"group"`
}

// MicroKind sums up one kind of unit.
type MicroKind struct {
	Kind    string `json:"kind"`
	Samples int    `json:"samples"`
	// Firing: share of samples that fired within their reload time
	Firing float64 `json:"firing"`
	// Hold: distance to the nearest enemy over its own range while firing and not moving much (median,
	// quartiles): where it fights from
	Hold    float64 `json:"hold"`
	HoldP25 float64 `json:"holdP25"`
	HoldP75 float64 `json:"holdP75"`
	// Kite: of samples with an enemy it outranges within 70% of its range, the share backing off
	Kite float64 `json:"kite"`
	// KiteAt: distance over range when backing off from enemies it outranges (median)
	KiteAt float64 `json:"kiteAt"`
	// Close: of samples where the enemy outranges it, the share closing in
	Close float64 `json:"close"`
	// Ahead: elmos ahead (+) or behind (-) of its group toward the enemy (median, groups of 3+)
	Ahead float64 `json:"ahead"`
	// Siege: of firing samples with a unit target, the share shooting at structures, and how often a
	// structure was the nearest enemy (to compare: a siege unit picks structures more than it meets them)
	Siege       float64 `json:"siege"`
	StaticNear  float64 `json:"staticNear"`
	RetreatHP   float64 `json:"retreatHP"` // median health of samples moving away without firing
	RetreatRate float64 `json:"retreatRate"`
}

// ReadMicro reads the micro samples of every JSONL file in dir.
func ReadMicro(dir string) ([]MicroSample, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.jsonl"))
	if err != nil {
		return nil, err
	}
	var out []MicroSample
	for _, f := range files {
		fh, err := os.Open(f)
		if err != nil {
			return nil, err
		}
		s, err := parseMicro(fh)
		fh.Close()
		if err != nil {
			return nil, fmt.Errorf("%s: %w", f, err)
		}
		out = append(out, s...)
	}
	return out, nil
}

func parseMicro(r io.Reader) ([]MicroSample, error) {
	var out []MicroSample
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1<<20), 1<<22)
	for sc.Scan() {
		line := sc.Bytes()
		if !strings.Contains(string(line[:min(len(line), 40)]), `"micro"`) {
			continue
		}
		var m MicroSample
		if err := json.Unmarshal(line, &m); err != nil {
			continue
		}
		m.Kind = strings.TrimPrefix(m.Kind, "hover ")
		out = append(out, m)
	}
	return out, sc.Err()
}

// microQ: the q quantile of unsorted values, unrounded (benchmark.go's quantile rounds to 0.1)
func microQ(v []float64, q float64) float64 {
	if len(v) == 0 {
		return 0
	}
	s := append([]float64(nil), v...)
	sort.Float64s(s)
	return s[int(q*float64(len(s)-1)+0.5)]
}

func share(n, of int) float64 {
	if of == 0 {
		return 0
	}
	return float64(n) / float64(of)
}

// MicroByKind sums samples up by kind (kinds with at least minSamples), most sampled first.
func MicroByKind(samples []MicroSample, minSamples int) []MicroKind {
	by := map[string][]MicroSample{}
	for _, s := range samples {
		if s.Range > 0 {
			by[s.Kind] = append(by[s.Kind], s)
		}
	}
	var out []MicroKind
	for kind, list := range by {
		if len(list) < minSamples {
			continue
		}
		k := MicroKind{Kind: kind, Samples: len(list)}
		var hold, holdAll, kiteAt, ahead, retreatHP []float64
		firing, outranged, backing, outrangedBy, closing, targeted, siege, staticNear, away := 0, 0, 0, 0, 0, 0, 0, 0, 0
		for _, s := range list {
			ratio := s.Dist / s.Range
			if s.Firing {
				firing++
				holdAll = append(holdAll, ratio)
				if s.Approach > -0.3 && s.Approach < 0.3 {
					hold = append(hold, ratio)
				}
				if s.TStatic != nil {
					targeted++
					if *s.TStatic {
						siege++
					}
				}
				if s.EStatic {
					staticNear++
				}
			}
			if !s.EStatic && s.ERange < s.Range*0.9 {
				if ratio < 0.7 {
					outranged++
					if s.Approach < -0.3 {
						backing++
					}
				}
				if s.Approach < -0.3 {
					kiteAt = append(kiteAt, ratio)
				}
			}
			if s.ERange >= s.Range*1.1 {
				outrangedBy++
				if s.Approach > 0.3 {
					closing++
				}
			}
			if s.Group >= 3 {
				ahead = append(ahead, s.Ahead)
			}
			if !s.Firing && s.Approach < -0.5 {
				away++
				retreatHP = append(retreatHP, s.HP)
			}
		}
		k.Firing = share(firing, len(list))
		// units that never stand still while firing (heavies walking in): all their firing samples
		if len(hold) < 10 {
			hold = holdAll
		}
		k.Hold, k.HoldP25, k.HoldP75 = microQ(hold, 0.5), microQ(hold, 0.25), microQ(hold, 0.75)
		k.Kite = share(backing, outranged)
		k.KiteAt = microQ(kiteAt, 0.5)
		k.Close = share(closing, outrangedBy)
		k.Ahead = microQ(ahead, 0.5)
		k.Siege = share(siege, targeted)
		k.StaticNear = share(staticNear, firing)
		k.RetreatHP = microQ(retreatHP, 0.5)
		k.RetreatRate = share(away, len(list))
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Samples > out[j].Samples })
	return out
}

// MicroText is the kinds as a markdown table.
func MicroText(kinds []MicroKind) string {
	var b strings.Builder
	b.WriteString("| Kind | Samples | Firing | Fights from (range, p25-p75) | Backs off from outranged | Backs off at | Closes on longer range | Ahead of group | Shoots structures (when near) | Retreats at health |\n")
	b.WriteString("|---|---|---|---|---|---|---|---|---|---|\n")
	for _, k := range kinds {
		fmt.Fprintf(&b, "| %s | %d | %.0f%% | %.2f (%.2f-%.2f) | %.0f%% | %.2f | %.0f%% | %.0f | %.0f%% (%.0f%%) | %.2f (%.0f%% of samples) |\n",
			k.Kind, k.Samples, 100*k.Firing, k.Hold, k.HoldP25, k.HoldP75, 100*k.Kite, k.KiteAt, 100*k.Close, k.Ahead,
			100*k.Siege, 100*k.StaticNear, k.RetreatHP, 100*k.RetreatRate)
	}
	return b.String()
}

// MicroDoctrine suggests sc_doctrine.lua's D.micro.kinds from the kinds: hold = where they fight from,
// kite = the distance they back off at when they mostly do (else false), siege when they shoot
// structures clearly more than structures are what's near them, behind = how far behind their group
// they stand when that's over 100 elmos.
func MicroDoctrine(kinds []MicroKind) string {
	var b strings.Builder
	b.WriteString("kinds = {\n")
	for _, k := range kinds {
		kite := "false"
		if k.Kite >= 0.3 && k.KiteAt > 0 {
			kite = fmt.Sprintf("%.2f", k.KiteAt)
		}
		fmt.Fprintf(&b, "\t[%q] = { hold = %.2f, kite = %s", k.Kind, k.Hold, kite)
		if k.Siege > 0.5 && k.Siege > k.StaticNear*1.5 {
			b.WriteString(", siege = true")
		}
		if k.Ahead < -100 {
			fmt.Fprintf(&b, ", behind = %.0f", -k.Ahead)
		}
		if k.Ahead > 100 {
			b.WriteString(", front = true")
		}
		fmt.Fprintf(&b, " }, -- %d samples, retreats at %.2f health\n", k.Samples, k.RetreatHP)
	}
	b.WriteString("}\n")
	return b.String()
}
