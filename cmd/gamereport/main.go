// Command gamereport analyses test games: economy pace against strong players, losses, stalls, the
// sub-commanders' recurring problems, and a ranked list of findings to work on.
//
//	gamereport testenv/batch/latest              # one batch (a directory of harness logs) or single logs
//	gamereport -compare batch/A batch/B          # A/B arms side by side, one directory per arm
//	gamereport -bench-from testenv/data/pro      # rebuild the strong players' benchmark from replay logs
//	gamereport -json testenv/batch/latest        # the report as JSON (for agents); -compare -json too
//	gamereport -micro testenv/data/pro [-json]   # how strong players' units move and shoot, by kind,
//	                                             # and the D.micro.kinds doctrine that follows
//	gamereport -roles testenv/data/team [-json]  # team games: what each player specialises in
//	gamereport -timeline testenv/batch/latest/3.txt [-json]  # one game minute by minute: economy,
//	                                             # losses and kills by kind, squad / raid decisions
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/rusenask/bar-ai-sub-commanders/internal/analysis"
)

func main() {
	title := flag.String("title", "", "report title (default: the inputs)")
	compare := flag.Bool("compare", false, "each argument is a directory of games (an arm): compare them")
	confidence := flag.Float64("confidence", 0.95, "the verdicts' interval level (a sequential test asks for more at interim looks)")
	benchFile := flag.String("bench", "", "benchmark JSON (default: the strong players' benchmark built into the binary)")
	benchFrom := flag.String("bench-from", "", "build a benchmark from the data logger's JSONL files in this directory")
	benchOut := flag.String("bench-out", "internal/analysis/benchmarks/pro-duel.json", "where -bench-from writes the benchmark")
	benchDesc := flag.String("bench-desc", "strong players' 1v1s (both rated 30+, BAR replays)", "benchmark description")
	playbookOut := flag.String("playbook-out", "docs/research/pro-playbook.md", "with -bench-from: where to write what strong players build and when")
	asJSON := flag.Bool("json", false, "print JSON (report, compare, timeline) instead of markdown / text")
	battles := flag.Bool("battles", false, "the games are battles (scenario battle): efficiency per spec")
	roles := flag.String("roles", "", "directory of data logger JSONL files of team games: players' roles by side size")
	micro := flag.String("micro", "", "directory of data logger JSONL files: per-kind unit behaviour and doctrine")
	formation := flag.String("formation", "", "comma-separated label=dir[:team] of data logger dirs (v8+): formation profiles and what they do to the trade")
	team := flag.Int("team", -1, "with -micro: only this team's fight samples in the commit table (0: ours in our own games)")
	timeline := flag.Bool("timeline", false, "each argument is one game's harness log: show it minute by minute")
	flag.Parse()
	analysis.Confidence = *confidence

	if *roles != "" {
		players, err := analysis.ReadRoles(*roles)
		if err != nil {
			log.Fatal(err)
		}
		if *asJSON {
			printJSON(players)
			return
		}
		fmt.Printf("%d players\n\n%s", len(players), analysis.RolesText(players))
		return
	}
	if *formation != "" {
		fmt.Print(analysis.FormationProfileHeader)
		var all []struct {
			label string
			fs    []analysis.FormSample
		}
		for _, spec := range strings.Split(*formation, ",") {
			label, dir, _ := strings.Cut(spec, "=")
			tm := -1
			if d, t, ok := strings.Cut(dir, ":"); ok {
				dir = d
				fmt.Sscan(t, &tm)
			}
			fs, err := analysis.ReadFormation(dir, tm)
			if err != nil {
				log.Fatal(err)
			}
			fmt.Print(analysis.FormationProfile(label, fs))
			all = append(all, struct {
				label string
				fs    []analysis.FormSample
			}{label, fs})
		}
		for _, a := range all {
			fmt.Printf("\n### %s\n\n%s\n%s\n%s", a.label,
				analysis.FormationBins(a.fs, "Shooting advantage (share able to shoot, ours - theirs)", func(f analysis.FormSample) float64 { return f.Advantage() }, []float64{-1, -0.5, -0.25, -0.1, 0.1, 0.25, 0.5, 1.01}),
				analysis.FormationBins(a.fs, "Width / depth (line vs column)", func(f analysis.FormSample) float64 { return f.OwnForm.Width / math.Max(f.OwnForm.Depth, 1) }, []float64{0, 0.5, 0.8, 1.25, 2, 4, math.Inf(1)}),
				analysis.FormationBins(a.fs, "Spread per sqrt(units) (elmos)", func(f analysis.FormSample) float64 { return f.OwnForm.Spread / math.Sqrt(float64(f.OwnForm.N)) }, []float64{0, 40, 70, 100, 150, 250, math.Inf(1)}))
		}
		return
	}
	if *micro != "" {
		samples, err := analysis.ReadMicro(*micro)
		if err != nil {
			log.Fatal(err)
		}
		kinds := analysis.MicroByKind(samples, 50)
		if *asJSON {
			printJSON(kinds)
			return
		}
		names := analysis.MicroByName(samples, 150)
		if len(names) > 25 {
			names = names[:25]
		}
		fmt.Printf("%d micro samples\n\n%s\nBy unit (most sampled):\n\n%s\nSuggested D.micro:\n\n%s", len(samples), analysis.MicroText(kinds), analysis.MicroText(names), analysis.MicroDoctrine(kinds))
		if fire, err := analysis.ReadFire(*micro); err == nil && len(fire) > 0 {
			fmt.Printf("\n%s", analysis.FireText(analysis.FireSummary(fire, 2, 1.2), 2, 1.2))
		}
		if cs, err := analysis.ReadCommit(*micro); err == nil && len(cs) > 0 {
			if *team >= 0 {
				// our own games: only our side's fights (the enemy's are seen through our sight only)
				kept := cs[:0]
				for _, c := range cs {
					if c.Team == *team {
						kept = append(kept, c)
					}
				}
				cs = kept
			}
			fmt.Printf("\nCommit (%d fights): how groups move at each strength ratio, and how it traded\n\n%s", len(cs), analysis.CommitText(analysis.CommitByRatio(cs, analysis.CommitBounds)))
		}
		return
	}
	if *benchFrom != "" {
		buildBenchmark(*benchFrom, *benchOut, *benchDesc, *playbookOut)
		return
	}
	if flag.NArg() == 0 {
		flag.Usage()
		os.Exit(2)
	}
	bench := analysis.ProDuel()
	if *benchFile != "" {
		data, err := os.ReadFile(*benchFile)
		if err != nil {
			log.Fatal(err)
		}
		bench = &analysis.Benchmark{}
		if err := json.Unmarshal(data, bench); err != nil {
			log.Fatal(err)
		}
	}
	if *battles {
		analysis.BattlesText(os.Stdout, load(flag.Args()))
		return
	}
	if *timeline {
		for _, g := range load(flag.Args()) {
			if *asJSON {
				printJSON(map[string]any{"game": g.Source, "result": g.Result, "detail": g.Detail, "seconds": g.Seconds, "minutes": analysis.Timeline(g)})
			} else {
				fmt.Print(analysis.TimelineText(g))
			}
		}
		return
	}
	if *compare {
		var arms []analysis.Arm
		for _, dir := range flag.Args() {
			arms = append(arms, analysis.Arm{Label: filepath.Base(dir), Games: load([]string{dir})})
		}
		if *asJSON {
			out := map[string]any{}
			for _, a := range arms {
				out[a.Label] = analysis.BuildReport(a.Label, a.Games, bench)
			}
			out["verdicts"] = analysis.Verdicts(arms)
			printJSON(out)
			return
		}
		analysis.Compare(os.Stdout, arms)
		analysis.WriteVerdicts(os.Stdout, arms)
		return
	}
	games := load(flag.Args())
	if len(games) == 0 {
		log.Fatal("no games found")
	}
	if *title == "" {
		*title = "Games: " + strings.Join(flag.Args(), ", ")
	}
	if *asJSON {
		printJSON(analysis.BuildReport(*title, games, bench))
		return
	}
	analysis.Report(os.Stdout, *title, games, bench)
}

func printJSON(v any) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", " ")
	if err := enc.Encode(v); err != nil {
		log.Fatal(err)
	}
}

// load reads harness logs: files, or every *.txt in directories.
func load(args []string) []*analysis.Game {
	var files []string
	for _, a := range args {
		st, err := os.Stat(a)
		if err != nil {
			log.Fatal(err)
		}
		if st.IsDir() {
			// game logs are <n>.txt (meta.txt describes the batch)
			m, _ := filepath.Glob(filepath.Join(a, "[0-9]*.txt"))
			sort.Slice(m, func(i, j int) bool { return natural(m[i]) < natural(m[j]) })
			files = append(files, m...)
		} else {
			files = append(files, a)
		}
	}
	var games []*analysis.Game
	for _, f := range files {
		r, err := os.Open(f)
		if err != nil {
			log.Fatal(err)
		}
		g, err := analysis.ParseGame(strings.TrimSuffix(filepath.Base(f), ".txt"), r)
		r.Close()
		if err != nil {
			log.Fatalf("%s: %v", f, err)
		}
		games = append(games, g)
	}
	return games
}

// natural sorts "2.txt" before "10.txt".
func natural(path string) string {
	base := strings.TrimSuffix(filepath.Base(path), ".txt")
	return fmt.Sprintf("%s/%08s", filepath.Dir(path), base)
}

func buildBenchmark(dir, out, desc, playbookOut string) {
	files, _ := filepath.Glob(filepath.Join(dir, "*.jsonl"))
	var recs []*analysis.Recorded
	for _, f := range files {
		r, err := os.Open(f)
		if err != nil {
			log.Fatal(err)
		}
		rec, err := analysis.ParseDatalog(filepath.Base(f), r)
		r.Close()
		if err != nil {
			log.Fatal(err)
		}
		recs = append(recs, rec)
	}
	b := analysis.BuildBenchmark(desc, recs)
	data, _ := json.MarshalIndent(b, "", " ")
	if err := os.WriteFile(out, append(data, '\n'), 0o644); err != nil {
		log.Fatal(err)
	}
	if playbookOut != "" {
		f, err := os.Create(playbookOut)
		if err != nil {
			log.Fatal(err)
		}
		analysis.Playbook(f, recs, b)
		if err := f.Close(); err != nil {
			log.Fatal(err)
		}
		fmt.Println("playbook:", playbookOut)
	}
	fmt.Printf("%s: %d games, %d players\n\n| Minute | metal income | extractors | factories | constructors | army value |\n|---|---|---|---|---|---|\n", out, b.Games, b.Players)
	for _, minute := range analysis.PaceMinutes {
		var row strings.Builder
		fmt.Fprintf(&row, "| %d |", minute)
		for _, m := range []string{"metalIncome", "mex", "factories", "builders", "army"} {
			band, ok := b.Band(minute, m)
			if !ok {
				row.WriteString(" - |")
				continue
			}
			fmt.Fprintf(&row, " %g (%g-%g) |", band.P50, band.P25, band.P75)
		}
		fmt.Println(row.String())
	}
}
