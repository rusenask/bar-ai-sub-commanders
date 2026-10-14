package game

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The widget's side of the file transport: start a session, say hello, answer an action.
func TestFileTransport(t *testing.T) {
	dir := t.TempDir()
	s := NewServer("127.0.0.1:0", slog.New(slog.NewTextHandler(io.Discard, nil)))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var over map[string]any
	gotOver := make(chan struct{})
	s.OnHello = func(info *Info) map[string]any {
		if info.Faction == "Cortex" && len(info.Enemies) == 1 {
			return map[string]any{"key": "cortex-vs-armada-medium", "rules": map[string]any{"engage_attack": 1.3}}
		}
		return nil
	}
	s.OnGameOver = func(info *Info, summary map[string]any) {
		over = summary
		close(gotOver)
	}
	go s.RunFiles(ctx, dir)

	appendLine := func(name, line string) {
		f, err := os.OpenFile(filepath.Join(dir, name), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			t.Fatal(err)
		}
		f.WriteString(line + "\n")
		f.Close()
	}
	if err := os.WriteFile(filepath.Join(dir, "session.txt"), []byte("s1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	appendLine("s1.w2b.jsonl", `{"type":"hello","game":{"map":"Testmap","faction":"Cortex","enemies":["Armada"],"frame":30}}`)

	// the bridge answers hello with its config
	waitFor := func(what string, cond func() bool) {
		deadline := time.Now().Add(5 * time.Second)
		for !cond() {
			if time.Now().After(deadline) {
				t.Fatalf("timed out waiting for %s", what)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	readOut := func() []map[string]any {
		f, err := os.Open(filepath.Join(dir, "s1.b2w.jsonl"))
		if err != nil {
			return nil
		}
		defer f.Close()
		var out []map[string]any
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			var m map[string]any
			if json.Unmarshal(sc.Bytes(), &m) == nil {
				out = append(out, m)
			}
		}
		return out
	}
	waitFor("config", func() bool {
		for _, m := range readOut() {
			if m["type"] == "config" {
				return true
			}
		}
		return false
	})
	waitFor("learned rules", func() bool {
		for _, m := range readOut() {
			if m["type"] == "learned" {
				return true
			}
		}
		return false
	})
	if info, _, online := s.Snapshot(); info == nil || info.Map != "Testmap" || !online {
		t.Fatalf("snapshot %+v online=%v", info, online)
	}

	// an action round trip: the widget answers with a result
	done := make(chan error, 1)
	var got json.RawMessage
	go func() {
		var err error
		got, err = s.Do(ctx, 2, "set_posture", map[string]any{"posture": "spend"})
		done <- err
	}()
	var id float64
	waitFor("action", func() bool {
		for _, m := range readOut() {
			if m["type"] == "action" {
				id = m["id"].(float64)
				return true
			}
		}
		return false
	})
	appendLine("s1.w2b.jsonl", `{"type":"result","id":`+strings.TrimSuffix(strings.TrimSuffix(jsonNum(id), ".0"), ".")+`,"ok":true,"data":{"done":true}}`)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if string(got) != `{"done":true}` {
		t.Errorf("result %s", got)
	}

	appendLine("s1.w2b.jsonl", `{"type":"gameover","args":{"won":true,"minutes":40}}`)
	select {
	case <-gotOver:
	case <-time.After(5 * time.Second):
		t.Fatal("no game over")
	}
	if over["won"] != true {
		t.Errorf("summary %v", over)
	}

	// a new session replaces the old one
	os.WriteFile(filepath.Join(dir, "session.txt"), []byte("s2"), 0o644)
	appendLine("s2.w2b.jsonl", `{"type":"hello","game":{"map":"Other","frame":1}}`)
	waitFor("second session", func() bool {
		info, _, _ := s.Snapshot()
		return info != nil && info.Map == "Other"
	})
}

func jsonNum(f float64) string {
	b, _ := json.Marshal(f)
	return string(b)
}
