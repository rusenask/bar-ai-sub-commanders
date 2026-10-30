package game

import (
	"bufio"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A widgeterror message lands in the error log with the game it came from.
func TestWidgetErrorLog(t *testing.T) {
	path := filepath.Join(t.TempDir(), "logs", "widget-errors.jsonl")
	s := NewServer("127.0.0.1:0", slog.New(slog.NewTextHandler(io.Discard, nil)))
	s.ErrorLog = path
	s.handle(message{Type: "hello", Game: &Info{Map: "Testmap", Faction: "Legion"}})
	s.handle(message{Type: "widgeterror", Args: map[string]any{
		"where": "Tactics.updatePush", "message": "attempt to compare boolean with number",
		"count": float64(1), "frame": float64(195300), "traceback": "stack traceback: ...",
	}})
	s.handle(message{Type: "widgeterror", Args: map[string]any{"where": "Tactics.updatePush", "message": "attempt to compare boolean with number", "count": float64(10)}})

	var got []WidgetError
	deadline := time.Now().Add(5 * time.Second)
	for len(got) < 2 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
		got = got[:0]
		f, err := os.Open(path)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			var e WidgetError
			if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
				t.Fatal(err)
			}
			got = append(got, e)
		}
		f.Close()
	}
	if len(got) != 2 {
		t.Fatalf("got %d lines, want 2", len(got))
	}
	e := got[0]
	if got[1].Count == 1 {
		e = got[1]
	}
	if e.Map != "Testmap" || e.Faction != "Legion" || e.Where != "Tactics.updatePush" || e.Frame != 195300 || e.Traceback == "" {
		t.Errorf("first error: %+v", e)
	}
}
