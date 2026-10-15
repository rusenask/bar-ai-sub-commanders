// Package strategist decides when each AI-enabled sub-commander should be
// reviewed and runs that review as a turn in its own opencode session.
package strategist

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/rusenask/bar-ai-sub-commanders/internal/analysis"
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
	// CalmFactor stretches Interval for sub-commanders with nothing going on (default 2).
	CalmFactor float64
	// MaxInFlight caps reviews running at once (0 = no cap).
	MaxInFlight int
	// Record, when set, is a file each review is appended to as a JSON line (report, reply, tools, time):
	// the data for grading prompt or model changes offline.
	Record string
	// LessonsDir, when set, keeps the strategist's lessons per matchup (debrief.go): written at game over,
	// read into each sub-commander's first report.
	LessonsDir string
}

type subState struct {
	sessionID     string
	reports       int
	lastFrame     int
	lastLogFrame  int
	lastDirective string
	lastThreats   int
	busy          bool
	failures      int // reviews failed in a row
	retryFrame    int // no review before this frame (backoff after failures)
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
	pace      pacer          // review pacing: provider speed, game speed, reviews in flight
	notes     []string       // this game's decisions, for the debrief (debrief.go)
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
	// idle for long with AI sub-commanders to serve: say why, once a minute (a bridge sat idle for two
	// hours with AI on and logged nothing; a restart fixed it and the cause was lost)
	lastActive, lastIdleLog := time.Now(), time.Time{}
	idle := func(why string) {
		if why == "" {
			lastActive = time.Now()
			return
		}
		if time.Since(lastActive) > 2*time.Minute && time.Since(lastIdleLog) > time.Minute {
			lastIdleLog = time.Now()
			s.log.Info("strategist idle", "why", why, "for", time.Since(lastActive).Round(time.Second))
		}
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		info, state, ok := s.game.Snapshot()
		if !ok || info == nil || state == nil || state.Paused {
			why := s.game.Why()
			if why == "" {
				why = "no game info or state"
			}
			idle(why)
			continue
		}
		s.trackGame(info, state)
		s.pace.observe(state.Frame, time.Now())
		ai, started := 0, 0
		for _, sub := range state.Subs {
			if !sub.AI {
				continue
			}
			ai++
			if reason := s.due(sub, state.Frame); reason != "" {
				started++
				wg.Go(func() { s.review(ctx, info, state, sub, reason) })
			}
		}
		switch {
		case ai == 0:
			idle("no sub-commander has AI on")
		case started > 0:
			idle("")
		default:
			idle(s.waitingWhy(state.Frame))
		}
	}
}

// waitingWhy: what every AI sub-commander is waiting on (a review in flight, a retry after failures,
// the next routine check), for the idle log.
func (s *Strategist) waitingWhy(frame int) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	busy, retry := 0, 0
	for _, ss := range s.subs {
		if ss.busy {
			busy++
		}
		if frame < ss.retryFrame {
			retry++
		}
	}
	s.pace.mu.Lock()
	inFlight := s.pace.inFlight
	s.pace.mu.Unlock()
	return fmt.Sprintf("no review due: %d busy, %d waiting to retry after failures, %d reviews in flight (max %d)",
		busy, retry, inFlight, s.cfg.MaxInFlight)
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
		s.notes = nil
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
	if ss.busy || frame < ss.retryFrame {
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
	// busy sub-commanders are reviewed as often as the provider answers, calm ones less often (pace.go)
	busy := sub.Threats > 0 || losses > 0 || sub.Squad.Fighting()
	elapsed := frame - ss.lastFrame
	switch {
	case len(why) > 0 && (ss.reports == 0 || elapsed >= s.pace.interval(s.cfg, true)):
	case elapsed >= s.pace.interval(s.cfg, busy):
		if busy {
			why = append(why, "the situation is moving")
		} else {
			why = append(why, "routine check")
		}
	default:
		return ""
	}
	if !s.pace.start(s.cfg) {
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
		s.pace.done()
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
			s.fail(sub, ss, state.Frame, err)
			return
		}
		s.mu.Lock()
		ss.sessionID = id
		s.mu.Unlock()
		s.log.Info("strategist session", "sub", sub.Name, "session", id)
	}

	prompt := report(info, state, sub, ss, reason, first, s.lessonsFor(info, state.Frame))
	ctx, cancel := context.WithTimeoutCause(ctx, s.cfg.TurnTimeout, errors.New("strategist turn took too long"))
	defer cancel()
	start := time.Now()
	reply, err := s.oc.Send(ctx, ss.sessionID, opencode.Prompt{Agent: s.cfg.Agent, Model: s.cfg.Model, Variant: s.cfg.Variant, Text: prompt})
	if err != nil {
		if cause := context.Cause(ctx); cause != nil && ctx.Err() != nil {
			err = cause
			_ = s.oc.Abort(context.WithoutCancel(ctx), ss.sessionID)
		}
		s.fail(sub, ss, state.Frame, err)
		return
	}

	s.pace.took(time.Since(start))
	s.mu.Lock()
	ss.reports++
	ss.failures, ss.retryFrame = 0, 0
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
	s.record(info, state, sub, reason, prompt, reply, time.Since(start))
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
	s.note(state.Frame, sub, note)
	s.game.Tell(sub.ID, "note", map[string]any{"text": note})
}

// record appends one review to Config.Record (if set) as a JSON line.
func (s *Strategist) record(info *game.Info, state *game.State, sub game.Sub, reason, prompt string, reply *opencode.Reply, took time.Duration) {
	if s.cfg.Record == "" {
		return
	}
	var tools []string
	for _, t := range reply.Tools {
		tools = append(tools, strings.TrimPrefix(t.Tool, "bar_")+"="+t.Status)
	}
	line, err := json.Marshal(map[string]any{
		"at": time.Now().UTC().Format(time.RFC3339), "game": gameKey(info), "frame": state.Frame,
		"sub": sub.ID, "name": sub.Name, "role": sub.Role, "why": reason,
		"report": prompt, "reply": reply.Text, "tools": tools, "tookMs": took.Milliseconds(),
	})
	if err != nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	f, err := os.OpenFile(s.cfg.Record, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		s.log.Warn("recording review", "err", err)
		return
	}
	defer f.Close()
	_, _ = f.Write(append(line, '\n'))
}

// fail reports a failed review and backs off: 5 s of game time, doubling up to 2 minutes.
func (s *Strategist) fail(sub game.Sub, ss *subState, frame int, err error) {
	s.mu.Lock()
	ss.failures++
	ss.retryFrame = frame + seconds(min(5*time.Second<<min(ss.failures-1, 5), 2*time.Minute))
	s.mu.Unlock()
	s.log.Warn("review failed", "sub", sub.Name, "failures", ss.failures, "err", err)
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
func report(info *game.Info, state *game.State, sub game.Sub, ss *subState, reason string, first bool, lessons string) string {
	var b strings.Builder
	if first {
		fmt.Fprintf(&b, "You command sub-commander #%d %q for player %s (faction %s) on map %q, %.0f x %.0f elmos (x grows east, z grows south).\n",
			sub.ID, sub.Name, info.Player, info.Faction, info.Map, info.MapX, info.MapZ)
		fmt.Fprintf(&b, "Wind %.0f-%.0f (average about %.0f; wind turbines pay off above ~7), tidal %.0f.\n", info.WindMin, info.WindMax, (info.WindMin+info.WindMax)/2, info.Tidal)
		fmt.Fprintf(&b, "Always pass sub_id=%d to tools. You will get a report like this whenever something happens or every so often.\n", sub.ID)
		fmt.Fprintf(&b, "This is your first report: load the %q skill (and any other skill you need), then look at the map once with get_map_view before deciding.\n", sub.Role)
		b.WriteString("\n")
	}
	fmt.Fprintf(&b, "## Report at %s (why now: %s)\n", clock(state.Frame), reason)
	if lessons != "" {
		fmt.Fprintf(&b, "Lessons from earlier games of this matchup for this stage of the game (%s; +confirmed/-contradicted by later games; weigh them, they are not orders):\n%s", stageOf(state.Frame), lessons)
	}
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
	b.WriteString(paceLine(state.Frame, state.Economy))
	if len(state.Team) > 0 && string(state.Team) != "null" {
		fmt.Fprintf(&b, "Rules engine (tunable rules, audit warnings, built in the last 3 min): %s\n", state.Team)
	}

	var others []brief
	for _, o := range state.Subs {
		if o.ID != sub.ID {
			others = append(others, brief{ID: o.ID, Name: o.Name, Role: o.Role, Posture: o.Posture, AI: o.AI, Zones: o.Zones, Threats: o.Threats, UnitCount: o.UnitCount, Status: o.Status})
		}
	}
	if len(others) > 0 {
		writeJSON(&b, "Other sub-commanders", others)
	}
	if len(state.Allies) > 2 {
		fmt.Fprintf(&b, "Our allies' bases: %s\n", state.Allies)
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

// strong players' 1v1 economies by minute (cmd/gamereport -bench-from, built into the binary)
var proPace = analysis.ProDuel()

// paceLine compares the team's income with strong players' at the same minute of their 1v1s.
func paceLine(frame int, e game.Economy) string {
	minute := frame / framesPerSecond / 60
	for m := minute; m >= 2; m-- { // the latest minute the benchmark covers
		mi, ok := proPace.Band(m, "metalIncome")
		ei, ok2 := proPace.Band(m, "energyIncome")
		if ok && ok2 {
			return fmt.Sprintf("Pace: metal income %.1f/s, energy %.0f/s at %d min; strong players' 1v1s at %d min: metal %g-%g/s, energy %g-%g/s (a guide, maps and plans differ).\n",
				e.MetalIncome, e.EnergyIncome, minute, m, mi.P25, mi.P75, ei.P25, ei.P75)
		}
	}
	return ""
}

func writeJSON(b *strings.Builder, label string, v any) {
	data, err := json.Marshal(v)
	if err != nil {
		data = []byte(`"unavailable"`)
	}
	fmt.Fprintf(b, "%s: %s\n", label, data)
}
