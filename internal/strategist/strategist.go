// Package strategist decides when each AI-enabled sub-commander should be
// reviewed and runs that review as a turn in its own opencode session.
package strategist

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/rusenask/bar-ai-sub-commanders/internal/game"
	"github.com/rusenask/bar-ai-sub-commanders/internal/opencode"
)

const framesPerSecond = 30

// Config controls the strategist.
type Config struct {
	Agent   string
	Model   opencode.Model
	Variant string
	// Interval is the game time between routine reviews of one sub-commander.
	Interval time.Duration
	// Urgent is the minimum game time between reviews when something happened
	// (new orders, enemies in the zone, losses).
	Urgent time.Duration
	// TurnTimeout bounds one review (model + tool calls).
	TurnTimeout time.Duration
}

type subState struct {
	sessionID     string
	reports       int
	lastFrame     int
	lastLogFrame  int
	lastDirective string
	lastThreats   int
	busy          bool
}

// Strategist runs reviews for AI-enabled sub-commanders.
type Strategist struct {
	cfg  Config
	game *game.Server
	oc   *opencode.Client
	log  *slog.Logger

	mu        sync.Mutex
	gameKey   string // identifies the connected game; sessions belong to one game
	lastFrame int
	subs      map[int]*subState
	acting    map[int]int    // sub id -> turns in flight
	actingIn  map[int]string // sub id -> game the turn started in
}

// New creates a strategist.
func New(cfg Config, g *game.Server, oc *opencode.Client, log *slog.Logger) *Strategist {
	return &Strategist{cfg: cfg, game: g, oc: oc, log: log, subs: map[int]*subState{}, acting: map[int]int{}, actingIn: map[int]string{}}
}

// Guard only lets tools act for a sub-commander whose review is running.
func (s *Strategist) Guard(subID int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.acting[subID] == 0 {
		return fmt.Errorf("sub-commander %d is not under your command: use the sub_id from your report", subID)
	}
	if !s.sameGame(s.actingIn[subID]) {
		return errors.New("the game you were commanding has ended")
	}
	return nil
}

// Run checks the game once a second until ctx ends.
func (s *Strategist) Run(ctx context.Context) {
	var wg sync.WaitGroup
	defer wg.Wait()
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		info, state, ok := s.game.Snapshot()
		if !ok || info == nil || state == nil || state.Paused {
			continue
		}
		s.trackGame(info, state)
		for _, sub := range state.Subs {
			if !sub.AI {
				continue
			}
			if reason := s.due(sub, state.Frame); reason != "" {
				wg.Go(func() { s.review(ctx, info, state, sub, reason) })
			}
		}
	}
}

func gameKey(info *game.Info) string {
	return fmt.Sprintf("%s|%s|%d|%s", info.Map, info.Player, info.Team, info.Faction)
}

// trackGame forgets sessions when a different game connects (or the same
// setup restarts: frames went backwards).
func (s *Strategist) trackGame(info *game.Info, state *game.State) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := gameKey(info)
	if key != s.gameKey || state.Frame+300 < s.lastFrame {
		if s.gameKey != "" {
			s.log.Info("new game, starting fresh strategist sessions", "map", info.Map, "faction", info.Faction)
		}
		s.gameKey = key
		clear(s.subs)
	}
	s.lastFrame = state.Frame
}

// sameGame reports whether the game the turn started in is still connected.
func (s *Strategist) sameGame(key string) bool {
	info, _, ok := s.game.Snapshot()
	return ok && info != nil && gameKey(info) == key
}

func seconds(d time.Duration) int {
	return int(d.Seconds() * framesPerSecond)
}

// due reports why the sub-commander should be reviewed now ("" = not yet)
// and marks it busy when it returns a reason.
func (s *Strategist) due(sub game.Sub, frame int) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	ss := s.subs[sub.ID]
	if ss == nil {
		ss = &subState{}
		s.subs[sub.ID] = ss
	}
	if ss.busy {
		return ""
	}
	var why []string
	if ss.reports == 0 {
		why = append(why, "you were just put in charge")
	}
	if sub.Directive != ss.lastDirective {
		why = append(why, "the player gave new orders")
	}
	if sub.Threats > 0 && ss.lastThreats == 0 {
		why = append(why, "enemies entered your zone")
	}
	losses := 0
	for _, e := range sub.Recent {
		if e.Frame > ss.lastLogFrame && strings.HasPrefix(e.Text, "lost ") {
			losses += max(e.Count, 1)
		}
	}
	if losses > 0 {
		why = append(why, fmt.Sprintf("you lost %d unit(s)", losses))
	}
	elapsed := frame - ss.lastFrame
	switch {
	case len(why) > 0 && (ss.reports == 0 || elapsed >= seconds(s.cfg.Urgent)):
	case elapsed >= seconds(s.cfg.Interval):
		why = append(why, "routine check")
	default:
		return ""
	}
	ss.busy = true
	ss.lastFrame = frame
	return strings.Join(why, ", ")
}

func (s *Strategist) review(ctx context.Context, info *game.Info, state *game.State, sub game.Sub, reason string) {
	s.mu.Lock()
	ss := s.subs[sub.ID]
	s.acting[sub.ID]++
	s.actingIn[sub.ID] = gameKey(info)
	first := ss.sessionID == ""
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		ss.busy = false
		if s.acting[sub.ID]--; s.acting[sub.ID] <= 0 {
			delete(s.acting, sub.ID)
			delete(s.actingIn, sub.ID)
		}
		s.mu.Unlock()
	}()

	s.game.Tell(sub.ID, "status", map[string]any{"text": "thinking (" + reason + ")…"})
	if first {
		id, err := s.oc.CreateSession(ctx, fmt.Sprintf("BAR %s · %s (#%d)", info.Map, sub.Name, sub.ID))
		if err != nil {
			s.fail(sub, err)
			return
		}
		s.mu.Lock()
		ss.sessionID = id
		s.mu.Unlock()
		s.log.Info("strategist session", "sub", sub.Name, "session", id)
	}

	prompt := report(info, state, sub, ss, reason, first)
	ctx, cancel := context.WithTimeoutCause(ctx, s.cfg.TurnTimeout, errors.New("strategist turn took too long"))
	defer cancel()
	start := time.Now()
	reply, err := s.oc.Send(ctx, ss.sessionID, opencode.Prompt{Agent: s.cfg.Agent, Model: s.cfg.Model, Variant: s.cfg.Variant, Text: prompt})
	if err != nil {
		if cause := context.Cause(ctx); cause != nil && ctx.Err() != nil {
			err = cause
			_ = s.oc.Abort(context.WithoutCancel(ctx), ss.sessionID)
		}
		s.fail(sub, err)
		return
	}

	s.mu.Lock()
	ss.reports++
	ss.lastDirective = sub.Directive
	ss.lastThreats = sub.Threats
	for _, e := range sub.Recent {
		ss.lastLogFrame = max(ss.lastLogFrame, e.Frame)
	}
	s.mu.Unlock()

	var used []string
	for _, t := range reply.Tools {
		used = append(used, strings.TrimPrefix(t.Tool, "bar_")+"="+t.Status)
	}
	s.log.Info("review", "sub", sub.Name, "why", reason, "took", time.Since(start).Round(100*time.Millisecond),
		"tools", strings.Join(used, ","), "in", int(reply.Tokens.Input), "cached", int(reply.Tokens.Cache.Read), "out", int(reply.Tokens.Output))

	if !s.sameGame(gameKey(info)) {
		s.log.Info("game changed during review, dropping its result", "sub", sub.Name)
		return
	}
	note := summaryLine(reply.Text)
	if note == "" {
		note = "no changes"
	}
	s.game.Tell(sub.ID, "note", map[string]any{"text": note})
}

func (s *Strategist) fail(sub game.Sub, err error) {
	s.log.Warn("review failed", "sub", sub.Name, "err", err)
	msg := err.Error()
	if len(msg) > 120 {
		msg = msg[:120] + "…"
	}
	s.game.Tell(sub.ID, "status", map[string]any{"text": "strategist error: " + msg})
}

// summaryLine keeps the model's last non-empty line, short enough for the panel.
func summaryLine(text string) string {
	line := ""
	for _, raw := range slices.Backward(strings.Split(strings.TrimSpace(text), "\n")) {
		if l := strings.TrimSpace(strings.Trim(raw, "*_` ")); l != "" {
			line = l
			break
		}
	}
	if r := []rune(line); len(r) > 160 {
		line = string(r[:159]) + "…"
	}
	return line
}

func clock(frame int) string {
	sec := frame / framesPerSecond
	return fmt.Sprintf("%d:%02d", sec/60, sec%60)
}

type brief struct {
	ID        int             `json:"id"`
	Name      string          `json:"name"`
	Role      string          `json:"role"`
	Posture   string          `json:"posture"`
	AI        bool            `json:"ai"`
	Zones     json.RawMessage `json:"zones,omitempty"`
	Threats   int             `json:"threats"`
	UnitCount int             `json:"unitCount"`
	Status    string          `json:"status,omitempty"`
}

// report builds the user message for one review. The fixed briefing comes
// first and only once per session, so every later turn extends a stable prefix.
func report(info *game.Info, state *game.State, sub game.Sub, ss *subState, reason string, first bool) string {
	var b strings.Builder
	if first {
		fmt.Fprintf(&b, "You command sub-commander #%d %q for player %s (faction %s) on map %q, %.0f x %.0f elmos (x grows east, z grows south).\n",
			sub.ID, sub.Name, info.Player, info.Faction, info.Map, info.MapX, info.MapZ)
		fmt.Fprintf(&b, "Always pass sub_id=%d to tools. You will get a report like this whenever something happens or every so often.\n\n", sub.ID)
	}
	fmt.Fprintf(&b, "## Report at %s (why now: %s)\n", clock(state.Frame), reason)
	if sub.Directive != "" {
		fmt.Fprintf(&b, "Player's standing orders: %q\n", sub.Directive)
	} else {
		b.WriteString("Player's standing orders: none (use your judgement within your role).\n")
	}

	self := sub
	self.Recent = nil
	self.AIStatus = ""
	writeJSON(&b, "You", self)
	writeJSON(&b, "Team economy", state.Economy)

	var others []brief
	for _, o := range state.Subs {
		if o.ID != sub.ID {
			others = append(others, brief{ID: o.ID, Name: o.Name, Role: o.Role, Posture: o.Posture, AI: o.AI, Zones: o.Zones, Threats: o.Threats, UnitCount: o.UnitCount, Status: o.Status})
		}
	}
	if len(others) > 0 {
		writeJSON(&b, "Other sub-commanders", others)
	}
	if len(state.Enemy) > 0 {
		fmt.Fprintf(&b, "Enemy intel: %s\n", state.Enemy)
	}

	var events []string
	for _, e := range slices.Backward(sub.Recent) {
		if e.Frame > ss.lastLogFrame && !e.AI {
			line := clock(e.Frame) + " " + e.Text
			if e.Count > 1 {
				line += fmt.Sprintf(" (x%d)", e.Count)
			}
			events = append(events, line)
		}
	}
	if len(events) > 0 {
		fmt.Fprintf(&b, "Your log since the last report:\n- %s\n", strings.Join(events, "\n- "))
	}
	b.WriteString("\nChange something with tools only if it clearly helps (often nothing should change). Then reply with one short sentence for the player: what you decided and why.\n")
	return b.String()
}

func writeJSON(b *strings.Builder, label string, v any) {
	data, err := json.Marshal(v)
	if err != nil {
		data = []byte(`"unavailable"`)
	}
	fmt.Fprintf(b, "%s: %s\n", label, data)
}
