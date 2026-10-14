package strategist

import (
	"errors"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/rusenask/bar-ai-sub-commanders/internal/game"
)

func TestFailedReviewsBackOff(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	s := New(Config{Interval: 30 * time.Second, Urgent: 8 * time.Second}, game.NewServer("127.0.0.1:0", log), nil, log)
	sub := game.Sub{ID: 1, Name: "Economy 1", AI: true}

	frame := 1000
	if s.due(sub, frame) == "" {
		t.Fatal("a new sub-commander should be reviewed right away")
	}
	ss := s.subs[1]
	ss.busy = false
	s.fail(sub, ss, frame, errors.New("opencode down"))
	if why := s.due(sub, frame+30); why != "" {
		t.Fatalf("reviewed again 1 s after a failure: %q", why)
	}
	if why := s.due(sub, frame+seconds(5*time.Second)); why == "" {
		t.Fatal("not retried after the first backoff")
	}

	// repeated failures wait longer, capped at 2 minutes
	for range 10 {
		ss.busy = false
		s.fail(sub, ss, frame, errors.New("opencode down"))
	}
	ss.busy = false
	if why := s.due(sub, frame+seconds(90*time.Second)); why != "" {
		t.Fatalf("retried within 90 s after many failures: %q", why)
	}
	if why := s.due(sub, frame+seconds(2*time.Minute)); why == "" {
		t.Fatal("backoff should be capped at 2 minutes")
	}
}

func TestPaceLine(t *testing.T) {
	line := paceLine(8*60*framesPerSecond, game.Economy{MetalIncome: 20, EnergyIncome: 300})
	if !strings.Contains(line, "Pace: metal income 20.0/s, energy 300/s at 8 min; strong players' 1v1s at 8 min: metal ") {
		t.Errorf("pace line %q", line)
	}
	if paceLine(60*framesPerSecond, game.Economy{}) != "" {
		t.Error("no pace in the first two minutes")
	}
}

func TestParseOps(t *testing.T) {
	ops, err := parseOps("Here you go:\n```json\n[{\"op\":\"confirm\",\"id\":2},{\"op\":\"create\",\"text\":\"x\",\"stage\":\"mid\"}]\n```")
	if err != nil || len(ops) != 2 || ops[0].Op != "confirm" || ops[1].Stage != "mid" {
		t.Fatalf("%v %+v", err, ops)
	}
	if _, err := parseOps("nothing to add"); err == nil {
		t.Error("no array is an error (the book stays as it was)")
	}
	if stageOf(30*60*5) != "opening" || stageOf(30*60*12) != "mid" || stageOf(30*60*40) != "late" {
		t.Error("stages")
	}
}
