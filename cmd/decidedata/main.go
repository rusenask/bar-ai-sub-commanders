// Command decidedata turns the data logger's samples (testenv/collect.sh) into training data for our
// decision models (design/decision-models.md):
//
//	<out>/<task>/{train,dev,test}.jsonl     Kev records: System One state + questions with labels
//	<out>/<task>/{train,dev,test}.feat.jsonl flat numeric features + label, for the baselines
//	<out>/stats.json                         counts and label rates per task and split
//
// Splits are by game (no fight from a test game is in training). Training sets keep at most 2:1 between
// the yes and no labels of the main question; dev and test keep the natural rate.
//
//	go run ./cmd/decidedata -in testenv/data/raw -out testenv/data/sets
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"hash/fnv"
	"log"
	"math"
	"math/rand/v2"
	"os"
	"path/filepath"
	"sort"

	"github.com/rusenask/bar-ai-sub-commanders/internal/decider"
)

type sample struct {
	Type    string `json:"type"`
	Game    string `json:"game"`
	Frame   int    `json:"frame"`
	Version int    `json:"version"`
	decider.FightFeatures
	OwnLost   int `json:"ownLost"`
	EnemyLost int `json:"enemyLost"`

	Unit      decider.UnitTraits `json:"unit"`
	Situation decider.Situation  `json:"situation"`
	Place     *decider.Place     `json:"place"`
	Dealt     int                `json:"dealt"`
	Died      bool               `json:"died"`
	Lived     int                `json:"lived"`
}

type record struct {
	State     string                      `json:"state"`
	Questions map[string]decider.Question `json:"questions"`
}

type example struct {
	split string
	label bool // the main question's label, for balancing and rates
	rec   record
	feat  map[string]float64
}

func splitOf(game string) string {
	h := fnv.New32a()
	h.Write([]byte(game))
	switch h.Sum32() % 10 {
	case 0:
		return "test"
	case 1:
		return "dev"
	}
	return "train"
}

// minFightLoss: fights where less value than this was lost in total are skirmishes, not fights
var minFightLoss = flag.Int("min-fight-loss", 150, "skip fights where both sides together lost less metal value than this")

func fightExample(s sample) (example, bool) {
	ahead, level, ok := decider.FightOutcome(s.OwnLost, s.EnemyLost)
	if !ok || s.Own.Count == 0 || s.OwnLost+s.EnemyLost < *minFightLoss {
		return example{}, false
	}
	qs := decider.FightQuestions()
	a, o := qs["ahead"], qs["outcome"]
	a.Label, o.Label = ahead, level
	qs["ahead"], qs["outcome"] = a, o
	s.Minute = s.Frame / 1800
	f := decider.FlatFight(s.FightFeatures)
	return example{label: ahead, rec: record{State: decider.FightState(s.FightFeatures), Questions: qs}, feat: f}, true
}

func valueExample(task string, s sample) (example, bool) {
	// still alive at the end after less than 3 minutes: we don't know yet whether it would have paid off
	if !s.Died && s.Lived < 180 {
		return example{}, false
	}
	paid := s.Dealt >= s.Unit.Cost
	vf := decider.ValueFeatures{Minute: s.Frame / 1800, Situation: s.Situation, Place: s.Place, Candidates: []decider.UnitTraits{s.Unit}}
	qs := decider.ValueQuestions(task, vf)
	q := qs[s.Unit.Name]
	q.Label = paid
	qs[s.Unit.Name] = q
	f := decider.FlatValue(vf, s.Unit)
	return example{label: paid, rec: record{State: decider.ValueState(task, vf), Questions: qs}, feat: f}, true
}

func main() {
	in := flag.String("in", "testenv/data/raw", "directory of logged games (*.jsonl)")
	out := flag.String("out", "testenv/data/sets", "output directory")
	maxRatio := flag.Float64("balance", 2, "most yes:no (or no:yes) in training sets; 0 keeps everything")
	minVersion := flag.Int("min-version", 2, "skip games logged by an older data logger (version in the start record)")
	flag.Parse()

	files, err := filepath.Glob(filepath.Join(*in, "*.jsonl"))
	if err != nil || len(files) == 0 {
		log.Fatalf("no logged games in %s", *in)
	}
	byTask := map[string][]example{}
	games := map[string]bool{}
	for _, file := range files {
		f, err := os.Open(file)
		if err != nil {
			log.Fatal(err)
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 1<<20), 1<<24)
		version := -1
		for sc.Scan() {
			var s sample
			if err := json.Unmarshal(sc.Bytes(), &s); err != nil {
				log.Printf("%s: skipping a line: %v", file, err)
				continue
			}
			if s.Type == "start" {
				version = s.Version
			}
			if version < *minVersion {
				continue
			}
			var ex example
			var ok bool
			switch s.Type {
			case "fight":
				ex, ok = fightExample(s)
			case "unit", "turret":
				ex, ok = valueExample(s.Type, s)
			}
			if ok {
				games[s.Game] = true
				ex.split = splitOf(s.Game)
				byTask[s.Type] = append(byTask[s.Type], ex)
			}
		}
		if err := sc.Err(); err != nil {
			log.Printf("%s: %v", file, err)
		}
		f.Close()
	}

	stats := map[string]any{"games": len(games)}
	rng := rand.New(rand.NewPCG(1, 2))
	for task, exs := range byTask {
		dir := filepath.Join(*out, task)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			log.Fatal(err)
		}
		taskStats := map[string]any{}
		for _, split := range []string{"train", "dev", "test"} {
			var part []example
			for _, e := range exs {
				if e.split == split {
					part = append(part, e)
				}
			}
			if split == "train" && *maxRatio > 0 {
				part = balance(part, *maxRatio, rng)
			}
			rng.Shuffle(len(part), func(i, j int) { part[i], part[j] = part[j], part[i] })
			yes := 0
			recs, feats := create(dir, split+".jsonl"), create(dir, split+".feat.jsonl")
			for _, e := range part {
				if e.label {
					yes++
				}
				writeJSON(recs, e.rec)
				writeJSON(feats, map[string]any{"label": e.label, "features": e.feat})
			}
			recs.Close()
			feats.Close()
			rate := 0.0
			if len(part) > 0 {
				rate = float64(yes) / float64(len(part))
			}
			taskStats[split] = map[string]any{"records": len(part), "yesRate": math.Round(rate*1000) / 1000}
		}
		stats[task] = taskStats
	}
	sf := create(*out, "stats.json")
	enc := json.NewEncoder(sf)
	enc.SetIndent("", "  ")
	enc.Encode(stats)
	sf.Close()
	keys := make([]string, 0, len(stats))
	for k := range stats {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Printf("%s: %v\n", k, stats[k])
	}
}

// balance downsamples the majority label to at most ratio times the minority.
func balance(exs []example, ratio float64, rng *rand.Rand) []example {
	var yes, no []example
	for _, e := range exs {
		if e.label {
			yes = append(yes, e)
		} else {
			no = append(no, e)
		}
	}
	limit := func(major, minor []example) []example {
		keep := int(float64(len(minor)) * ratio)
		if len(major) <= keep || len(minor) == 0 {
			return major
		}
		rng.Shuffle(len(major), func(i, j int) { major[i], major[j] = major[j], major[i] })
		return major[:keep]
	}
	if len(yes) > len(no) {
		yes = limit(yes, no)
	} else {
		no = limit(no, yes)
	}
	return append(yes, no...)
}

func create(dir, name string) *os.File {
	f, err := os.Create(filepath.Join(dir, name))
	if err != nil {
		log.Fatal(err)
	}
	return f
}

func writeJSON(f *os.File, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		log.Fatal(err)
	}
	f.Write(append(b, '\n'))
}
