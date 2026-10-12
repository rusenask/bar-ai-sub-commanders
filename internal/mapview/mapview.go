// Package mapview draws a top-down picture of the battlefield for the
// strategist: shaded terrain from a height grid, a coordinate grid labelled in
// elmos, zones, metal spots, our and allied units and what we know of the enemy.
package mapview

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"math"
	"strconv"
	"strings"

	"golang.org/x/image/font"
	"golang.org/x/image/font/basicfont"
	"golang.org/x/image/math/fixed"
)

// Terrain is a grid of ground heights over X1..X2, Z1..Z2, sampled at cell
// centres, row by row from Z1.
type Terrain struct {
	X1, Z1, X2, Z2 float64
	W, H           int
	Step           float64
	Heights        []float64
}

// ParseTerrain decodes the widget's answer to the terrain op (heights come as
// one comma-separated string).
func ParseTerrain(data []byte) (*Terrain, error) {
	var raw struct {
		X1      float64 `json:"x1"`
		Z1      float64 `json:"z1"`
		X2      float64 `json:"x2"`
		Z2      float64 `json:"z2"`
		W       int     `json:"w"`
		H       int     `json:"h"`
		Step    float64 `json:"step"`
		Heights string  `json:"heights"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("terrain: %w", err)
	}
	parts := strings.Split(raw.Heights, ",")
	if raw.W < 2 || raw.H < 2 || raw.Step <= 0 || len(parts) != raw.W*raw.H {
		return nil, fmt.Errorf("terrain: %dx%d grid with %d heights", raw.W, raw.H, len(parts))
	}
	t := &Terrain{X1: raw.X1, Z1: raw.Z1, X2: raw.X2, Z2: raw.Z2, W: raw.W, H: raw.H, Step: raw.Step, Heights: make([]float64, len(parts))}
	for i, p := range parts {
		h, err := strconv.ParseFloat(p, 64)
		if err != nil {
			return nil, fmt.Errorf("terrain: height %d: %w", i, err)
		}
		t.Heights[i] = h
	}
	return t, nil
}

func (t *Terrain) at(i, j int) float64 {
	return t.Heights[min(max(j, 0), t.H-1)*t.W+min(max(i, 0), t.W-1)]
}

// Zone is a sub-commander zone in world coordinates.
type Zone struct {
	Kind string  `json:"kind"`
	X    float64 `json:"x"`
	Z    float64 `json:"z"`
	R    float64 `json:"r"`
	X1   float64 `json:"x1"`
	Z1   float64 `json:"z1"`
	X2   float64 `json:"x2"`
	Z2   float64 `json:"z2"`
}

// SubZone is one zone and the sub-commander it belongs to.
type SubZone struct {
	Sub  int  `json:"sub"`
	Zone Zone `json:"zone"`
}

// Spot is a metal spot; Taken is free, own, ally or enemy.
type Spot struct {
	X     float64 `json:"x"`
	Z     float64 `json:"z"`
	Taken string  `json:"taken"`
}

// Unit is one of ours or an ally's.
type Unit struct {
	X         float64 `json:"x"`
	Z         float64 `json:"z"`
	HX        float64 `json:"hx"`
	HZ        float64 `json:"hz"`
	Facing    int     `json:"facing"` // 0 south, 1 east, 2 north, 3 west
	Side      string  `json:"side"`   // own or ally
	Sub       int     `json:"sub"`    // owning sub-commander, 0 = none
	Structure bool    `json:"structure"`
	Factory   bool    `json:"factory"`
	Kind      string  `json:"kind"`
	Marked    bool    `json:"marked"` // queued for removal
}

// Enemy is an enemy unit we can see or have on radar right now.
type Enemy struct {
	X         float64 `json:"x"`
	Z         float64 `json:"z"`
	Known     bool    `json:"known"` // false: radar blip of unknown type
	Structure bool    `json:"structure"`
	Air       bool    `json:"air"`
}

// Sighting is a cluster of recent enemy sightings.
type Sighting struct {
	X                float64 `json:"x"`
	Z                float64 `json:"z"`
	Sightings        int     `json:"sightings"`
	NewestSecondsAgo int     `json:"newestSecondsAgo"`
}

// Point is a world position.
type Point struct {
	X float64 `json:"x"`
	Z float64 `json:"z"`
}

// Sub is a sub-commander and its colour.
type Sub struct {
	ID    int       `json:"id"`
	Name  string    `json:"name"`
	Color []float64 `json:"color"` // r, g, b in 0..1
}

// Scene is the widget's answer to the map_view op.
type Scene struct {
	Bounds struct {
		X1 float64 `json:"x1"`
		Z1 float64 `json:"z1"`
		X2 float64 `json:"x2"`
		Z2 float64 `json:"z2"`
	} `json:"bounds"`
	Subs    []Sub     `json:"subs"`
	Zones   []SubZone `json:"zones"`
	Metal   []Spot    `json:"metal"`
	Units   []Unit    `json:"units"`
	Enemies []Enemy   `json:"enemies"`
	Intel   struct {
		RecentSightings []Sighting `json:"recentSightings"`
		StartPositions  []Point    `json:"startPositions"`
	} `json:"intel"`
}

// Options control a picture.
type Options struct {
	Title string
	Focus int // the sub-commander the picture is for
}

const (
	mapPx   = 768 // long side of the map area
	marginL = 46
	marginT = 20
	marginR = 14
	marginB = 66

	// slope (rise over run) above which most vehicles / most ground units can't climb
	steepSlope = 0.40
	cliffSlope = 0.75
)

var (
	background = rgb(24, 26, 30)
	enemyRed   = rgb(240, 52, 40)
	sightColor = rgb(255, 150, 40)
	metalColor = rgb(250, 222, 60)
	allyColor  = rgb(140, 172, 235)
	ownColor   = rgb(236, 236, 236)
	white      = rgb(255, 255, 255)
	black      = rgb(16, 16, 16)
	steepTint  = rgb(132, 82, 56)
	cliffTint  = rgb(52, 40, 36)
	shallow    = rgb(86, 152, 196)
	deep       = rgb(22, 52, 106)
	landLow    = rgb(96, 138, 78)
	landMid    = rgb(160, 150, 102)
	landHigh   = rgb(208, 202, 190)
)

type canvas struct {
	img               *image.RGBA
	x1, z1, scale     float64
	left, top, mw, mh int
	subs              map[int]Sub
}

// MIMEType is the format Render produces. JPEG: a third of the size of PNG for
// shaded terrain, and every picture stays in the model's session history.
const MIMEType = "image/jpeg"

// Render draws the scene over the terrain and returns the picture plus a text
// description of how to read it.
func Render(t *Terrain, s *Scene, opts Options) ([]byte, string, error) {
	b := s.Bounds
	spanX, spanZ := b.X2-b.X1, b.Z2-b.Z1
	if spanX <= 0 || spanZ <= 0 {
		return nil, "", fmt.Errorf("empty view bounds")
	}
	scale := mapPx / max(spanX, spanZ)
	mw, mh := int(math.Round(spanX*scale)), int(math.Round(spanZ*scale))
	c := &canvas{
		img: image.NewRGBA(image.Rect(0, 0, marginL+mw+marginR, marginT+mh+marginB)),
		x1:  b.X1, z1: b.Z1, scale: scale,
		left: marginL, top: marginT, mw: mw, mh: mh,
		subs: map[int]Sub{},
	}
	for _, sub := range s.Subs {
		c.subs[sub.ID] = sub
	}
	c.fillRect(0, 0, c.img.Rect.Dx(), c.img.Rect.Dy(), background, 1)
	if t != nil {
		c.terrain(t)
	}
	grid := c.grid(spanX, spanZ)
	c.zones(s.Zones, opts.Focus)
	c.metal(s.Metal)
	c.units(s.Units)
	c.enemies(s)
	c.legend(opts, grid)

	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, c.img, &jpeg.Options{Quality: 86}); err != nil {
		return nil, "", err
	}
	free := 0
	for _, m := range s.Metal {
		if m.Taken == "free" {
			free++
		}
	}
	desc := fmt.Sprintf("Top-down picture of x %.0f..%.0f, z %.0f..%.0f elmos (x grows right = east, z grows down = south), 1 px = %.1f elmos. "+
		"Grid lines every %d elmos, labelled in elmos along the top (x) and left (z): read positions for add_zone off them. "+
		"Terrain: green low to grey high, brown = steep (most vehicles can't climb), dark brown = cliffs (impassable for most ground units), blue = water. "+
		"Zones and units are drawn in each sub-commander's colour (you are #%d), white = our units no sub-commander owns, light blue = allies, "+
		"red = enemies in sight or on radar now (squares structures, rings air or unknown radar blips), orange rings = earlier enemy sightings, red diamonds = enemy start positions. "+
		"Yellow rings = free metal spots (%d in view), filled = taken. Factories have a white tick toward their exit. Red X = queued for removal.",
		b.X1, b.X2, b.Z1, b.Z2, 1/scale, grid, opts.Focus, free)
	return buf.Bytes(), desc, nil
}

// ---- projection and primitives ----

func (c *canvas) px(x float64) float64 { return float64(c.left) + (x-c.x1)*c.scale }
func (c *canvas) py(z float64) float64 { return float64(c.top) + (z-c.z1)*c.scale }

func rgb(r, g, b uint8) color.RGBA { return color.RGBA{r, g, b, 255} }

func fromUnit(f []float64) color.RGBA {
	if len(f) < 3 {
		return ownColor
	}
	to := func(v float64) uint8 { return uint8(min(max(v, 0), 1) * 255) }
	return rgb(to(f[0]), to(f[1]), to(f[2]))
}

func lerp(a, b color.RGBA, t float64) color.RGBA {
	t = min(max(t, 0), 1)
	mix := func(x, y uint8) uint8 { return uint8(float64(x) + (float64(y)-float64(x))*t) }
	return rgb(mix(a.R, b.R), mix(a.G, b.G), mix(a.B, b.B))
}

func shade(c color.RGBA, f float64) color.RGBA {
	m := func(v uint8) uint8 { return uint8(min(max(float64(v)*f, 0), 255)) }
	return rgb(m(c.R), m(c.G), m(c.B))
}

// inMap reports whether a pixel is inside the map area (overlays don't spill into margins).
func (c *canvas) inMap(x, y int) bool {
	return x >= c.left && y >= c.top && x < c.left+c.mw && y < c.top+c.mh
}

func (c *canvas) blend(x, y int, col color.RGBA, a float64) {
	if !(image.Point{x, y}.In(c.img.Rect)) {
		return
	}
	if a >= 1 {
		c.img.SetRGBA(x, y, col)
		return
	}
	o := c.img.RGBAAt(x, y)
	m := func(dst, src uint8) uint8 { return uint8(float64(dst)*(1-a) + float64(src)*a) }
	c.img.SetRGBA(x, y, rgb(m(o.R, col.R), m(o.G, col.G), m(o.B, col.B)))
}

func (c *canvas) fillRect(x0, y0, x1, y1 int, col color.RGBA, a float64) {
	for y := y0; y < y1; y++ {
		for x := x0; x < x1; x++ {
			c.blend(x, y, col, a)
		}
	}
}

// dot plots a square brush of width w centred on (x, y), clipped to the map area.
func (c *canvas) dot(x, y float64, w int, col color.RGBA, a float64) {
	x0, y0 := int(math.Round(x-float64(w)/2)), int(math.Round(y-float64(w)/2))
	for j := y0; j < y0+w; j++ {
		for i := x0; i < x0+w; i++ {
			if c.inMap(i, j) {
				c.blend(i, j, col, a)
			}
		}
	}
}

func (c *canvas) line(x0, y0, x1, y1 float64, w int, col color.RGBA, a float64) {
	steps := int(max(math.Abs(x1-x0), math.Abs(y1-y0))) + 1
	for i := range steps + 1 {
		f := float64(i) / float64(steps)
		c.dot(x0+(x1-x0)*f, y0+(y1-y0)*f, w, col, a)
	}
}

func (c *canvas) ring(x, y, r float64, w int, col color.RGBA, a float64) {
	steps := max(int(2*math.Pi*r), 12)
	for i := range steps {
		ang := 2 * math.Pi * float64(i) / float64(steps)
		c.dot(x+r*math.Cos(ang), y+r*math.Sin(ang), w, col, a)
	}
}

func (c *canvas) disc(x, y, r float64, col color.RGBA, a float64) {
	for j := int(y - r - 1); j <= int(y+r+1); j++ {
		for i := int(x - r - 1); i <= int(x+r+1); i++ {
			dx, dy := float64(i)+0.5-x, float64(j)+0.5-y
			if dx*dx+dy*dy <= r*r && c.inMap(i, j) {
				c.blend(i, j, col, a)
			}
		}
	}
}

func (c *canvas) box(x0, y0, x1, y1 float64, col color.RGBA, a float64) {
	for j := int(math.Floor(y0)); j < int(math.Ceil(y1)); j++ {
		for i := int(math.Floor(x0)); i < int(math.Ceil(x1)); i++ {
			if c.inMap(i, j) {
				c.blend(i, j, col, a)
			}
		}
	}
}

func (c *canvas) outline(x0, y0, x1, y1 float64, w int, col color.RGBA, a float64) {
	c.line(x0, y0, x1, y0, w, col, a)
	c.line(x1, y0, x1, y1, w, col, a)
	c.line(x1, y1, x0, y1, w, col, a)
	c.line(x0, y1, x0, y0, w, col, a)
}

var face = basicfont.Face7x13

func textWidth(s string) int { return font.MeasureString(face, s).Round() }

// text draws s with its top-left corner at (x, y); bg puts a dark box behind it.
func (c *canvas) text(x, y int, s string, col color.RGBA, bg bool) {
	if bg {
		c.fillRect(x-2, y-1, x+textWidth(s)+2, y+13, black, 0.65)
	}
	d := font.Drawer{Dst: c.img, Src: image.NewUniform(col), Face: face, Dot: fixed.P(x, y+10)}
	d.DrawString(s)
}

// ---- layers ----

func (c *canvas) terrain(t *Terrain) {
	landMin, landMax := math.Inf(1), math.Inf(-1)
	for _, h := range t.Heights {
		if h >= 0 {
			landMin, landMax = min(landMin, h), max(landMax, h)
		}
	}
	if landMax <= landMin {
		landMin, landMax = 0, max(landMin, 1)
	}
	// colour per cell, then bilinear between cells per pixel
	cells := make([][3]float64, t.W*t.H)
	lx, ly, lz := -0.55, 0.65, -0.55 // light from the north-west, above
	ln := math.Sqrt(lx*lx + ly*ly + lz*lz)
	lx, ly, lz = lx/ln, ly/ln, lz/ln
	for j := range t.H {
		for i := range t.W {
			h := t.at(i, j)
			dx := (t.at(i+1, j) - t.at(i-1, j)) / (2 * t.Step)
			dz := (t.at(i, j+1) - t.at(i, j-1)) / (2 * t.Step)
			slope := math.Hypot(dx, dz)
			// hillshade with some vertical exaggeration, 1 on flat ground
			nx, ny, nz := -dx*2, 1.0, -dz*2
			nn := math.Sqrt(nx*nx + ny*ny + nz*nz)
			lit := min(max((nx*lx+ny*ly+nz*lz)/nn/ly, 0.45), 1.35)
			var col color.RGBA
			if h < 0 {
				col = shade(lerp(shallow, deep, -h/160), 0.85+0.15*lit)
			} else {
				f := (h - landMin) / (landMax - landMin)
				if f < 0.5 {
					col = lerp(landLow, landMid, f*2)
				} else {
					col = lerp(landMid, landHigh, (f-0.5)*2)
				}
				switch {
				case slope > cliffSlope:
					col = lerp(col, cliffTint, 0.8)
				case slope > steepSlope:
					col = lerp(col, steepTint, 0.45)
				}
				col = shade(col, lit)
			}
			cells[j*t.W+i] = [3]float64{float64(col.R), float64(col.G), float64(col.B)}
		}
	}
	cell := func(i, j int) [3]float64 { return cells[min(max(j, 0), t.H-1)*t.W+min(max(i, 0), t.W-1)] }
	for y := range c.mh {
		wz := c.z1 + (float64(y)+0.5)/c.scale
		gz := (wz-t.Z1)/t.Step - 0.5
		j0 := int(math.Floor(gz))
		fz := gz - float64(j0)
		for x := range c.mw {
			wx := c.x1 + (float64(x)+0.5)/c.scale
			gx := (wx-t.X1)/t.Step - 0.5
			i0 := int(math.Floor(gx))
			fx := gx - float64(i0)
			a, b, d, e := cell(i0, j0), cell(i0+1, j0), cell(i0, j0+1), cell(i0+1, j0+1)
			var px [3]uint8
			for k := range 3 {
				top := a[k] + (b[k]-a[k])*fx
				bot := d[k] + (e[k]-d[k])*fx
				px[k] = uint8(min(max(top+(bot-top)*fz, 0), 255))
			}
			c.img.SetRGBA(c.left+x, c.top+y, rgb(px[0], px[1], px[2]))
		}
	}
}

// grid draws coordinate lines and labels and returns the spacing in elmos.
func (c *canvas) grid(spanX, spanZ float64) int {
	step := 4096
	for _, g := range []int{256, 512, 1024, 2048} {
		if max(spanX, spanZ)/float64(g) <= 10 {
			step = g
			break
		}
	}
	first := func(from float64) int { return int(math.Ceil(from/float64(step))) * step }
	for x := first(c.x1); float64(x) <= c.x1+spanX; x += step {
		px := c.px(float64(x))
		c.line(px, float64(c.top), px, float64(c.top+c.mh-1), 1, white, 0.28)
		label := strconv.Itoa(x)
		c.text(min(int(px)-textWidth(label)/2, c.img.Rect.Dx()-textWidth(label)-2), 3, label, white, false)
	}
	for z := first(c.z1); float64(z) <= c.z1+spanZ; z += step {
		py := c.py(float64(z))
		c.line(float64(c.left), py, float64(c.left+c.mw-1), py, 1, white, 0.28)
		label := strconv.Itoa(z)
		c.text(c.left-4-textWidth(label), min(int(py)-6, c.top+c.mh-12), label, white, false)
	}
	return step
}

func (c *canvas) zones(zones []SubZone, focus int) {
	labelled := map[int]bool{}
	for _, z := range zones {
		sub := c.subs[z.Sub]
		col := fromUnit(sub.Color)
		w := 2
		if z.Sub == focus {
			w = 3
		}
		var lx, ly float64
		switch z.Zone.Kind {
		case "circle":
			x, y, r := c.px(z.Zone.X), c.py(z.Zone.Z), z.Zone.R*c.scale
			c.ring(x, y, r, w, col, 0.95)
			lx, ly = x, y-r+4
		case "rect":
			x0, y0, x1, y1 := c.px(z.Zone.X1), c.py(z.Zone.Z1), c.px(z.Zone.X2), c.py(z.Zone.Z2)
			c.outline(x0, y0, x1, y1, w, col, 0.95)
			lx, ly = (x0+x1)/2, y0+4
		default:
			continue
		}
		if labelled[z.Sub] {
			continue
		}
		labelled[z.Sub] = true
		label := fmt.Sprintf("#%d %s", z.Sub, sub.Name)
		if z.Sub == focus {
			label += " (you)"
		}
		x := min(max(int(lx)-textWidth(label)/2, c.left+2), c.left+c.mw-textWidth(label)-2)
		y := min(max(int(ly), c.top+2), c.top+c.mh-16)
		c.text(x, y, label, col, true)
	}
}

func (c *canvas) spotRadius() float64 { return max(3.5, 48*c.scale) }

func (c *canvas) metal(spots []Spot) {
	r := c.spotRadius()
	for _, m := range spots {
		x, y := c.px(m.X), c.py(m.Z)
		switch m.Taken {
		case "free":
			c.ring(x, y, r, 2, metalColor, 1)
		case "enemy":
			c.disc(x, y, r, enemyRed, 1)
			c.ring(x, y, r, 1, metalColor, 1)
		default:
			c.disc(x, y, r, metalColor, 0.9)
		}
	}
}

func (c *canvas) units(units []Unit) {
	mobileR := 2.0
	if c.scale > 0.2 {
		mobileR = 3
	}
	// structures under mobile units
	for _, pass := range []bool{true, false} {
		for _, u := range units {
			if u.Structure != pass {
				continue
			}
			col := c.colorFor(u)
			x, y := c.px(u.X), c.py(u.Z)
			if u.Structure {
				hx, hz := max(u.HX*c.scale, 1.5), max(u.HZ*c.scale, 1.5)
				c.box(x-hx, y-hz, x+hx, y+hz, col, 1)
				w := 1
				if u.Factory {
					w = 2
				}
				c.outline(x-hx, y-hz, x+hx, y+hz, w, black, 0.9)
				if u.Factory {
					dx, dy := [4]float64{0, 1, 0, -1}[u.Facing&3], [4]float64{1, 0, -1, 0}[u.Facing&3]
					reach := max(hx, hz) + 7
					c.line(x, y, x+dx*reach, y+dy*reach, 2, white, 1)
				}
				if u.Marked {
					s := max(hx, hz) + 3
					c.line(x-s, y-s, x+s, y+s, 2, enemyRed, 1)
					c.line(x-s, y+s, x+s, y-s, 2, enemyRed, 1)
				}
			} else {
				c.disc(x, y, mobileR+1, black, 0.8)
				c.disc(x, y, mobileR, col, 1)
			}
		}
	}
}

// colorFor: allies light blue, ours in the owning sub-commander's colour or white.
func (c *canvas) colorFor(u Unit) color.RGBA {
	if u.Side == "ally" {
		return allyColor
	}
	if sub, ok := c.subs[u.Sub]; ok {
		return fromUnit(sub.Color)
	}
	return ownColor
}

func (c *canvas) enemies(s *Scene) {
	b := s.Bounds
	inView := func(x, z float64) bool { return x >= b.X1 && x <= b.X2 && z >= b.Z1 && z <= b.Z2 }
	for _, st := range s.Intel.RecentSightings {
		if inView(st.X, st.Z) {
			x, y := c.px(st.X), c.py(st.Z)
			c.ring(x, y, 9, 2, sightColor, 0.9)
			if c.inMap(int(x)+11, int(y)-6) {
				c.text(int(x)+11, int(y)-6, fmt.Sprintf("%ds ago", st.NewestSecondsAgo), sightColor, true)
			}
		}
	}
	for _, p := range s.Intel.StartPositions {
		if inView(p.X, p.Z) {
			x, y := c.px(p.X), c.py(p.Z)
			r := 10.0
			c.line(x, y-r, x+r, y, 2, enemyRed, 1)
			c.line(x+r, y, x, y+r, 2, enemyRed, 1)
			c.line(x, y+r, x-r, y, 2, enemyRed, 1)
			c.line(x-r, y, x, y-r, 2, enemyRed, 1)
			label := "enemy start"
			c.text(min(int(x)+13, c.left+c.mw-textWidth(label)-2), int(y)-6, label, enemyRed, true)
		}
	}
	for _, e := range s.Enemies {
		x, y := c.px(e.X), c.py(e.Z)
		switch {
		case !e.Known || e.Air:
			c.ring(x, y, 4, 2, enemyRed, 1)
		case e.Structure:
			c.box(x-3.5, y-3.5, x+3.5, y+3.5, enemyRed, 1)
			c.outline(x-3.5, y-3.5, x+3.5, y+3.5, 1, black, 0.9)
		default:
			c.disc(x, y, 4, black, 0.8)
			c.disc(x, y, 3, enemyRed, 1)
		}
	}
}

func (c *canvas) legend(opts Options, grid int) {
	y := c.top + c.mh + 8
	title := opts.Title
	if title != "" {
		title += "  |  "
	}
	title += fmt.Sprintf("grid every %d elmos, x grows east (right), z grows south (down)", grid)
	c.text(c.left, y, title, white, false)

	y += 18
	x := c.left
	swatch := func(draw func(cx, cy float64), label string) {
		draw(float64(x+6), float64(y+6))
		c.text(x+15, y, label, white, false)
		x += 15 + textWidth(label) + 14
		if x > c.left+c.mw-120 {
			x = c.left
			y += 17
		}
	}
	solid := func(col color.RGBA) func(cx, cy float64) {
		return func(cx, cy float64) {
			c.fillRect(int(cx)-5, int(cy)-5, int(cx)+5, int(cy)+5, col, 1)
		}
	}
	swatch(solid(lerp(landLow, steepTint, 0.45)), "steep")
	swatch(solid(cliffTint), "cliff")
	swatch(solid(shallow), "water")
	swatch(solid(ownColor), "ours, no sub-commander")
	swatch(solid(allyColor), "allies")
	swatch(solid(enemyRed), "enemy now")
	swatch(func(cx, cy float64) { c.legendRing(cx, cy, sightColor) }, "earlier sighting")
	swatch(func(cx, cy float64) { c.legendRing(cx, cy, metalColor) }, "free metal (filled = taken)")
}

// legendRing draws outside the map area, so it can't use the clipped ring
func (c *canvas) legendRing(cx, cy float64, col color.RGBA) {
	for i := range 40 {
		a := 2 * math.Pi * float64(i) / 40
		for _, r := range []float64{4.5, 5.5} {
			c.blend(int(math.Round(cx+r*math.Cos(a))), int(math.Round(cy+r*math.Sin(a))), col, 1)
		}
	}
}
