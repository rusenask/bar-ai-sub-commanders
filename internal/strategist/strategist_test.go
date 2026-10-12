package strategist

import (
	"errors"
	"io"
	"log/slog"
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
