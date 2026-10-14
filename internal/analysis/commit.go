package analysis

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
)

// Commit: when strong players push into a fight and when they pull back, from the data logger's "fight"
// samples (v7+: ownApproach / enemyApproach). By the local strength ratio (our armed mobile units' value
// over theirs, turrets included on both sides): how often the group moves in, holds or pulls back, and
// how each choice traded. The squads' engage thresholds (sc_doctrine.lua D.engage attack / hold) are
// judged against it.

type commitSide struct {
	Value float64 `json:"value"`
}

// CommitSample is one fight's start.
type CommitSample struct {
	Team          int        `json:"team"`
	Own           commitSide `json:"own"`
	OwnTurrets    commitSide `json:"ownTurrets"`
	Enemy         commitSide `json:"enemy"`
	EnemyTurrets  commitSide `json:"enemyTurrets"`
	OwnApproach   *float64   `json:"ownApproach"`
	EnemyApproach *float64   `json:"enemyApproach"`
	OwnLost       float64    `json:"ownLost"`
	EnemyLost     float64    `json:"enemyLost"`
}

// Ratio is our side's value over theirs, turrets included.
func (c CommitSample) Ratio() float64 {
	return (c.Own.Value + c.OwnTurrets.Value) / math.Max(c.Enemy.Value+c.EnemyTurrets.Value, 1)
}

// ReadCommit reads the fight samples that carry the approach (v7+) of every JSONL file in dir.
func ReadCommit(dir string) ([]CommitSample, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.jsonl"))
	if err != nil {
		return nil, err
	}
	var out []CommitSample
	for _, f := range files {
		fh, err := os.Open(f)
		if err != nil {
			return nil, err
		}
		s, err := parseCommit(fh)
		fh.Close()
		if err != nil {
			return nil, fmt.Errorf("%s: %w", f, err)
		}
		out = append(out, s...)
	}
	return out, nil
}

func parseCommit(r io.Reader) ([]CommitSample, error) {
	var out []CommitSample
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1<<20), 1<<22)
	for sc.Scan() {
		line := sc.Bytes()
		if !strings.Contains(string(line), `"type":"fight"`) || !strings.Contains(string(line), `"ownApproach"`) {
			continue
		}
		var c CommitSample
		if json.Unmarshal(line, &c) == nil && c.OwnApproach != nil && c.Own.Value > 0 {
			out = append(out, c)
		}
	}
	return out, sc.Err()
}

// CommitBin is the fights at one range of strength ratios.
type CommitBin struct {
	Lo, Hi   float64 // ratio range [Lo, Hi)
	Fights   int
	In       float64 // share moving in (approach > 0.2)
	Hold     float64 // share holding (|approach| <= 0.2)
	Out      float64 // share pulling back (approach < -0.2)
	TradeIn  float64 // their value lost over ours (pooled) when moving in
	TradeOut float64 // the same when pulling back
}

// commitMove: in (+1), hold (0) or out (-1) from an approach
func commitMove(a float64) int {
	switch {
	case a > 0.2:
		return 1
	case a < -0.2:
		return -1
	}
	return 0
}

// CommitByRatio bins fights by strength ratio (bounds: the bins' edges).
func CommitByRatio(samples []CommitSample, bounds []float64) []CommitBin {
	var out []CommitBin
	for i := 0; i+1 < len(bounds); i++ {
		b := CommitBin{Lo: bounds[i], Hi: bounds[i+1]}
		var in, hold, back int
		var lostIn, killIn, lostOut, killOut float64
		for _, c := range samples {
			r := c.Ratio()
			if r < b.Lo || r >= b.Hi {
				continue
			}
			b.Fights++
			switch commitMove(*c.OwnApproach) {
			case 1:
				in++
				lostIn += c.OwnLost
				killIn += c.EnemyLost
			case -1:
				back++
				lostOut += c.OwnLost
				killOut += c.EnemyLost
			default:
				hold++
			}
		}
		if b.Fights > 0 {
			n := float64(b.Fights)
			b.In, b.Hold, b.Out = float64(in)/n, float64(hold)/n, float64(back)/n
			b.TradeIn = killIn / math.Max(lostIn, 1)
			b.TradeOut = killOut / math.Max(lostOut, 1)
		}
		out = append(out, b)
	}
	return out
}

// CommitText renders the bins.
func CommitText(bins []CommitBin) string {
	var s strings.Builder
	s.WriteString("| Strength ratio (ours / theirs) | Fights | Move in | Hold | Pull back | Trade moving in | Trade pulling back |\n|---|---|---|---|---|---|---|\n")
	for _, b := range bins {
		hi := fmt.Sprintf("%.2g", b.Hi)
		if math.IsInf(b.Hi, 1) {
			hi = "up"
		}
		fmt.Fprintf(&s, "| %.2g-%s | %d | %.0f%% | %.0f%% | %.0f%% | %.2f | %.2f |\n", b.Lo, hi, b.Fights, 100*b.In, 100*b.Hold, 100*b.Out, b.TradeIn, b.TradeOut)
	}
	return s.String()
}

// CommitBounds are the default ratio bins.
var CommitBounds = []float64{0, 0.33, 0.5, 0.67, 0.8, 1, 1.25, 1.5, 2, 3, math.Inf(1)}
