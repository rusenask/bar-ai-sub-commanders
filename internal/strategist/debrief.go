package strategist

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/rusenask/bar-ai-sub-commanders/internal/game"
	"github.com/rusenask/bar-ai-sub-commanders/internal/learn"
	"github.com/rusenask/bar-ai-sub-commanders/internal/opencode"
)

// The strategist learns across games in words: at game over it reviews the game it just played (the
// result, the rules engine's last report, what each sub-commander decided) and writes short lessons for
// the next game of the same matchup (learn/lessons/<matchup>.md); those go into the first report of
// every sub-commander next time. The learned rules (internal/learn) are the numeric half.

const maxNotes = 200

// note remembers a decision of this game for the debrief.
func (s *Strategist) note(frame int, sub game.Sub, text string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.notes) < maxNotes {
		s.notes = append(s.notes, fmt.Sprintf("%s %s (%s): %s", clock(frame), sub.Name, sub.Role, text))
	}
}

// lessonsFor returns the notes from past games of this game's matchup ("" when none or off).
func (s *Strategist) lessonsFor(info *game.Info) string {
	if s.cfg.LessonsDir == "" || info == nil {
		return ""
	}
	return learn.Lessons(s.cfg.LessonsDir, learn.Matchup(info.Faction, info.Enemies))
}

// Debrief writes lessons from the game that just ended. summary: won, minutes, dealt, taken (the
// widget's game over). Runs in its own opencode session; no tools.
func (s *Strategist) Debrief(ctx context.Context, info *game.Info, summary map[string]any) {
	if s.cfg.LessonsDir == "" || info == nil {
		return
	}
	s.mu.Lock()
	notes := append([]string(nil), s.notes...)
	s.mu.Unlock()
	_, state, _ := s.game.Snapshot()
	matchup := learn.Matchup(info.Faction, info.Enemies)
	won, _ := summary["won"].(bool)
	minutes, _ := summary["minutes"].(float64)
	result := "lost"
	if won {
		result = "won"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Debrief. The game just ended: %s (%s vs %s on %s) %s after %.0f minutes.\n", info.Player, info.Faction,
		strings.Join(info.Enemies, ", "), info.Map, result, minutes)
	if d, t := summary["dealt"], summary["taken"]; d != nil && t != nil {
		fmt.Fprintf(&b, "Damage dealt %v, taken %v.\n", d, t)
	}
	if state != nil && len(state.Team) > 0 {
		fmt.Fprintf(&b, "The rules engine's last report: %s\n", state.Team)
	}
	if len(notes) > 0 {
		fmt.Fprintf(&b, "What the sub-commanders decided during the game:\n- %s\n", strings.Join(notes, "\n- "))
	}
	if old := s.lessonsFor(info); old != "" {
		fmt.Fprintf(&b, "\nLessons written after earlier games of this matchup (newest first):\n%s\n", old)
	}
	b.WriteString("\nDo not use any tools. Write 3 to 5 short lessons for the next game of this matchup: what worked, " +
		"what didn't, what to do differently (name rules and values when a rule change is the lesson). Plain bullet " +
		"points, no preamble. Don't repeat earlier lessons unless this game confirmed or contradicted them (say which).")
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	id, err := s.oc.CreateSession(ctx, fmt.Sprintf("BAR debrief %s %s", info.Map, matchup))
	if err != nil {
		s.log.Warn("debrief", "err", err)
		return
	}
	reply, err := s.oc.Send(ctx, id, opencode.Prompt{Agent: s.cfg.Agent, Model: s.cfg.Model, Variant: s.cfg.Variant, Text: b.String()})
	if err != nil {
		s.log.Warn("debrief", "err", err)
		return
	}
	header := fmt.Sprintf("%s, %s vs %s, %s at %.0f min", info.Map, info.Faction, strings.Join(info.Enemies, "+"), result, minutes)
	if err := learn.AddLesson(s.cfg.LessonsDir, matchup, header, reply.Text); err != nil {
		s.log.Warn("debrief save", "err", err)
		return
	}
	s.log.Info("debrief written", "matchup", matchup, "lessons", summaryLine(reply.Text))
}
