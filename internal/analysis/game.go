// Package analysis reads test games (the harness log, testenv/sctest_out.txt) and recorded games (the data
// logger's JSONL, e.g. strong players' replays) and reports how a game went: economy pace against strong
// players, losses, stalls and the sub-commanders' recurring problems. cmd/gamereport is its command line.
package analysis

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Eco is one team's economy at a minute, in the data logger's terms (zz_datalog.lua "eco" records and the
// harness's "eco" lines use the same unit classification).
type Eco struct {
	Minute        int     `json:"minute"`
	MetalIncome   float64 `json:"metalIncome"`
	EnergyIncome  float64 `json:"energyIncome"`
	Mex           int     `json:"mex"`
	Generators    int     `json:"generators"`
	Factories     int     `json:"factories"`
	Builders      int     `json:"builders"`
	Army          float64 `json:"army"`
	Turrets       float64 `json:"turrets"`
	EnergyStalled int     `json:"energyStalled,omitempty"` // seconds so far with energy near empty (harness only)
	MetalOverflow int     `json:"metalOverflow,omitempty"` // seconds so far with metal storage full (harness only)
	Partial       bool    `json:"-"`                       // only income known (older harness logs)
}

// Death is a unit we lost or killed (harness "lost" / "killed" lines).
type Death struct {
	Minute int
	Kind   string
	Name   string
	Cost   int
}

// Game is one test game as the harness logged it.
type Game struct {
	Source  string
	Result  string // WIN, LOSS, TIMEOUT or "" when the game didn't finish
	Detail  string // e.g. "(no units left)"
	Seconds int
	Stats   map[string]float64 // final "us:" line: metalProduced, unitsKilled, unitsDied, damageDealt, ...
	Eco     []Eco
	Lost    []Death
	Killed  []Death
	Player  []string       // the scripted player's actions, in order
	Errors  []string       // harness errors
	Logs    map[string]int // sub-commander log messages (numbers stripped) -> times seen
}

var (
	reFrame  = regexp.MustCompile(`^\[(\d+)\] (.*)$`)
	reTime   = regexp.MustCompile(`^t=(\d+)s metal [\d.]+/[\d.]+ \+([\d.-]+) energy [\d.]+/[\d.]+ \+([\d.-]+)`)
	reResult = regexp.MustCompile(`^RESULT (\w+)(.*?)(?: t=(\d+)s)?$`)
	reSub    = regexp.MustCompile(`^  \[(\d+)\] `)
	reDigits = regexp.MustCompile(`\d+`)
)

// keyValues parses "a=1 b=x" into a map.
func keyValues(s string) map[string]string {
	kv := map[string]string{}
	for f := range strings.FieldsSeq(s) {
		if k, v, ok := strings.Cut(f, "="); ok {
			kv[k] = v
		}
	}
	return kv
}

func num(kv map[string]string, k string) float64 {
	f, _ := strconv.ParseFloat(kv[k], 64)
	return f
}

// ParseGame reads a harness log (sctest_out.txt, testenv/batch/.../<n>.txt).
func ParseGame(source string, r io.Reader) (*Game, error) {
	g := &Game{Source: source, Stats: map[string]float64{}, Logs: map[string]int{}}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	ecoLines := false
	var incomes []Eco                        // from the 30 s status lines, for logs without eco lines
	prevLogs := map[string]map[string]bool{} // sub -> messages in its previous snapshot
	curLogs := map[string]map[string]bool{}
	sub := ""
	for sc.Scan() {
		line := sc.Text()
		m := reFrame.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		body := m[2]
		switch {
		case strings.HasPrefix(body, "eco "):
			kv := keyValues(body[4:])
			ecoLines = true
			g.Eco = append(g.Eco, Eco{
				Minute: int(num(kv, "minute")), MetalIncome: num(kv, "metalIncome"), EnergyIncome: num(kv, "energyIncome"),
				Mex: int(num(kv, "mex")), Generators: int(num(kv, "generators")), Factories: int(num(kv, "factories")),
				Builders: int(num(kv, "builders")), Army: num(kv, "army"), Turrets: num(kv, "turrets"),
				EnergyStalled: int(num(kv, "energyStalled")), MetalOverflow: int(num(kv, "metalOverflow")),
			})
		case strings.HasPrefix(body, "lost "), strings.HasPrefix(body, "killed "):
			verb, rest, _ := strings.Cut(body, " ")
			kv := keyValues(rest)
			d := Death{Minute: int(num(kv, "minute")), Kind: strings.ReplaceAll(kv["kind"], "_", " "), Name: kv["name"], Cost: int(num(kv, "cost"))}
			if verb == "lost" {
				g.Lost = append(g.Lost, d)
			} else {
				g.Killed = append(g.Killed, d)
			}
		case reTime.MatchString(body):
			t := reTime.FindStringSubmatch(body)
			sec, _ := strconv.Atoi(t[1])
			mi, _ := strconv.ParseFloat(t[2], 64)
			ei, _ := strconv.ParseFloat(t[3], 64)
			if sec > 0 && sec%60 == 0 {
				incomes = append(incomes, Eco{Minute: sec / 60, MetalIncome: mi, EnergyIncome: ei, Partial: true})
			}
			// a new status snapshot: the sub-commanders' logs that follow are compared with the last one
			prevLogs, curLogs = curLogs, map[string]map[string]bool{}
		case strings.HasPrefix(body, "RESULT "):
			r := reResult.FindStringSubmatch(body)
			if r != nil {
				g.Result, g.Detail = r[1], strings.TrimSpace(r[2])
				g.Seconds, _ = strconv.Atoi(r[3])
			}
		case strings.HasPrefix(body, "  us:"):
			for k, v := range keyValues(body[5:]) {
				g.Stats[k], _ = strconv.ParseFloat(v, 64)
			}
		case strings.HasPrefix(body, "player: "):
			g.Player = append(g.Player, body[8:])
		case strings.HasPrefix(body, "HARNESS ERROR"):
			g.Errors = append(g.Errors, body)
		case reSub.MatchString(body):
			sub = reSub.FindStringSubmatch(body)[1]
		case strings.HasPrefix(body, "     log: "), strings.HasPrefix(body, "     AI: "):
			msg := strings.TrimSpace(body[strings.Index(body, ":")+1:])
			if curLogs[sub] == nil {
				curLogs[sub] = map[string]bool{}
			}
			curLogs[sub][msg] = true
			// the harness prints each sub-commander's latest few messages every 30 s: count the new ones
			if !prevLogs[sub][msg] {
				g.Logs[normalize(msg)]++
			}
		}
	}
	if !ecoLines {
		g.Eco = incomes
	}
	return g, sc.Err()
}

// normalize strips numbers and positions so repeats of a message count together.
func normalize(msg string) string {
	return reDigits.ReplaceAllString(msg, "#")
}

// Recorded is a game from the data logger (zz_datalog.lua): one economy series per team, and what each
// team's factories and constructors started (combat units and turrets).
type Recorded struct {
	Source string
	Map    string
	Teams  map[int][]Eco
	Builds []Build
}

// Build is a combat unit or turret a team started.
type Build struct {
	Team   int
	Minute int
	Turret bool
	Name   string  `json:"name"`
	Human  string  `json:"human"`
	Kind   string  `json:"kind"`
	Cost   float64 `json:"cost"`
	Tech   int     `json:"tech"`
	Air    bool    `json:"air"`
}

// ParseDatalog reads the data logger's JSONL (testenv/data/pro/<id>.jsonl).
func ParseDatalog(source string, r io.Reader) (*Recorded, error) {
	rec := &Recorded{Source: source, Teams: map[int][]Eco{}}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 4<<20), 4<<20)
	for sc.Scan() {
		var head struct {
			Type    string  `json:"type"`
			Team    int     `json:"team"`
			Map     string  `json:"map"`
			Frame   int     `json:"frame"`
			Chosen  string  `json:"chosen"`
			Options []Build `json:"options"`
		}
		if json.Unmarshal(sc.Bytes(), &head) != nil {
			continue
		}
		switch head.Type {
		case "start":
			rec.Map = head.Map
		case "eco":
			var e Eco
			if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
				return nil, fmt.Errorf("%s: %w", source, err)
			}
			rec.Teams[head.Team] = append(rec.Teams[head.Team], e)
		case "build", "turretbuild":
			for _, o := range head.Options {
				if o.Name == head.Chosen {
					o.Team, o.Minute, o.Turret = head.Team, head.Frame/1800, head.Type == "turretbuild"
					rec.Builds = append(rec.Builds, o)
				}
			}
		}
	}
	for t, s := range rec.Teams {
		sort.Slice(s, func(i, j int) bool { return s[i].Minute < s[j].Minute })
		rec.Teams[t] = s
	}
	return rec, sc.Err()
}

// At returns a series' economy at a minute (nil if the game hadn't reached it).
func At(series []Eco, minute int) *Eco {
	for i := range series {
		if series[i].Minute == minute {
			return &series[i]
		}
	}
	return nil
}
