package game

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// The file transport: BAR from game version test-31614 sandboxes user widgets (no sockets; writes only
// under LuaUI/Config/), so the widget (widget/LuaUI/Include/sc_link.lua) talks through files in
// LuaUI/Config/scbridge/, a folder the bridge watches (mounted into its container):
//
//	session.txt              the widget's current session id; a new one is a new link
//	<session>.w2b.<n>.jsonl  widget -> bridge, in segments: each full one ends with {"type":"next"}, and the
//	                         bridge deletes it once read
//	<session>.b2w.jsonl      bridge -> widget (small)
//
// Housekeeping: when a new session starts, the previous session's files go; at start, files older than
// MaxAge go. Nothing piles up across games.

const (
	pollEvery = 150 * time.Millisecond // Docker Desktop's mounts don't deliver change events
	pingEvery = 10 * time.Second       // the widget drops a silent bridge after 30 s
	// MaxAge: files older than this in the folder are left from old games.
	MaxAge = 24 * time.Hour
)

var nextMarker = []byte(`{"type":"next"}`)

// FileListener watches dir for widget sessions.
type FileListener struct {
	dir     string
	mu      sync.Mutex
	session string
	current *fileConn
	closed  chan struct{}
	once    sync.Once
}

// ListenFiles watches dir (created if missing) and clears what old games left there.
func ListenFiles(dir string) (*FileListener, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	l := &FileListener{dir: dir, closed: make(chan struct{})}
	l.removeOlder(MaxAge)
	return l, nil
}

func (l *FileListener) Addr() string { return "files " + l.dir }

func (l *FileListener) Close() error {
	l.once.Do(func() { close(l.closed) })
	return nil
}

// Accept waits for a new session id in session.txt and returns its link; the previous session's files
// are removed (that game is over or restarted).
func (l *FileListener) Accept(ctx context.Context) (Conn, error) {
	tick := time.NewTicker(pollEvery * 3)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-l.closed:
			return nil, errors.New("closed")
		case <-tick.C:
		}
		data, err := os.ReadFile(filepath.Join(l.dir, "session.txt"))
		if err != nil {
			continue
		}
		id := string(bytes.TrimSpace(data))
		if id == "" || id == l.session || strings.ContainsAny(id, `/\`) || strings.Contains(id, "..") {
			continue
		}
		l.mu.Lock()
		prev := l.session
		l.session = id
		l.current = newFileConn(l.dir, id)
		c := l.current
		l.mu.Unlock()
		if prev != "" {
			l.removeSession(prev)
		}
		return c, nil
	}
}

// removeSession deletes one session's files.
func (l *FileListener) removeSession(id string) {
	files, _ := filepath.Glob(filepath.Join(l.dir, id+".*"))
	for _, f := range files {
		os.Remove(f)
	}
}

// removeOlder deletes session files not touched for age (session.txt stays: it names the live game).
func (l *FileListener) removeOlder(age time.Duration) {
	entries, _ := os.ReadDir(l.dir)
	for _, e := range entries {
		if e.IsDir() || e.Name() == "session.txt" {
			continue
		}
		if info, err := e.Info(); err == nil && time.Since(info.ModTime()) > age {
			os.Remove(filepath.Join(l.dir, e.Name()))
		}
	}
}

// fileConn is one session: Read follows the widget's segments (deleting each it finished), Write appends
// to the bridge's file, and a ping goes out every pingEvery so the widget knows the bridge is there.
type fileConn struct {
	dir, session string
	seg          int
	f            *os.File
	r            *bufio.Reader
	pending      []byte
	mu           sync.Mutex
	closed       chan struct{}
	once         sync.Once
}

func newFileConn(dir, session string) *fileConn {
	c := &fileConn{dir: dir, session: session, closed: make(chan struct{})}
	go c.pinger()
	return c
}

func (c *fileConn) Describe() string { return "files " + filepath.Join(c.dir, c.session) }

func (c *fileConn) segPath(n int) string {
	return filepath.Join(c.dir, fmt.Sprintf("%s.w2b.%d.jsonl", c.session, n))
}

// Read returns the widget's next complete lines; a "next" line moves to the following segment.
func (c *fileConn) Read(p []byte) (int, error) {
	for {
		if len(c.pending) > 0 {
			n := copy(p, c.pending)
			c.pending = c.pending[n:]
			return n, nil
		}
		select {
		case <-c.closed:
			return 0, io.EOF
		default:
		}
		if c.f == nil {
			f, err := os.Open(c.segPath(c.seg))
			if err != nil {
				time.Sleep(pollEvery)
				continue
			}
			c.f, c.r = f, bufio.NewReaderSize(f, 64*1024)
		}
		line, err := c.r.ReadBytes('\n')
		if err != nil {
			// a partial line stays in the file: read it again once it's complete
			if len(line) > 0 {
				if _, serr := c.f.Seek(-int64(len(line)), io.SeekCurrent); serr == nil {
					c.r.Reset(c.f)
				}
			}
			time.Sleep(pollEvery)
			continue
		}
		if bytes.Equal(bytes.TrimSpace(line), nextMarker) {
			c.f.Close()
			os.Remove(c.segPath(c.seg))
			c.f, c.r = nil, nil
			c.seg++
			continue
		}
		c.pending = line
	}
}

func (c *fileConn) Write(p []byte) (int, error) {
	select {
	case <-c.closed:
		return 0, ErrOffline
	default:
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	f, err := os.OpenFile(filepath.Join(c.dir, c.session+".b2w.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	return f.Write(p)
}

func (c *fileConn) pinger() {
	t := time.NewTicker(pingEvery)
	defer t.Stop()
	for {
		select {
		case <-c.closed:
			return
		case <-t.C:
			c.Write([]byte(`{"type":"ping"}` + "\n"))
		}
	}
}

func (c *fileConn) Close() error {
	c.once.Do(func() {
		close(c.closed)
		if c.f != nil {
			c.f.Close()
		}
	})
	return nil
}
