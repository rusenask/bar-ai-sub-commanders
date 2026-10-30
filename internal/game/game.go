// Package game is the bridge's side of the link to the "Sub-Commanders AI link"
// widget: a localhost TCP server speaking one JSON object per line.
package game

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"
)

// Info describes the running game, sent once by the widget on connect.
type Info struct {
	Protocol int      `json:"protocol"`
	Map      string   `json:"map"`
	MapX     float64  `json:"mapX"`
	MapZ     float64  `json:"mapZ"`
	Team     int      `json:"team"`
	Faction  string   `json:"faction"`
	Player   string   `json:"player"`
	Frame    int      `json:"frame"`
	WindMin  float64  `json:"windMin"`
	WindMax  float64  `json:"windMax"`
	Tidal    float64  `json:"tidal"`
	Enemies  []string `json:"enemies,omitempty"` // the enemy teams' factions
	AIs      []string `json:"ais,omitempty"`     // the enemy AIs' names
}

// LogEntry is one line of a sub-commander's activity log.
type LogEntry struct {
	Frame int    `json:"frame"`
	Text  string `json:"text"`
	Count int    `json:"count"`
	AI    bool   `json:"ai"`
}

// Sub is a sub-commander as reported by the widget. Nested data the bridge
// only forwards to the model stays raw (the Lua encoder turns empty tables
// into [] which would not decode into Go maps).
type Sub struct {
	ID          int             `json:"id"`
	Name        string          `json:"name"`
	Role        string          `json:"role"`
	Posture     string          `json:"posture"`
	Paused      bool            `json:"paused"`
	AI          bool            `json:"ai"`
	Directive   string          `json:"directive,omitempty"`
	AIStatus    string          `json:"aiStatus,omitempty"`
	Status      string          `json:"status,omitempty"`
	Zones       json.RawMessage `json:"zones,omitempty"`
	Counts      json.RawMessage `json:"counts,omitempty"`
	SpendMetal  float64         `json:"spendMetal"`
	SpendEnergy float64         `json:"spendEnergy"`
	Threats     int             `json:"threats"`
	AirThreats  int             `json:"airThreats"`
	Focus       json.RawMessage `json:"focus,omitempty"`
	Composition json.RawMessage `json:"composition,omitempty"`
	Activity    json.RawMessage `json:"activity,omitempty"`
	ManualUnits int             `json:"manualUnits"`
	// how much it does on its own (light / balanced / full) and whether its zones are automatic
	Autonomy  string `json:"autonomy,omitempty"`
	AutoZones bool   `json:"autoZones,omitempty"`
	// an army's current decision about its target (engage / regroup / hold / fallback)
	Squad *Squad `json:"squad,omitempty"`
	// armies: whether its fast units raid (on by default), and what the raid squad is doing
	Raids *bool           `json:"raids,omitempty"`
	FedBy string          `json:"fedBy,omitempty"` // an army without a factory: whose factory builds its units
	Raid  json.RawMessage `json:"raid,omitempty"`
	// what the player's own constructors queue and how many of their units are in this sub's zones
	PlayerActivity json.RawMessage `json:"playerActivity,omitempty"`
	UnitCount      int             `json:"unitCount"`
	Recent         []LogEntry      `json:"recent"`
}

// Squad is an army's decision about its target: our local power against theirs (ratio) decides it.
type Squad struct {
	Action string  `json:"action"`
	Ratio  float64 `json:"ratio"`
	Target struct {
		X float64 `json:"x"`
		Z float64 `json:"z"`
	} `json:"target"`
}

// Fighting reports whether the army is in or near a fight.
func (s *Squad) Fighting() bool {
	return s != nil && (s.Action == "engage" || s.Action == "fallback" || s.Action == "hold")
}

// Economy is the team's resource state.
type Economy struct {
	Metal         float64 `json:"metal"`
	MetalStorage  float64 `json:"metalStorage"`
	MetalIncome   float64 `json:"metalIncome"`
	MetalPull     float64 `json:"metalPull"` // what everything is trying to spend per second
	Energy        float64 `json:"energy"`
	EnergyStorage float64 `json:"energyStorage"`
	EnergyIncome  float64 `json:"energyIncome"`
	EnergyPull    float64 `json:"energyPull"`
}

// State is the periodic snapshot the widget sends (every 3 game seconds).
type State struct {
	Frame   int             `json:"frame"`
	Paused  bool            `json:"paused"`
	Economy Economy         `json:"economy"`
	Subs    []Sub           `json:"subs"`
	Enemy   json.RawMessage `json:"enemy,omitempty"`
	// our allies' bases: [{ team, x, z }] (the Air Force can cover them: cover_ally)
	Allies json.RawMessage `json:"allies,omitempty"`
	// the rules engine's team view: tunable rule values, audit warnings, what got built lately
	Team json.RawMessage `json:"team,omitempty"`
}

// Sub returns the sub-commander with the given id.
func (s *State) Sub(id int) (Sub, bool) {
	for _, sub := range s.Subs {
		if sub.ID == id {
			return sub, true
		}
	}
	return Sub{}, false
}

type message struct {
	Type  string          `json:"type"`
	ID    int64           `json:"id,omitzero"`
	Sub   int             `json:"sub,omitzero"`
	Op    string          `json:"op,omitempty"`
	Args  map[string]any  `json:"args,omitempty"`
	OK    bool            `json:"ok,omitzero"`
	Error string          `json:"error,omitempty"`
	Data  json.RawMessage `json:"data,omitempty"`
	Game  *Info           `json:"game,omitempty"`
	State *State          `json:"state,omitempty"`
}

type result struct {
	data json.RawMessage
	err  error
}

// ErrOffline is returned when no game is connected.
var ErrOffline = errors.New("game is not connected")

// DecideFunc answers a widget's "decide" request (its args: {task, features} or {state, questions}) with
// the answers object.
type DecideFunc func(ctx context.Context, args map[string]any) (json.RawMessage, error)

// Server accepts the widget connection (one at a time; a new one replaces the old).
type Server struct {
	addr string
	log  *slog.Logger

	// Decide, when set, serves the widget's requests to a decision model (set before Run).
	Decide DecideFunc
	// OnHello, when set, may answer a new game with a message's args of type "learned" (rules learned for
	// this matchup, internal/learn); OnGameOver gets the game's summary (won, minutes, dealt, taken).
	OnHello    func(info *Info) map[string]any
	OnGameOver func(info *Info, summary map[string]any)
	// ErrorLog, when set, is the JSONL file the widget's caught Lua errors are appended to (errorlog.go).
	ErrorLog string

	mu      sync.Mutex
	conn    Conn // the widget's link (transport.go)
	info    *Info
	state   *State
	over    bool
	pending map[int64]chan result

	writeMu sync.Mutex
	errMu   sync.Mutex // one error log append at a time
	nextID  atomic.Int64
}

// NewServer creates a server listening on addr once Run is called.
func NewServer(addr string, log *slog.Logger) *Server {
	return &Server{addr: addr, log: log, pending: map[int64]chan result{}}
}

// Run serves the TCP link on the server's address until ctx is cancelled (Serve takes any Listener).
func (s *Server) Run(ctx context.Context) error {
	l, err := ListenTCP(ctx, s.addr)
	if err != nil {
		return err
	}
	return s.Serve(ctx, l)
}

// attach makes conn the game's connection (replacing any other) and serves it.
func (s *Server) attach(conn Conn) {
	s.mu.Lock()
	if s.conn != nil {
		s.conn.Close()
	}
	s.conn = conn
	s.mu.Unlock()
	go s.serve(conn)
}

func (s *Server) serve(conn Conn) {
	s.log.Info("game connected", "from", conn.Describe())
	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for sc.Scan() {
		var msg message
		if err := json.Unmarshal(sc.Bytes(), &msg); err != nil {
			s.log.Warn("bad message from game", "err", err)
			continue
		}
		s.handle(msg)
	}
	s.mu.Lock()
	if s.conn == conn {
		s.conn = nil
		for id, ch := range s.pending {
			ch <- result{err: ErrOffline}
			delete(s.pending, id)
		}
	}
	s.mu.Unlock()
	s.log.Info("game disconnected", "err", sc.Err())
}

func (s *Server) handle(msg message) {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch msg.Type {
	case "hello":
		if msg.Game != nil {
			s.info = msg.Game
			s.over = false
			s.log.Info("game", "map", msg.Game.Map, "faction", msg.Game.Faction, "frame", msg.Game.Frame)
		}
		// tell the widget what the bridge offers, and what was learned for this matchup
		go s.write(message{Type: "config", Args: map[string]any{"decider": s.Decide != nil}})
		if s.OnHello != nil && msg.Game != nil {
			info := msg.Game
			go func() {
				if args := s.OnHello(info); args != nil {
					_ = s.write(message{Type: "learned", Args: args})
				}
			}()
		}
	case "decide":
		if s.Decide != nil {
			go s.decide(msg)
		}
	case "state":
		if msg.State != nil {
			s.state = msg.State
		}
	case "gameover":
		s.over = true
		if s.OnGameOver != nil && msg.Args != nil {
			info := s.info
			go s.OnGameOver(info, msg.Args)
		}
	case "widgeterror":
		e := widgetError(s.info, msg.Args, time.Now())
		s.log.Warn("widget error", "where", e.Where, "count", e.Count, "frame", e.Frame, "message", e.Message)
		if s.ErrorLog != "" {
			go func() {
				s.errMu.Lock()
				defer s.errMu.Unlock()
				if err := appendWidgetError(s.ErrorLog, e); err != nil {
					s.log.Warn("widget error log", "err", err)
				}
			}()
		}
	case "result":
		if ch, ok := s.pending[msg.ID]; ok {
			delete(s.pending, msg.ID)
			if msg.OK {
				ch <- result{data: msg.Data}
			} else {
				ch <- result{err: errors.New(msg.Error)}
			}
		}
	}
}

// Snapshot returns the latest game info and state (nil until received) and
// whether a game is connected and still running.
// AnswerTimeout is how long a request to the widget (map view, build options...) waits for its answer.
var AnswerTimeout = 30 * time.Second

// Why says why there is no live game to act on ("" when there is): the strategist logs it when idle.
func (s *Server) Why() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case s.conn == nil:
		return "no game connected"
	case s.over:
		return "the game is marked over (gameover received; a new game's hello clears it)"
	case s.info == nil:
		return "the game connected but sent no hello yet"
	case s.state == nil:
		return "no state from the game yet"
	case s.state.Paused:
		return "the game is paused"
	}
	return ""
}

func (s *Server) Snapshot() (*Info, *State, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.info, s.state, s.conn != nil && !s.over
}

func (s *Server) write(msg message) error {
	s.mu.Lock()
	conn := s.conn
	s.mu.Unlock()
	if conn == nil {
		return ErrOffline
	}
	b, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	if d, ok := conn.(interface{ SetWriteDeadline(time.Time) error }); ok {
		d.SetWriteDeadline(time.Now().Add(5 * time.Second))
	}
	_, err = conn.Write(append(b, '\n'))
	return err
}

// Do sends an action to a sub-commander and waits for the widget's answer.
func (s *Server) Do(ctx context.Context, sub int, op string, args map[string]any) (json.RawMessage, error) {
	id := s.nextID.Add(1)
	ch := make(chan result, 1)
	s.mu.Lock()
	s.pending[id] = ch
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.pending, id)
		s.mu.Unlock()
	}()
	if err := s.write(message{Type: "action", ID: id, Sub: sub, Op: op, Args: args}); err != nil {
		return nil, err
	}
	// 30 s: over the file transport (Docker Desktop's mount, polled) a widget's answer arrived after the
	// old 10 s even when the game answered at once (every map view and build options request failed)
	ctx, cancel := context.WithTimeoutCause(ctx, AnswerTimeout, errors.New("game did not answer in time (paused or minimised?)"))
	defer cancel()
	select {
	case r := <-ch:
		return r.data, r.err
	case <-ctx.Done():
		return nil, context.Cause(ctx)
	}
}

// decide answers one "decide" request; the reply carries the answers or an error.
func (s *Server) decide(msg message) {
	reply := message{Type: "decision", ID: msg.ID}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	data, err := s.Decide(ctx, msg.Args)
	cancel()
	reply.Data = data
	if err != nil {
		reply.Error = err.Error()
		s.log.Warn("decision failed", "err", err)
	} else {
		reply.OK = true
	}
	if err := s.write(reply); err != nil && !errors.Is(err, ErrOffline) {
		s.log.Warn("decision reply", "err", err)
	}
}

// Tell sends an action without waiting (status lines, notes).
func (s *Server) Tell(sub int, op string, args map[string]any) {
	if err := s.write(message{Type: "action", ID: s.nextID.Add(1), Sub: sub, Op: op, Args: args}); err != nil && !errors.Is(err, ErrOffline) {
		s.log.Warn("tell", "op", op, "err", err)
	}
}
