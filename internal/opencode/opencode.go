// Package opencode drives a headless `opencode serve` instance: it can start
// one in the strategist directory and talk to its session API.
package opencode

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Client talks to an opencode server.
type Client struct {
	BaseURL string
	HTTP    *http.Client
}

// Model selects a provider/model pair as configured in opencode.
type Model struct {
	ProviderID string `json:"providerID"`
	ModelID    string `json:"modelID"`
}

// ParseModel splits "provider/model".
func ParseModel(s string) (Model, error) {
	provider, model, ok := strings.Cut(s, "/")
	if !ok || provider == "" || model == "" {
		return Model{}, fmt.Errorf("model %q: want provider/model", s)
	}
	return Model{ProviderID: provider, ModelID: model}, nil
}

// Prompt is one user turn.
type Prompt struct {
	Agent   string
	Model   Model
	Variant string
	Text    string
}

// Tokens is the usage reported for one assistant turn.
type Tokens struct {
	Input     float64 `json:"input"`
	Output    float64 `json:"output"`
	Reasoning float64 `json:"reasoning"`
	Cache     struct {
		Read  float64 `json:"read"`
		Write float64 `json:"write"`
	} `json:"cache"`
}

// ToolCall is a tool the agent used during the turn.
type ToolCall struct {
	Tool   string
	Status string
	Input  json.RawMessage
	Output string
}

// Reply is the result of a prompt.
type Reply struct {
	Text   string
	Tools  []ToolCall
	Tokens Tokens
}

func (c *Client) do(ctx context.Context, method, path string, body, out any) error {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, rd)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("opencode %s %s: %s: %s", method, path, resp.Status, bytes.TrimSpace(data))
	}
	if out != nil {
		if err := json.Unmarshal(data, out); err != nil {
			return fmt.Errorf("opencode %s %s: decode: %w", method, path, err)
		}
	}
	return nil
}

// Healthy reports whether the server answers.
func (c *Client) Healthy(ctx context.Context) bool {
	return c.do(ctx, http.MethodGet, "/global/health", nil, nil) == nil
}

// CreateSession starts a new session and returns its id.
func (c *Client) CreateSession(ctx context.Context, title string) (string, error) {
	var out struct {
		ID string `json:"id"`
	}
	if err := c.do(ctx, http.MethodPost, "/session", map[string]any{"title": title}, &out); err != nil {
		return "", err
	}
	return out.ID, nil
}

// Send posts a user message and waits for the agent to finish its turn.
func (c *Client) Send(ctx context.Context, sessionID string, p Prompt) (*Reply, error) {
	body := map[string]any{
		"agent": p.Agent,
		"model": p.Model,
		"parts": []map[string]any{{"type": "text", "text": p.Text}},
	}
	if p.Variant != "" {
		body["variant"] = p.Variant
	}
	var last message
	if err := c.do(ctx, http.MethodPost, "/session/"+sessionID+"/message", body, &last); err != nil {
		return nil, err
	}
	if len(last.Info.Error) > 0 && string(last.Info.Error) != "null" {
		return nil, fmt.Errorf("agent error: %s", last.Info.Error)
	}
	// A turn with tool calls spans several assistant messages; the response
	// only has the last one, so gather the rest of the turn from the session.
	turn := []message{last}
	var all []message
	if err := c.do(ctx, http.MethodGet, "/session/"+sessionID+"/message", nil, &all); err == nil {
		turn = turn[:0]
		for _, m := range all {
			if m.Info.Role == "assistant" && m.Info.ParentID == last.Info.ParentID {
				turn = append(turn, m)
			}
		}
	}
	reply := &Reply{}
	for _, m := range turn {
		t := m.Info.Tokens
		reply.Tokens.Input += t.Input
		reply.Tokens.Output += t.Output
		reply.Tokens.Reasoning += t.Reasoning
		reply.Tokens.Cache.Read += t.Cache.Read
		reply.Tokens.Cache.Write += t.Cache.Write
		for _, part := range m.Parts {
			if part.Type != "tool" {
				continue
			}
			output := part.State.Output
			if part.State.Status == "error" {
				output = part.State.Error
			}
			reply.Tools = append(reply.Tools, ToolCall{Tool: part.Tool, Status: part.State.Status, Input: part.State.Input, Output: output})
		}
	}
	var texts []string
	for _, part := range last.Parts {
		if t := strings.TrimSpace(part.Text); part.Type == "text" && t != "" {
			texts = append(texts, t)
		}
	}
	reply.Text = strings.Join(texts, "\n")
	return reply, nil
}

type message struct {
	Info struct {
		Role     string          `json:"role"`
		ParentID string          `json:"parentID"`
		Error    json.RawMessage `json:"error"`
		Tokens   Tokens          `json:"tokens"`
	} `json:"info"`
	Parts []struct {
		Type  string `json:"type"`
		Text  string `json:"text"`
		Tool  string `json:"tool"`
		State struct {
			Status string          `json:"status"`
			Input  json.RawMessage `json:"input"`
			Output string          `json:"output"`
			Error  string          `json:"error"`
		} `json:"state"`
	} `json:"parts"`
}

// Abort stops a running turn.
func (c *Client) Abort(ctx context.Context, sessionID string) error {
	return c.do(ctx, http.MethodPost, "/session/"+sessionID+"/abort", nil, nil)
}

// Serve starts `opencode serve` in dir and returns a client for it. The
// process is killed when ctx ends.
func Serve(ctx context.Context, bin, dir, host string, port int, log *slog.Logger) (*Client, error) {
	if port == 0 {
		p, err := freePort()
		if err != nil {
			return nil, err
		}
		port = p
	}
	cmd := exec.CommandContext(ctx, bin, "serve", "--port", strconv.Itoa(port), "--hostname", host)
	cmd.Dir = dir
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	cmd.WaitDelay = 3 * time.Second
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start opencode: %w", err)
	}
	go func() {
		err := cmd.Wait()
		if ctx.Err() == nil {
			log.Error("opencode serve exited", "err", err)
		}
	}()
	c := &Client{BaseURL: "http://127.0.0.1:" + strconv.Itoa(port), HTTP: &http.Client{Timeout: 5 * time.Minute}}
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		hctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		ok := c.Healthy(hctx)
		cancel()
		if ok {
			log.Info("opencode ready", "url", c.BaseURL, "dir", dir)
			return c, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
	return nil, errors.New("opencode serve did not become healthy within 60s")
}

func freePort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port, nil
}
