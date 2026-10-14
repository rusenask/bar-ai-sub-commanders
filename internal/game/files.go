package game

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// The file transport: BAR from game version test-31614 sandboxes user widgets (no sockets; files only
// under LuaUI/Config/), so the AI widget talks through two append-only files in LuaUI/Config/scbridge/:
//
//	session.txt              the widget's current session id (rewritten when it starts)
//	<session>.w2b.jsonl      widget -> bridge, one JSON message per line
//	<session>.b2w.jsonl      bridge -> widget
//
// The bridge watches the directory (mounted into its container), treats each new session as a new
// connection and serves it like a TCP one.

// pollEvery is how often the files are checked (Docker Desktop's mounts don't deliver change events).
const pollEvery = 150 * time.Millisecond

// fileConn is one session: Read tails the widget's file, Write appends to the bridge's.
type fileConn struct {
	in, out string
	mu      sync.Mutex
	f       *os.File // the widget's file, opened once it exists
	closed  chan struct{}
	once    sync.Once
}

func newFileConn(dir, session string) *fileConn {
	return &fileConn{
		in:     filepath.Join(dir, session+".w2b.jsonl"),
		out:    filepath.Join(dir, session+".b2w.jsonl"),
		closed: make(chan struct{}),
	}
}

func (c *fileConn) Read(p []byte) (int, error) {
	for {
		select {
		case <-c.closed:
			return 0, io.EOF
		default:
		}
		c.mu.Lock()
		if c.f == nil {
			if f, err := os.Open(c.in); err == nil {
				c.f = f
			}
		}
		f := c.f
		c.mu.Unlock()
		if f != nil {
			n, err := f.Read(p)
			if n > 0 {
				return n, nil
			}
			if err != nil && !errors.Is(err, io.EOF) {
				return 0, err
			}
		}
		time.Sleep(pollEvery)
	}
}

func (c *fileConn) Write(p []byte) (int, error) {
	select {
	case <-c.closed:
		return 0, ErrOffline
	default:
	}
	f, err := os.OpenFile(c.out, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	return f.Write(p)
}

func (c *fileConn) Close() error {
	c.once.Do(func() {
		close(c.closed)
		c.mu.Lock()
		if c.f != nil {
			c.f.Close()
		}
		c.mu.Unlock()
	})
	return nil
}

func (c *fileConn) String() string { return "files " + strings.TrimSuffix(c.in, ".w2b.jsonl") }

// RunFiles serves widget sessions from the file transport in dir until ctx is cancelled: each new
// session.txt is a new connection (replacing the old one, like a new TCP connection), and every 10 s the
// bridge writes a ping so the widget knows it is there.
func (s *Server) RunFiles(ctx context.Context, dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	s.log.Info("waiting for the game (files)", "dir", dir)
	var session string
	var conn *fileConn
	tick := time.NewTicker(pollEvery * 3)
	defer tick.Stop()
	lastPing := time.Now()
	for {
		select {
		case <-ctx.Done():
			if conn != nil {
				conn.Close()
			}
			return nil
		case <-tick.C:
		}
		data, err := os.ReadFile(filepath.Join(dir, "session.txt"))
		if err == nil {
			if id := string(bytes.TrimSpace(data)); id != "" && id != session && !strings.ContainsAny(id, `/\.`) {
				session = id
				conn = newFileConn(dir, id)
				s.attach(conn)
			}
		}
		if conn != nil && time.Since(lastPing) > 10*time.Second {
			lastPing = time.Now()
			_ = s.write(message{Type: "ping"})
		}
	}
}
