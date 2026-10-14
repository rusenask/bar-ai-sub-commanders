package strategist

import (
	"context"
	"encoding/json"
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

// stageOf names the stage of the game at a frame (learn.Stages: opening < 10 min, mid 10-25, late 25+).
func stageOf(frame int) string {
	switch m := frame / (30 * 60); {
	case m < 10:
		return "opening"
	case m < 25:
		return "mid"
	default:
		return "late"
	}
}

// lessonsFor returns the strongest lessons for the stage the game is in ("" when none or off): every
// report carries them, under a small budget.
func (s *Strategist) lessonsFor(info *game.Info, frame int) string {
	if s.cfg.LessonsDir == "" || info == nil {
		return ""
	}
	book := learn.LoadBook(s.cfg.LessonsDir, learn.Matchup(info.Faction, info.Enemies))
	return learn.Listing(book.ForStage(stageOf(frame), 5))
}

// Debrief edits the matchup's lesson book with what the game that just ended showed. summary: won,
// minutes, dealt, taken (the widget's game over). Its own opencode session, no tools; the reply is a
// JSON list of edits (learn.Op). A reply that doesn't parse leaves the book as it was.
func (s *Strategist) Debrief(ctx context.Context, info *game.Info, summary map[string]any) {
	if s.cfg.LessonsDir == "" || info == nil {
		return
	}
	s.mu.Lock()
	notes := append([]string(nil), s.notes...)
	s.mu.Unlock()
	_, state, _ := s.game.Snapshot()
	matchup := learn.Matchup(info.Faction, info.Enemies)
	book := learn.LoadBook(s.cfg.LessonsDir, matchup)
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
		fmt.Fprintf(&b, "What the sub-commanders decided during the game (game time first):\n- %s\n", strings.Join(notes, "\n- "))
	}
	fmt.Fprintf(&b, "\nThe team's lesson book for this matchup (%d of at most %d; +confirmed/-contradicted by games):\n%s", len(book.Lessons), learn.MaxLessons, learn.Listing(book.Lessons))
	if len(book.Lessons) == 0 {
		b.WriteString("(empty)\n")
	}
	b.WriteString(`
Do not use any tools. Edit the lesson book with what THIS game showed. Reply with only a JSON array of edits:
  {"op":"confirm","id":N}  this game bore lesson N out          {"op":"contradict","id":N}  it went against N
  {"op":"update","id":N,"text":"...","stage":"..."}  sharpen N   {"op":"drop","id":N}  N is wrong or useless
  {"op":"merge","ids":[N,M],"text":"...","stage":"..."}  two say the same thing
  {"op":"create","text":"...","stage":"opening|mid|late|all"}  something new (one sentence, concrete: what to do, when, why)
Stages: opening < 10 min, mid 10-25, late 25+; "all" only when it holds throughout. Name rules and values when a rule change is the lesson. Prefer confirm/contradict/update/merge over create; the book holds at most ` + fmt.Sprint(learn.MaxLessons) + ` lessons. [] if the game taught nothing new.`)
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
	ops, err := parseOps(reply.Text)
	if err != nil {
		s.log.Warn("debrief reply isn't a list of edits; lesson book unchanged", "err", err, "reply", summaryLine(reply.Text))
		return
	}
	game := fmt.Sprintf("%s %s %s", time.Now().Format("2006-01-02T15:04"), info.Map, result)
	done := book.Apply(ops, game)
	if err := book.Save(s.cfg.LessonsDir); err != nil {
		s.log.Warn("debrief save", "err", err)
		return
	}
	s.log.Info("debrief: lesson book edited", "matchup", matchup, "edits", strings.Join(done, ", "), "lessons", len(book.Lessons))
}

// parseOps reads the JSON array of edits from a reply (code fences and text around it are tolerated).
func parseOps(text string) ([]learn.Op, error) {
	start, end := strings.Index(text, "["), strings.LastIndex(text, "]")
	if start < 0 || end < start {
		return nil, fmt.Errorf("no JSON array")
	}
	var ops []learn.Op
	if err := json.Unmarshal([]byte(text[start:end+1]), &ops); err != nil {
		return nil, err
	}
	return ops, nil
}
