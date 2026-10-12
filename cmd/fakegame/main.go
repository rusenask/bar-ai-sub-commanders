// Command fakegame stands in for the BAR widget when testing scbridge: it
// connects, reports a scripted sub-commander and prints the actions it gets.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
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
			args, _ := json.Marshal(m["args"])
			fmt.Printf("ACTION sub=%v op=%v args=%s\n", m["sub"], m["op"], args)
			result := map[string]any{"type": "result", "id": m["id"], "ok": true}
			switch m["op"] {
			case "set_posture":
				if a, ok := m["args"].(map[string]any); ok {
					posture, _ = a["posture"].(string)
				}
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
