// Package learn tunes the sub-commanders' doctrine from game results: the rules the strategist may tune
// (D.tunable in sc_doctrine.lua) are searched per matchup with a cross-entropy method. Each game plays one
// sample around the current mean; after a generation the mean moves toward the best-scoring samples and
// the spread narrows. Sandboxes run the exploration games (testenv/sandbox/batch.py --learn); the bridge
// serves the learned rules to real games and keeps learning from their summaries.
package learn

import (
	"encoding/json"
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Param is one tunable rule: its bounds and the doctrine's default.
type Param struct {
	Name    string  `json:"name"`
	Min     float64 `json:"min"`
	Max     float64 `json:"max"`
	Default float64 `json:"default"`
	Int     bool    `json:"int,omitempty"` // whole numbers (factory counts, constructor bonus)
}

// Trial is one game played with one sample of the rules.
type Trial struct {
	Generation int                `json:"generation"`
	Rules      map[string]float64 `json:"rules"`
	Score      float64            `json:"score"`
	Result     string             `json:"result"`
	Minutes    float64            `json:"minutes"`
	Mean       bool               `json:"mean,omitempty"` // the mean itself (measures progress)
	Source     string             `json:"source,omitempty"`
	At         time.Time          `json:"at"`
}

// Store is what has been learned for one matchup.
type Store struct {
	Key        string             `json:"key"`
	Generation int                `json:"generation"`
	Params     []Param            `json:"params"`
	Mean       map[string]float64 `json:"mean"`  // in rule units
	Sigma      map[string]float64 `json:"sigma"` // as a fraction of each rule's range
	Trials     []Trial            `json:"trials"`
	// History of each generation: how the mean scored (its own trials) and how all samples scored.
	History []GenSummary `json:"history"`
	// Active, when set, are the only rules searched; the others stay at their mean. One game says little,
	// so a few rules at a time learn faster than all of them (the first run moved 18 and found no trend).
	Active []string `json:"active,omitempty"`
	// MeanEvery: every this many samples is the mean itself (default 6), to measure where the search is.
	MeanEvery int `json:"meanEvery,omitempty"`
}

func (s *Store) active(name string) bool {
	if len(s.Active) == 0 {
		return true
	}
	for _, a := range s.Active {
		if a == name {
			return true
		}
	}
	return false
}

// GenSummary is one generation's outcome.
type GenSummary struct {
	Generation int     `json:"generation"`
	Games      int     `json:"games"`
	MeanScore  float64 `json:"meanScore"`  // average score of all trials
	EliteScore float64 `json:"eliteScore"` // average of the elites
	MeanTrials float64 `json:"meanTrials"` // average score of the mean's own trials (-1 none)
	Wins       int     `json:"wins"`
	Losses     int     `json:"losses"`
}

// Search settings.
const (
	StartSigma = 0.08 // of each rule's range (0.15 on 18 rules at once broke most games: 16 of 24 lost)
	MinSigma   = 0.03
	EliteShare = 0.3
	Step       = 0.5 // how far the mean moves toward the elites per generation
)

var (
	reTunable = regexp.MustCompile(`(?m)^\s*([a-z_]+)\s*=\s*\{\s*(D(?:\.[a-z]+)?)\s*,\s*"([A-Za-z]+)"\s*,\s*([-0-9.]+)\s*,\s*([-0-9.]+)\s*,`)
)

// ParamsFromDoctrine reads the tunable rules, their bounds and defaults from sc_doctrine.lua.
func ParamsFromDoctrine(path string) ([]Param, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	src := string(data)
	var out []Param
	for _, m := range reTunable.FindAllStringSubmatch(src, -1) {
		lo, _ := strconv.ParseFloat(m[4], 64)
		hi, _ := strconv.ParseFloat(m[5], 64)
		def, ok := defaultOf(src, m[2], m[3])
		if !ok {
			return nil, fmt.Errorf("no default for %s (%s.%s)", m[1], m[2], m[3])
		}
		p := Param{Name: m[1], Min: lo, Max: hi, Default: def}
		p.Int = lo == math.Trunc(lo) && hi == math.Trunc(hi) && def == math.Trunc(def) && hi-lo <= 10
		out = append(out, p)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no D.tunable entries in %s", path)
	}
	return out, nil
}

// defaultOf finds `field = value` inside the table `table = {` (or `D.field = value` for D itself).
func defaultOf(src, table, field string) (float64, bool) {
	if table == "D" {
		m := regexp.MustCompile(`(?m)^D\.` + field + `\s*=\s*([-0-9.]+)`).FindStringSubmatch(src)
		if m == nil {
			return 0, false
		}
		v, err := strconv.ParseFloat(m[1], 64)
		return v, err == nil
	}
	start := strings.Index(src, "\n"+table+" = {")
	if start < 0 {
		return 0, false
	}
	end := strings.Index(src[start+1:], "\n}")
	if end < 0 {
		return 0, false
	}
	block := src[start : start+1+end]
	m := regexp.MustCompile(`(?m)^\t` + field + `\s*=\s*([-0-9.]+)`).FindStringSubmatch(block)
	if m == nil {
		return 0, false
	}
	v, err := strconv.ParseFloat(m[1], 64)
	return v, err == nil
}

// New starts a store at the doctrine's defaults.
func New(key string, params []Param) *Store {
	s := &Store{Key: key, Params: params, Mean: map[string]float64{}, Sigma: map[string]float64{}}
	for _, p := range params {
		s.Mean[p.Name] = p.Default
		s.Sigma[p.Name] = StartSigma
	}
	return s
}

// Path is where a matchup's store lives in dir.
func Path(dir, key string) string { return filepath.Join(dir, key+".json") }

// Load reads a store, or starts one from params when there is none.
func Load(dir, key string, params []Param) (*Store, error) {
	data, err := os.ReadFile(Path(dir, key))
	if os.IsNotExist(err) {
		return New(key, params), nil
	}
	if err != nil {
		return nil, err
	}
	s := &Store{}
	if err := json.Unmarshal(data, s); err != nil {
		return nil, err
	}
	// rules added to the doctrine since: start them at their defaults
	have := map[string]bool{}
	for _, p := range s.Params {
		have[p.Name] = true
	}
	for _, p := range params {
		if !have[p.Name] {
			s.Params = append(s.Params, p)
			s.Mean[p.Name] = p.Default
			s.Sigma[p.Name] = StartSigma
		}
	}
	return s, nil
}

// Save writes the store.
func (s *Store) Save(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", " ")
	if err != nil {
		return err
	}
	return os.WriteFile(Path(dir, s.Key), data, 0o644)
}

func clamp(v, lo, hi float64) float64 { return math.Max(lo, math.Min(hi, v)) }

// Sample draws n rule sets for the next games: every MeanEvery-th is the mean itself (to measure it), the
// rest Gaussian around it on the active rules, clamped to the bounds.
func (s *Store) Sample(n int, rng *rand.Rand) []map[string]float64 {
	every := s.MeanEvery
	if every <= 0 {
		every = 6
	}
	out := make([]map[string]float64, n)
	for i := range out {
		r := map[string]float64{}
		for _, p := range s.Params {
			v := s.Mean[p.Name]
			if i%every != 0 && s.active(p.Name) {
				v += rng.NormFloat64() * s.Sigma[p.Name] * (p.Max - p.Min)
			}
			v = clamp(v, p.Min, p.Max)
			if p.Int {
				v = math.Round(v)
			}
			r[p.Name] = v
		}
		out[i] = r
	}
	return out
}

// IsMean reports whether rules are the store's mean (a measuring sample). Rules the sample didn't have
// (added to the doctrine after it was drawn) don't count.
func (s *Store) IsMean(rules map[string]float64) bool {
	for _, p := range s.Params {
		if _, ok := rules[p.Name]; !ok {
			continue
		}
		m := clamp(s.Mean[p.Name], p.Min, p.Max)
		if p.Int {
			m = math.Round(m)
		}
		if math.Abs(rules[p.Name]-m) > 1e-9 {
			return false
		}
	}
	return true
}

// Score turns a game's outcome into a number to maximise: a win is worth most (more when early), a game
// still going at the end is half, a loss counts the time survived; the damage trade nudges each.
func Score(result string, minutes, dealtTaken, limitMinutes float64) float64 {
	trade := 0.0
	if dealtTaken > 0 {
		trade = clamp(math.Log2(dealtTaken), -1, 1)
	}
	if limitMinutes <= 0 {
		limitMinutes = 60
	}
	switch result {
	case "WIN":
		return 1 + 0.2*clamp(1-minutes/limitMinutes, 0, 1)
	case "TIMEOUT":
		return 0.5 + 0.15*trade
	default:
		return 0.3*clamp(minutes/limitMinutes, 0, 1) + 0.05*trade
	}
}

// Update adds a generation's trials and moves the mean toward the elites.
func (s *Store) Update(trials []Trial) GenSummary {
	gen := s.Generation + 1
	sum := GenSummary{Generation: gen, Games: len(trials), MeanTrials: -1}
	if len(trials) == 0 {
		return sum
	}
	var meanScores []float64
	for i := range trials {
		trials[i].Generation = gen
		trials[i].Mean = s.IsMean(trials[i].Rules)
		sum.MeanScore += trials[i].Score
		if trials[i].Mean {
			meanScores = append(meanScores, trials[i].Score)
		}
		switch trials[i].Result {
		case "WIN":
			sum.Wins++
		case "LOSS":
			sum.Losses++
		}
	}
	sum.MeanScore /= float64(len(trials))
	if len(meanScores) > 0 {
		sum.MeanTrials = avg(meanScores)
	}
	sorted := append([]Trial(nil), trials...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Score > sorted[j].Score })
	k := max(2, int(math.Ceil(EliteShare*float64(len(sorted)))))
	k = min(k, len(sorted))
	elites := sorted[:k]
	for _, e := range elites {
		sum.EliteScore += e.Score
	}
	sum.EliteScore /= float64(k)
	for _, p := range s.Params {
		span := p.Max - p.Min
		if span <= 0 || !s.active(p.Name) {
			continue
		}
		var vals []float64
		for _, e := range elites {
			// a rule the game didn't have (added after the sample was drawn) says nothing about it
			if v, ok := e.Rules[p.Name]; ok {
				vals = append(vals, (v-p.Min)/span)
			}
		}
		if len(vals) == 0 {
			continue
		}
		m := (s.Mean[p.Name] - p.Min) / span
		em := avg(vals)
		sd := 0.0
		for _, v := range vals {
			sd += (v - em) * (v - em)
		}
		sd = math.Sqrt(sd / float64(len(vals)))
		m += Step * (em - m)
		s.Mean[p.Name] = p.Min + clamp(m, 0, 1)*span
		// the elites' spread underestimates where to look next (they are the lucky draws): inflate it, and
		// shrink slowly so the search doesn't freeze before it gets there
		s.Sigma[p.Name] = math.Max(MinSigma, 0.85*s.Sigma[p.Name]+0.15*1.5*sd)
	}
	s.Generation = gen
	s.Trials = append(s.Trials, trials...)
	s.History = append(s.History, sum)
	return sum
}

func avg(v []float64) float64 {
	if len(v) == 0 {
		return 0
	}
	t := 0.0
	for _, x := range v {
		t += x
	}
	return t / float64(len(v))
}

// Overlay is what the widget reads at game start (LuaUI/Config/sc_learned.json).
type Overlay struct {
	Key        string             `json:"key"`
	Generation int                `json:"generation"`
	Rules      map[string]float64 `json:"rules"`
}

// MeanOverlay is the current best guess, for real games.
func (s *Store) MeanOverlay() Overlay {
	r := map[string]float64{}
	for _, p := range s.Params {
		v := clamp(s.Mean[p.Name], p.Min, p.Max)
		if p.Int {
			v = math.Round(v)
		}
		r[p.Name] = v
	}
	return Overlay{Key: s.Key, Generation: s.Generation, Rules: r}
}

// Changes lists rules that moved from the doctrine's defaults, largest move first, for reports.
func (s *Store) Changes() []string {
	type ch struct {
		name     string
		from, to float64
		rel      float64
	}
	var list []ch
	for _, p := range s.Params {
		to := s.MeanOverlay().Rules[p.Name]
		if span := p.Max - p.Min; span > 0 && math.Abs(to-p.Default)/span > 0.02 {
			list = append(list, ch{p.Name, p.Default, to, math.Abs(to-p.Default) / span})
		}
	}
	sort.Slice(list, func(i, j int) bool { return list[i].rel > list[j].rel })
	out := make([]string, len(list))
	for i, c := range list {
		out[i] = fmt.Sprintf("%s %.3g -> %.3g", c.name, c.from, c.to)
	}
	return out
}
