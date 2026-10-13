package analysis

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Roles: what each player of a team game specialises in (from the data logger's build, turretbuild, eco
// and teams samples of replays), so a team of sub-commanders can split the work the way strong teams do.

// PlayerRole is one player of one game.
type PlayerRole struct {
	Game     string  `json:"game"`
	Team     int     `json:"team"`
	Ally     int     `json:"ally"`
	Side     string  `json:"side"`
	SideSize int     `json:"sideSize"` // players on its side
	Ground   float64 `json:"ground"`   // metal of ground units started
	Air      float64 `json:"air"`
	Naval    float64 `json:"naval"`
	Turrets  float64 `json:"turrets"`
	Mex      int     `json:"mex"`      // extractors at its last eco sample
	AirStart float64 `json:"airStart"` // minute of its first armed plane (-1 none)
	Role     string  `json:"role"`
}

type option struct {
	Name string  `json:"name"`
	Kind string  `json:"kind"`
	Cost float64 `json:"cost"`
	Air  bool    `json:"air"`
}

type roleLine struct {
	Type    string   `json:"type"`
	Game    string   `json:"game"`
	Frame   int      `json:"frame"`
	Team    int      `json:"team"`
	Chosen  string   `json:"chosen"`
	Options []option `json:"options"`
	Mex     int      `json:"mex"`
	Teams   []struct {
		Team int    `json:"team"`
		Ally int    `json:"ally"`
		Side string `json:"side"`
	} `json:"teams"`
}

// ReadRoles reads every JSONL file in dir and labels each player of each game.
func ReadRoles(dir string) ([]PlayerRole, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.jsonl"))
	if err != nil {
		return nil, err
	}
	var out []PlayerRole
	for _, f := range files {
		fh, err := os.Open(f)
		if err != nil {
			return nil, err
		}
		players := map[int]*PlayerRole{}
		player := func(t int) *PlayerRole {
			if players[t] == nil {
				players[t] = &PlayerRole{Game: filepath.Base(f), Team: t, AirStart: -1}
			}
			return players[t]
		}
		hasTeams := false
		sc := bufio.NewScanner(fh)
		sc.Buffer(make([]byte, 1<<20), 1<<24)
		for sc.Scan() {
			line := sc.Text()
			if !strings.Contains(line, `"type":"build"`) && !strings.Contains(line, `"type":"turretbuild"`) &&
				!strings.Contains(line, `"type":"eco"`) && !strings.Contains(line, `"type":"teams"`) {
				continue
			}
			var l roleLine
			if json.Unmarshal([]byte(line), &l) != nil {
				continue
			}
			switch l.Type {
			case "teams":
				hasTeams = true
				for _, t := range l.Teams {
					p := player(t.Team)
					p.Ally, p.Side = t.Ally, t.Side
				}
			case "eco":
				player(l.Team).Mex = l.Mex
			case "build", "turretbuild":
				var chosen *option
				for i := range l.Options {
					if l.Options[i].Name == l.Chosen {
						chosen = &l.Options[i]
					}
				}
				if chosen == nil {
					continue
				}
				p := player(l.Team)
				switch {
				case l.Type == "turretbuild":
					p.Turrets += chosen.Cost
				case chosen.Air:
					p.Air += chosen.Cost
					if p.AirStart < 0 {
						p.AirStart = float64(l.Frame) / 1800
					}
				case strings.Contains(chosen.Kind, "naval"):
					p.Naval += chosen.Cost
				default:
					p.Ground += chosen.Cost
				}
			}
		}
		err = sc.Err()
		fh.Close()
		if err != nil {
			return nil, fmt.Errorf("%s: %w", f, err)
		}
		if !hasTeams {
			continue // older logs: no alliances, no roles
		}
		size := map[int]int{}
		for _, p := range players {
			size[p.Ally]++
		}
		// eco: the side's most extractors while building less army than the side's average
		armyAvg, topMex := map[int]float64{}, map[int]int{}
		for _, p := range players {
			armyAvg[p.Ally] += (p.Ground + p.Air + p.Naval) / float64(size[p.Ally])
			topMex[p.Ally] = max(topMex[p.Ally], p.Mex)
		}
		for _, p := range players {
			p.SideSize = size[p.Ally]
			units := p.Ground + p.Air + p.Naval
			total := units + p.Turrets
			switch {
			case total < 500:
				p.Role = "idle"
			case p.Air >= 0.4*units:
				p.Role = "air"
			case p.Naval >= 0.4*units:
				p.Role = "naval"
			case p.Turrets >= 0.35*total:
				p.Role = "defense"
			case p.SideSize > 1 && p.Mex == topMex[p.Ally] && units < armyAvg[p.Ally]:
				p.Role = "eco"
			default:
				p.Role = "ground"
			}
			out = append(out, *p)
		}
	}
	return out, nil
}

// RolesText: by side size, how players split into roles, how often a side has an air player, when air starts.
func RolesText(players []PlayerRole) string {
	bySize := map[int][]PlayerRole{}
	for _, p := range players {
		bySize[p.SideSize] = append(bySize[p.SideSize], p)
	}
	sizes := make([]int, 0, len(bySize))
	for s := range bySize {
		sizes = append(sizes, s)
	}
	sort.Ints(sizes)
	roles := []string{"ground", "air", "eco", "defense", "naval", "idle"}
	var b strings.Builder
	b.WriteString("| Players per side | Players | ground | air | eco | defense | naval | idle | Sides with an air player | First armed plane (median minute) |\n")
	b.WriteString("|---|---|---|---|---|---|---|---|---|---|\n")
	for _, s := range sizes {
		list := bySize[s]
		count := map[string]int{}
		sidesAir, sides := map[string]bool{}, map[string]bool{}
		var airStart []float64
		for _, p := range list {
			count[p.Role]++
			key := fmt.Sprintf("%s/%d", p.Game, p.Ally)
			sides[key] = true
			if p.Role == "air" {
				sidesAir[key] = true
			}
			if p.AirStart >= 0 {
				airStart = append(airStart, p.AirStart)
			}
		}
		fmt.Fprintf(&b, "| %d | %d |", s, len(list))
		for _, r := range roles {
			fmt.Fprintf(&b, " %.0f%% |", 100*share(count[r], len(list)))
		}
		fmt.Fprintf(&b, " %.0f%% | %.1f |\n", 100*share(len(sidesAir), len(sides)), microQ(airStart, 0.5))
	}
	return b.String()
}
