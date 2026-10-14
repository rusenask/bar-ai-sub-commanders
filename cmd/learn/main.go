// Command learn tunes the sub-commanders' doctrine from game results (internal/learn): a store per
// matchup in learn/<key>.json, one generation per batch.
//
//	learn sample -key legion-vs-armada -n 36 -out /tmp/overlays   # rule sets for the next games (g1.json ...)
//	learn update -key legion-vs-armada -batch testenv/batch/<dir> -samples /tmp/overlays
//	learn show -key legion-vs-armada                              # generations, scores, what moved
//	learn overlay -key legion-vs-armada -out /tmp/rules.json   # the mean (for an A/B: force-batch OVERLAY=)
//	learn validate -key legion-vs-armada -evidence "batch A vs batch B: ..."   # the mean beat the defaults:
//	                                                                          # real games get it (the bridge)
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math/rand/v2"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/rusenask/bar-ai-sub-commanders/internal/analysis"
	"github.com/rusenask/bar-ai-sub-commanders/internal/learn"
)

func main() {
	if len(os.Args) < 2 {
		log.Fatal("usage: learn sample|update|show|overlay -key <matchup> ...")
	}
	cmd := os.Args[1]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	key := fs.String("key", "", "matchup, e.g. legion-vs-armada")
	dir := fs.String("dir", "learn", "where the stores live")
	doctrine := fs.String("doctrine", "widget/LuaUI/Include/sc_doctrine.lua", "the doctrine (rules, bounds, defaults)")
	n := fs.Int("n", 12, "sample: how many rule sets")
	out := fs.String("out", "", "sample: directory for g<i>.json; overlay: the file")
	batch := fs.String("batch", "", "update: the batch directory (<i>.txt harness logs)")
	samples := fs.String("samples", "", "update: the directory sample wrote")
	limit := fs.Float64("minutes", 60, "update: the games' length")
	only := fs.String("only", "", "sample: search only these rules (comma-separated; kept in the store; \"all\" clears it)")
	evidence := fs.String("evidence", "", "validate: the A/B batches that show the mean beats the defaults")
	meanEvery := fs.Int("mean-every", 0, "sample: every this many games play the mean itself (kept in the store)")
	_ = fs.Parse(os.Args[2:])
	if *key == "" {
		log.Fatal("-key is required")
	}
	params, err := learn.ParamsFromDoctrine(*doctrine)
	if err != nil {
		log.Fatal(err)
	}
	store, err := learn.Load(*dir, *key, params)
	if err != nil {
		log.Fatal(err)
	}
	switch cmd {
	case "sample":
		if *only == "all" {
			store.Active = nil
		} else if *only != "" {
			store.Active = strings.Split(*only, ",")
		}
		if *meanEvery > 0 {
			store.MeanEvery = *meanEvery
		}
		if *only != "" || *meanEvery > 0 {
			if err := store.Save(*dir); err != nil {
				log.Fatal(err)
			}
		}
		if err := os.MkdirAll(*out, 0o755); err != nil {
			log.Fatal(err)
		}
		rng := rand.New(rand.NewPCG(uint64(time.Now().UnixNano()), uint64(os.Getpid())))
		for i, r := range store.Sample(*n, rng) {
			writeJSON(filepath.Join(*out, fmt.Sprintf("g%d.json", i+1)), learn.Overlay{Key: store.Key, Generation: store.Generation + 1, Rules: r})
		}
		fmt.Printf("%d rule sets for generation %d of %s in %s\n", *n, store.Generation+1, store.Key, *out)
	case "update":
		var trials []learn.Trial
		files, _ := filepath.Glob(filepath.Join(*samples, "g*.json"))
		for _, f := range files {
			var ov learn.Overlay
			data, err := os.ReadFile(f)
			if err != nil || json.Unmarshal(data, &ov) != nil {
				continue
			}
			i := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(f), "g"), ".json")
			fh, err := os.Open(filepath.Join(*batch, i+".txt"))
			if err != nil {
				fmt.Printf("game %s: no log (not run): left out\n", i)
				continue
			}
			g, err := analysis.ParseGame(fh.Name(), fh)
			fh.Close()
			if err != nil || g.Result == "" || len(g.Crashed) > 0 {
				fmt.Printf("game %s: unfinished or crashed: left out\n", i)
				continue
			}
			s := analysis.Summarize(g)
			trials = append(trials, learn.Trial{Rules: ov.Rules, Result: g.Result, Minutes: s.Minutes,
				Score: learn.Score(g.Result, s.Minutes, s.DealtTaken, *limit), Source: fh.Name(), At: time.Now()})
		}
		sum := store.Update(trials)
		if err := store.Save(*dir); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("%s generation %d: %d games, %d won, %d lost, score %.3f (elites %.3f, the mean's own games %.3f)\n",
			store.Key, sum.Generation, sum.Games, sum.Wins, sum.Losses, sum.MeanScore, sum.EliteScore, sum.MeanTrials)
		fmt.Println("moved from the doctrine:", strings.Join(store.Changes(), ", "))
	case "show":
		fmt.Printf("%s: generation %d, %d games\n\n| Gen | Games | Won | Lost | Score | Elites | Mean's games |\n|---|---|---|---|---|---|---|\n", store.Key, store.Generation, len(store.Trials))
		for _, h := range store.History {
			fmt.Printf("| %d | %d | %d | %d | %.3f | %.3f | %.3f |\n", h.Generation, h.Games, h.Wins, h.Losses, h.MeanScore, h.EliteScore, h.MeanTrials)
		}
		fmt.Println("\nmoved from the doctrine:", strings.Join(store.Changes(), ", "))
	case "validate":
		if *evidence == "" {
			log.Fatal("-evidence is required: the A/B batches that show the mean beats the defaults")
		}
		store.Validate(*evidence)
		if err := store.Save(*dir); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("%s generation %d validated: real games get it\n", store.Key, store.Generation)
	case "overlay":
		writeJSON(*out, store.MeanOverlay())
		fmt.Printf("%s generation %d -> %s\n", store.Key, store.Generation, *out)
	default:
		log.Fatalf("unknown command %q", cmd)
	}
}

func writeJSON(path string, v any) {
	data, err := json.MarshalIndent(v, "", " ")
	if err != nil {
		log.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		log.Fatal(err)
	}
}
