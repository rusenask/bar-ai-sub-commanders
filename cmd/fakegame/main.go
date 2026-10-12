// Command fakegame stands in for the BAR widget when testing scbridge: it
// connects, reports a scripted sub-commander and prints the actions it gets.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:7878", "scbridge game address")
	duration := flag.Duration("for", 90*time.Second, "how long to run")
	flag.Parse()

	conn, err := net.Dial("tcp", *addr)
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close()
	enc := json.NewEncoder(conn)

	frame := 30 * 240
	posture := "balanced"
	send := func(v any) {
		if err := enc.Encode(v); err != nil {
			log.Fatal(err)
		}
	}
	state := func() map[string]any {
		return map[string]any{"type": "state", "state": map[string]any{
			"frame":   frame,
			"paused":  false,
			"economy": map[string]any{"metal": 1420, "metalStorage": 1450, "metalIncome": 14.8, "energy": 1200, "energyStorage": 1260, "energyIncome": 260},
			"subs": []map[string]any{{
				"id": 1, "name": "Economy 1", "role": "economy", "posture": posture, "ai": true,
				"directive":  "expand to the metal field east of the base but stay out of the north",
				"status":     "metal is overflowing: give me a factory or more roles to spend it",
				"zones":      []map[string]any{{"kind": "circle", "x": 4600, "z": 2000, "r": 1100, "cx": 4600, "cz": 2000, "metalSpots": 7, "freeMetalSpots": 0, "ownStructures": 31, "groundDefenses": 0, "airDefenses": 0}},
				"counts":     map[string]any{"builders": 1, "factories": 0, "combat": 0, "nanos": 0, "statics": 30, "total": 31},
				"spendMetal": 0.0, "threats": 0, "airThreats": 0, "unitCount": 31,
				"composition": [][]any{{"Legion Commander", 1}},
				"activity":    [][]any{{"nothing to do", 1}},
				"recent": []map[string]any{
					{"frame": frame - 300, "text": "metal is overflowing: give me a factory or more roles to spend it", "count": 1, "ai": false},
					{"frame": frame - 900, "text": "Wind Turbine (energy)", "count": 6, "ai": false},
				},
			}, {
				"id": 2, "name": "Defense 2", "role": "defense", "posture": "balanced", "ai": false,
				"zones":   []map[string]any{{"kind": "rect", "x1": 3700, "z1": 500, "x2": 5500, "z2": 1400}},
				"counts":  map[string]any{"builders": 2, "factories": 0, "combat": 0, "nanos": 0, "statics": 4, "total": 6},
				"threats": 0, "unitCount": 6, "recent": []any{},
			}},
			"enemy": map[string]any{"recentSightings": []any{}, "startPositions": []map[string]any{{"x": 4600, "z": 7400}}},
		}}
	}

	send(map[string]any{"type": "hello", "game": map[string]any{"protocol": 1, "map": "All That Simmers v1.1.1", "mapX": 8192, "mapZ": 8192, "team": 0, "faction": "Legion", "player": "Tester", "frame": frame}})
	send(state())

	lines := make(chan map[string]any)
	go func() {
		sc := bufio.NewScanner(conn)
		for sc.Scan() {
			var m map[string]any
			if json.Unmarshal(sc.Bytes(), &m) == nil {
				lines <- m
			}
		}
		if err := sc.Err(); err != nil {
			log.Print(err)
		}
		close(lines)
	}()

	tick := time.NewTicker(3 * time.Second)
	defer tick.Stop()
	end := time.After(*duration)
	for {
		select {
		case <-end:
			return
		case <-tick.C:
			frame += 90
			send(state())
		case m, ok := <-lines:
			if !ok {
				fmt.Println("bridge closed the connection")
				os.Exit(1)
			}
			switch m["type"] {
			case "config":
				fmt.Printf("CONFIG %v\n", m["args"])
				if a, ok := m["args"].(map[string]any); ok && a["decider"] == true {
					// what the widget asks the decision model when a factory picks its next unit
					send(map[string]any{"type": "decide", "id": -1, "sub": 1, "args": map[string]any{
						"state": "Beyond All Reason RTS. Our Army sub-commander's factory is choosing its next unit. Enemy units seen in the last 5 minutes: 6 assault, 4 bomber. First seen in the last 3 minutes: 4 bomber. Our units: 8 assault.",
						"questions": map[string]any{"unit": map[string]any{"type": "choice", "instructions": "Which unit should the factory build next?",
							"criteria": map[string]any{"legaabot": "mobile anti-air: shoots aircraft only, good against bombers", "legkark": "heavy: armored, good against assault units", "leggob": "raider: fast and cheap"}}},
					}})
				}
				continue
			case "decision":
				fmt.Printf("DECISION ok=%v data=%v error=%v\n", m["ok"], m["data"], m["error"])
				continue
			}
			args, _ := json.Marshal(m["args"])
			fmt.Printf("ACTION sub=%v op=%v args=%s\n", m["sub"], m["op"], args)
			result := map[string]any{"type": "result", "id": m["id"], "ok": true}
			switch m["op"] {
			case "set_posture":
				if a, ok := m["args"].(map[string]any); ok {
					posture, _ = a["posture"].(string)
				}
			case "map_view":
				a, _ := m["args"].(map[string]any)
				view, _ := a["view"].(string)
				result["data"] = mapView(view)
			case "terrain":
				a, _ := m["args"].(map[string]any)
				result["data"] = terrain(a)
			case "build_options":
				result["data"] = []map[string]any{
					{"name": "leglab", "human": "Bot Lab", "kind": "factory", "by": "constructors", "metal": 600, "energy": 1200, "tech": 1},
					{"name": "legmex", "human": "Metal Extractor", "kind": "metal extractor", "by": "constructors", "metal": 50, "energy": 500, "tech": 1},
				}
			}
			send(result)
		}
	}
}

// mapView is a scripted answer to the map_view op: the base in the north,
// a free metal field to the east, the enemy in the south.
func mapView(view string) map[string]any {
	bounds := map[string]any{"x1": 0, "z1": 0, "x2": 8192, "z2": 8192}
	if view == "zones" {
		bounds = map[string]any{"x1": 2800, "z1": 200, "x2": 6400, "z2": 3800}
	}
	var metal []map[string]any
	for i := range 7 {
		a := float64(i) / 7 * 2 * math.Pi
		metal = append(metal, map[string]any{"x": 4600 + 700*math.Cos(a), "z": 2000 + 700*math.Sin(a), "taken": "own"})
	}
	for i := range 4 {
		metal = append(metal, map[string]any{"x": 6600 + 250*float64(i%2), "z": 2200 + 300*float64(i/2), "taken": "free"})
	}
	units := []map[string]any{
		{"x": 4600, "z": 2000, "hx": 16, "hz": 16, "side": "own", "sub": 1, "structure": false, "kind": "constructor"},
		{"x": 4300, "z": 1500, "hx": 48, "hz": 40, "facing": 0, "side": "own", "sub": 0, "structure": true, "factory": true, "kind": "factory"},
		{"x": 4300, "z": 1640, "hx": 16, "hz": 16, "side": "own", "sub": 1, "structure": true, "kind": "converter", "marked": true},
	}
	for i := range 6 {
		units = append(units, map[string]any{"x": 4900 + 60*float64(i%3), "z": 2300 + 60*float64(i/3), "hx": 24, "hz": 24, "side": "own", "sub": 1, "structure": true, "kind": "energy"})
	}
	return map[string]any{
		"bounds": bounds,
		"subs":   []map[string]any{{"id": 1, "name": "Economy 1", "color": []float64{1, 0.76, 0.2}}, {"id": 2, "name": "Defense 2", "color": []float64{0.3, 0.8, 1}}},
		"zones": []map[string]any{
			{"sub": 1, "zone": map[string]any{"kind": "circle", "x": 4600, "z": 2000, "r": 1100}},
			{"sub": 2, "zone": map[string]any{"kind": "rect", "x1": 3700, "z1": 500, "x2": 5500, "z2": 1400}},
		},
		"metal":   metal,
		"units":   units,
		"enemies": []map[string]any{{"x": 4500, "z": 6900, "known": true, "structure": true}, {"x": 4300, "z": 5600, "known": true}},
		"intel":   map[string]any{"recentSightings": []map[string]any{{"x": 5200, "z": 4800, "sightings": 4, "newestSecondsAgo": 35}}, "startPositions": []map[string]any{{"x": 4600, "z": 7400}}},
	}
}

// terrain answers the terrain op: hills, a river between the bases with one
// ford, and a cliff edged plateau to the east of the base.
func terrain(a map[string]any) map[string]any {
	num := func(k string, def float64) float64 {
		if v, ok := a[k].(float64); ok {
			return v
		}
		return def
	}
	x1, z1, x2, z2, cells := num("x1", 0), num("z1", 0), num("x2", 8192), num("z2", 8192), num("cells", 256)
	step := max(x2-x1, z2-z1) / cells
	w, h := int(math.Ceil((x2-x1)/step)), int(math.Ceil((z2-z1)/step))
	hs := make([]string, 0, w*h)
	for j := range h {
		z := z1 + (float64(j)+0.5)*step
		for i := range w {
			x := x1 + (float64(i)+0.5)*step
			v := 90 + 35*math.Sin(x/700)*math.Cos(z/900)
			if d := math.Abs(z - 4300 - 300*math.Sin(x/1200)); d < 350 && math.Abs(x-2000) > 250 {
				v -= 150 * (1 - d/350)
			}
			if x > 6000 && z > 1200 && z < 3200 {
				v += 140
			}
			hs = append(hs, strconv.Itoa(int(v)))
		}
	}
	return map[string]any{"x1": x1, "z1": z1, "x2": x2, "z2": z2, "w": w, "h": h, "step": step, "heights": strings.Join(hs, ",")}
}
