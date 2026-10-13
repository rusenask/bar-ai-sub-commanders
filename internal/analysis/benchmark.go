package analysis

import (
	_ "embed"
	"encoding/json"
	"sort"
	"strconv"
)

// Metrics compared between our games and the benchmark, in report order.
var Metrics = []string{"metalIncome", "mex", "factories", "builders", "army", "turrets", "energyIncome", "generators"}

// MetricNames are the metrics as the report shows them.
var MetricNames = map[string]string{
	"metalIncome": "metal income", "energyIncome": "energy income", "mex": "extractors", "generators": "generators",
	"factories": "factories", "builders": "constructors", "army": "army value", "turrets": "turret value",
}

// Value returns one metric of an economy sample.
func (e Eco) Value(metric string) float64 {
	switch metric {
	case "metalIncome":
		return e.MetalIncome
	case "energyIncome":
		return e.EnergyIncome
	case "mex":
		return float64(e.Mex)
	case "generators":
		return float64(e.Generators)
	case "factories":
		return float64(e.Factories)
	case "builders":
		return float64(e.Builders)
	case "army":
		return e.Army
	case "turrets":
		return e.Turrets
	}
	return 0
}

// Band is the spread of a metric at a minute: quartiles over the players that reached it.
type Band struct {
	P25 float64 `json:"p25"`
	P50 float64 `json:"p50"`
	P75 float64 `json:"p75"`
	N   int     `json:"n"`
}

// Benchmark is how strong players' economies grow, minute by minute (from replays, cmd/gamereport -bench).
type Benchmark struct {
	Description string                     `json:"description"`
	Games       int                        `json:"games"`
	Players     int                        `json:"players"`
	Minutes     map[string]map[string]Band `json:"minutes"` // minute -> metric -> band
}

// Band returns a metric's band at a minute, if the benchmark has enough players there.
func (b *Benchmark) Band(minute int, metric string) (Band, bool) {
	if b == nil {
		return Band{}, false
	}
	band, ok := b.Minutes[strconv.Itoa(minute)][metric]
	return band, ok && band.N >= 4
}

//go:embed benchmarks/pro-duel.json
var proDuel []byte

// ProDuel is the benchmark of strong players' 1v1s shipped with the repo (rebuilt by make benchmarks).
func ProDuel() *Benchmark {
	var b Benchmark
	if json.Unmarshal(proDuel, &b) != nil || len(b.Minutes) == 0 {
		return nil
	}
	return &b
}

// BuildBenchmark computes quartiles per minute over every team's series.
func BuildBenchmark(description string, games []*Recorded) *Benchmark {
	b := &Benchmark{Description: description, Minutes: map[string]map[string]Band{}}
	values := map[int]map[string][]float64{}
	for _, g := range games {
		if len(g.Teams) == 0 {
			continue
		}
		b.Games++
		for _, series := range g.Teams {
			b.Players++
			for _, e := range series {
				if values[e.Minute] == nil {
					values[e.Minute] = map[string][]float64{}
				}
				for _, m := range Metrics {
					values[e.Minute][m] = append(values[e.Minute][m], e.Value(m))
				}
			}
		}
	}
	for minute, byMetric := range values {
		bands := map[string]Band{}
		for m, v := range byMetric {
			bands[m] = bandOf(v)
		}
		b.Minutes[strconv.Itoa(minute)] = bands
	}
	return b
}

func bandOf(v []float64) Band {
	s := append([]float64(nil), v...)
	sort.Float64s(s)
	return Band{P25: quantile(s, 0.25), P50: quantile(s, 0.5), P75: quantile(s, 0.75), N: len(s)}
}

// quantile of sorted values, interpolated, rounded to one decimal.
func quantile(s []float64, q float64) float64 {
	if len(s) == 0 {
		return 0
	}
	pos := q * float64(len(s)-1)
	i := int(pos)
	v := s[i]
	if i+1 < len(s) {
		v += (s[i+1] - s[i]) * (pos - float64(i))
	}
	return float64(int(v*10+0.5)) / 10
}

func median(v []float64) float64 {
	if len(v) == 0 {
		return 0
	}
	s := append([]float64(nil), v...)
	sort.Float64s(s)
	return quantile(s, 0.5)
}
