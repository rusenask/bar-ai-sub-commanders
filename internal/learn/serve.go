package learn

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Matchup is the store key prefix for a game: our faction against the enemies' ("cortex-vs-armada").
func Matchup(us string, enemies []string) string {
	them := make([]string, 0, len(enemies))
	seen := map[string]bool{}
	for _, e := range enemies {
		e = strings.ToLower(e)
		if e != "" && !seen[e] {
			seen[e] = true
			them = append(them, e)
		}
	}
	if len(them) == 0 {
		them = []string{"unknown"}
	}
	return strings.ToLower(us) + "-vs-" + strings.Join(them, "+")
}

// Find picks the store for a matchup in dir: the one starting with the matchup that has the most games
// ("cortex-vs-armada-medium" for "cortex-vs-armada"); nil when none was learned.
func Find(dir, matchup string, params []Param) (*Store, error) {
	files, err := filepath.Glob(filepath.Join(dir, matchup+"*.json"))
	if err != nil || len(files) == 0 {
		return nil, err
	}
	var best *Store
	for _, f := range files {
		key := strings.TrimSuffix(filepath.Base(f), ".json")
		s, err := Load(dir, key, params)
		if err != nil {
			continue
		}
		if best == nil || len(s.Trials) > len(best.Trials) {
			best = s
		}
	}
	return best, nil
}

// RecordReal adds a real game played with the store's mean: measured, not searched (real games are the
// player's, never exploration). summary: won (bool), minutes, dealt, taken.
func (s *Store) RecordReal(dir string, summary map[string]any, source string) error {
	won, _ := summary["won"].(bool)
	minutes, _ := summary["minutes"].(float64)
	dealt, _ := summary["dealt"].(float64)
	taken, _ := summary["taken"].(float64)
	result := "LOSS"
	if won {
		result = "WIN"
	}
	dt := 0.0
	if taken > 0 {
		dt = dealt / taken
	}
	s.Trials = append(s.Trials, Trial{Generation: s.Generation, Rules: s.MeanOverlay().Rules, Score: Score(result, minutes, dt, 60),
		Result: result, Minutes: minutes, Mean: true, Source: source, At: time.Now()})
	if err := s.Save(dir); err != nil {
		return fmt.Errorf("save %s: %w", s.Key, err)
	}
	return nil
}

// Exists reports whether a learning directory is there (the bridge runs without one too).
func Exists(dir string) bool {
	st, err := os.Stat(dir)
	return err == nil && st.IsDir()
}
