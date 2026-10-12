// Command decidereval scores a System One decision model (Kev, Clef, ...) on
// Beyond All Reason decisions with known good answers: unit counters, attack or
// hold, builder priorities, turret choice. It prints accuracy and latency.
//
//	go run ./cmd/decidereval -url http://100.108.100.25:8009
package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"slices"
	"strings"
	"time"

	"github.com/rusenask/bar-ai-sub-commanders/internal/decider"
)

//go:embed cases.json
var casesJSON []byte

// the Legion T1 bot lab's combat units, described the way the widget describes options
var legionT1 = map[string]string{
	"legcen":   "legcen: assault, range 180, speed 90, health 840, cost 140 metal; all-round fighter, good against raiders",
	"legkark":  "legkark: heavy, range 360, speed 42, health 1725, cost 310 metal; armored, good against assault units and raiders, weak against massed cheap units and artillery",
	"leggob":   "leggob: raider, range 261, speed 75, health 200, cost 30 metal; fast and cheap, good against artillery, skirmishers and lone extractors, weak against riot units and turrets",
	"leglob":   "leglob: assault, range 400, speed 51, health 550, cost 60 metal; all-round fighter, good against raiders",
	"legbal":   "legbal: artillery, range 460, speed 43, health 900, cost 160 metal; long arcing range, good against turrets and static defence, weak against fast raiders",
	"legaabot": "legaabot: mobile anti-air, range 760, speed 55, health 610, cost 120 metal, shoots aircraft only; good against bombers and gunships, useless against ground units and unarmed scout planes",
}

type testCase struct {
	Name      string                     `json:"name"`
	State     string                     `json:"state"`
	Questions map[string]json.RawMessage `json:"questions"`
	Question  string                     `json:"question"`
	Accept    []string                   `json:"accept"`
	Reject    []string                   `json:"reject"`
	Noul      *bool                      `json:"noul"`
	MaxScore  *float64                   `json:"maxScore"`
}

type answer struct {
	Choice        string             `json:"choice"`
	Noul          *float64           `json:"noul"`
	Score         *float64           `json:"score"`
	Probabilities map[string]float64 `json:"probabilities"`
}

func main() {
	url := flag.String("url", "http://100.108.100.25:8009", "decision model base URL")
	model := flag.String("model", "kev-latest", "model name to send")
	flag.Parse()

	var cases []testCase
	if err := json.Unmarshal(casesJSON, &cases); err != nil {
		log.Fatal(err)
	}
	units, _ := json.Marshal(legionT1)
	client := decider.New(*url, *model)
	client.HTTP.Timeout = 60 * time.Second
	passed, total := 0, 0
	var latencies []time.Duration
	for _, c := range cases {
		qs := map[string]json.RawMessage{}
		for k, q := range c.Questions {
			qs[k] = json.RawMessage(strings.ReplaceAll(string(q), `"$LEGION_T1"`, string(units)))
		}
		raw, _ := json.Marshal(qs)
		start := time.Now()
		answers, err := client.Decide(context.Background(), c.State, raw)
		took := time.Since(start)
		total++
		if err != nil {
			fmt.Printf("FAIL  %-40s error: %v\n", c.Name, err)
			continue
		}
		latencies = append(latencies, took)
		var a map[string]answer
		if err := json.Unmarshal(answers, &a); err != nil {
			fmt.Printf("FAIL  %-40s bad answers: %s\n", c.Name, answers)
			continue
		}
		got := a[c.Question]
		ok, detail := judge(c, got)
		if ok {
			passed++
		}
		fmt.Printf("%-5s %-40s %s  (%s)\n", map[bool]string{true: "ok", false: "FAIL"}[ok], c.Name, detail, took.Round(time.Millisecond))
	}
	slices.Sort(latencies)
	median := time.Duration(0)
	if len(latencies) > 0 {
		median = latencies[len(latencies)/2]
	}
	fmt.Printf("\n%d/%d correct, median latency %s (%s)\n", passed, total, median.Round(time.Millisecond), *url)
}

func judge(c testCase, a answer) (bool, string) {
	switch {
	case c.Noul != nil:
		if a.Noul == nil {
			return false, "no noul"
		}
		return (*a.Noul >= 0.5) == *c.Noul, fmt.Sprintf("p(yes)=%.2f want %v", *a.Noul, *c.Noul)
	case c.MaxScore != nil:
		if a.Score == nil {
			return false, "no score"
		}
		return *a.Score <= *c.MaxScore, fmt.Sprintf("score=%.2f want <= %.1f", *a.Score, *c.MaxScore)
	default:
		probs := top(a.Probabilities)
		if len(c.Accept) > 0 {
			return slices.Contains(c.Accept, a.Choice), fmt.Sprintf("chose %s, want one of %v  [%s]", a.Choice, c.Accept, probs)
		}
		return !slices.Contains(c.Reject, a.Choice), fmt.Sprintf("chose %s, must not be %v  [%s]", a.Choice, c.Reject, probs)
	}
}

func top(p map[string]float64) string {
	type kv struct {
		k string
		v float64
	}
	var list []kv
	for k, v := range p {
		list = append(list, kv{k, v})
	}
	slices.SortFunc(list, func(a, b kv) int {
		if a.v > b.v {
			return -1
		}
		return 1
	})
	var parts []string
	for i, e := range list {
		if i == 3 {
			break
		}
		parts = append(parts, fmt.Sprintf("%s %.2f", e.k, e.v))
	}
	return strings.Join(parts, ", ")
}
