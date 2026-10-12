package mapview

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image/jpeg"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// synthetic 12288 x 12288 map: rolling hills, a lake in the south-west, a cliff
// ridge across the middle with a gap, a plateau in the north-east
func testTerrain(x1, z1, x2, z2 float64, cells int) []byte {
	step := max(x2-x1, z2-z1) / float64(cells)
	w, h := int(math.Ceil((x2-x1)/step)), int(math.Ceil((z2-z1)/step))
	var hs []string
	for j := range h {
		z := z1 + (float64(j)+0.5)*step
		for i := range w {
			x := x1 + (float64(i)+0.5)*step
			v := 80 + 40*math.Sin(x/900)*math.Cos(z/1100)
			if d := math.Hypot(x-2500, z-9500); d < 2000 {
				v -= 260 * (1 - d/2000)
			}
			if math.Abs(z-6000) < 150 && math.Abs(x-6000) > 700 {
				v += 220 * (1 - math.Abs(z-6000)/150)
			}
			if x > 8500 && z < 3500 {
				v += 160
			}
			hs = append(hs, fmt.Sprint(int(v)))
		}
	}
	data, _ := json.Marshal(map[string]any{"x1": x1, "z1": z1, "x2": x2, "z2": z2, "w": w, "h": h, "step": step, "heights": strings.Join(hs, ",")})
	return data
}

func testScene(x1, z1, x2, z2 float64) *Scene {
	s := &Scene{}
	s.Bounds.X1, s.Bounds.Z1, s.Bounds.X2, s.Bounds.Z2 = x1, z1, x2, z2
	s.Subs = []Sub{{ID: 1, Name: "Economy 1", Color: []float64{1, 0.76, 0.2}}, {ID: 2, Name: "Defense 2", Color: []float64{0.3, 0.8, 1}}}
	s.Zones = []SubZone{
		{Sub: 1, Zone: Zone{Kind: "circle", X: 3000, Z: 3000, R: 1100}},
		{Sub: 2, Zone: Zone{Kind: "rect", X1: 4500, Z1: 5200, X2: 7500, Z2: 6800}},
	}
	for i := range 8 {
		taken := []string{"free", "own", "free", "ally", "enemy", "own", "free", "free"}[i]
		s.Metal = append(s.Metal, Spot{X: 2200 + float64(i%4)*500, Z: 2400 + float64(i/4)*900, Taken: taken})
	}
	s.Metal = append(s.Metal, Spot{X: 10000, Z: 10000, Taken: "enemy"})
	s.Units = []Unit{
		{X: 3000, Z: 3000, HX: 48, HZ: 48, Facing: 0, Side: "own", Structure: true, Factory: true, Kind: "factory"},
		{X: 3000, Z: 3150, HX: 16, HZ: 16, Side: "own", Sub: 1, Structure: true, Kind: "converter", Marked: true},
		{X: 3300, Z: 2800, HX: 24, HZ: 24, Side: "own", Sub: 1, Structure: true, Kind: "energy"},
		{X: 2700, Z: 3300, Side: "own", Sub: 1, Kind: "constructor"},
		{X: 5200, Z: 5800, HX: 16, HZ: 16, Side: "own", Sub: 2, Structure: true, Kind: "defense turret"},
		{X: 6000, Z: 5900, Side: "own", Sub: 2, Kind: "combat"},
		{X: 6100, Z: 5950, Side: "own", Sub: 2, Kind: "combat"},
		{X: 1500, Z: 1500, HX: 40, HZ: 40, Facing: 1, Side: "ally", Structure: true, Factory: true},
	}
	s.Enemies = []Enemy{{X: 9000, Z: 9000, Known: true}, {X: 9200, Z: 9100, Known: true, Structure: true}, {X: 8000, Z: 7000, Air: true, Known: true}, {X: 7000, Z: 8000}}
	s.Intel.RecentSightings = []Sighting{{X: 8500, Z: 6500, Sightings: 3, NewestSecondsAgo: 42}}
	s.Intel.StartPositions = []Point{{X: 10500, Z: 10500}}
	return s
}

func TestRender(t *testing.T) {
	out := os.Getenv("MAPVIEW_OUT") // set to a directory to look at the pictures
	for _, v := range []struct {
		name           string
		x1, z1, x2, z2 float64
		cells          int
	}{
		{"map", 0, 0, 12288, 12288, 256},
		{"zones", 1500, 1500, 8200, 8200, 160},
	} {
		terrain, err := ParseTerrain(testTerrain(v.x1, v.z1, v.x2, v.z2, v.cells))
		if err != nil {
			t.Fatal(err)
		}
		pic, desc, err := Render(terrain, testScene(v.x1, v.z1, v.x2, v.z2), Options{Title: "Test Map", Focus: 1})
		if err != nil {
			t.Fatal(err)
		}
		img, err := jpeg.Decode(bytes.NewReader(pic))
		if err != nil {
			t.Fatal(err)
		}
		if b := img.Bounds(); b.Dx() != mapPx+marginL+marginR || b.Dy() != mapPx+marginT+marginB {
			t.Errorf("%s: size %v", v.name, b)
		}
		if !strings.Contains(desc, "you are #1") {
			t.Errorf("%s: description %q", v.name, desc)
		}
		if out != "" {
			if err := os.WriteFile(filepath.Join(out, v.name+".jpg"), pic, 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
}

func TestParseTerrainRejectsShortGrid(t *testing.T) {
	if _, err := ParseTerrain([]byte(`{"w":3,"h":3,"step":10,"heights":"1,2,3"}`)); err == nil {
		t.Fatal("want error")
	}
}
