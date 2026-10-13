package strategist

import (
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/rusenask/bar-ai-sub-commanders/internal/game"
)

func TestPacerIntervals(t *testing.T) {
	cfg := Config{Interval: 30 * time.Second, Urgent: 8 * time.Second}
	var p pacer
	if got, want := p.interval(cfg, false), seconds(60*time.Second); got != want {
		t.Errorf("calm: %d frames, want %d (2 x interval)", got, want)
	}
	if got, want := p.interval(cfg, true), seconds(15*time.Second); got != want {
		t.Errorf("busy before anything is measured: %d, want half the interval %d", got, want)
	}

	// the game runs at 10x (300 frames a second) and the provider answers in 2 s: one turn is 20 s of
	// game time (24 with slack)
	start := time.Unix(1000, 0)
	p.observe(0, start)
	p.observe(300, start.Add(time.Second))
	p.took(2 * time.Second)
	if got, want := p.interval(cfg, true), int(2*300*1.2); got != want {
		t.Errorf("busy at 10x: %d, want %d", got, want)
	}

	// normal speed, fast provider: never more often than Urgent
	var q pacer
	q.observe(0, start)
	q.observe(30, start.Add(time.Second))
	q.took(time.Second)
	if got, want := q.interval(cfg, true), seconds(8*time.Second); got != want {
		t.Errorf("busy at 1x: %d, want urgent %d", got, want)
	}

	// a very slow provider: no less often than Interval
	q.took(10 * time.Minute)
	if got, want := q.interval(cfg, true), seconds(30*time.Second); got != want {
		t.Errorf("slow provider: %d, want interval %d", got, want)
	}
}

func TestPacerCapsReviewsInFlight(t *testing.T) {
	cfg := Config{MaxInFlight: 2}
	var p pacer
	if !p.start(cfg) || !p.start(cfg) {
		t.Fatal("two reviews should start")
	}
	if p.start(cfg) {
		t.Fatal("a third review started past the cap")
	}
	p.done()
	if !p.start(cfg) {
		t.Fatal("a slot freed up")
	}
}

func TestBusySubsAreReviewedSooner(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	s := New(Config{Interval: 30 * time.Second, Urgent: 8 * time.Second}, game.NewServer("127.0.0.1:0", log), nil, log)
	calm := game.Sub{ID: 1, AI: true}
	busy := game.Sub{ID: 2, AI: true, Squad: &game.Squad{Action: "engage", Ratio: 1.4}}
	for _, sub := range []game.Sub{calm, busy} {
		if s.due(sub, 0) == "" {
			t.Fatal("first report")
		}
		s.subs[sub.ID].busy, s.subs[sub.ID].reports = false, 1
	}
	at := seconds(20 * time.Second)
	if why := s.due(calm, at); why != "" {
		t.Errorf("calm sub reviewed after 20 s: %q", why)
	}
	if why := s.due(busy, at); why != "the situation is moving" {
		t.Errorf("fighting army not reviewed after 20 s: %q", why)
	}
}
