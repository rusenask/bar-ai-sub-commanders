// Package decider talks to a "System One" decision model (TypeSafe's
// /v1/systemone contract, served by Kev, Clef and similar): a state and typed
// questions in, calibrated probabilities out, in tens of milliseconds. The
// widget uses it for frequent small choices the LLM strategist is too slow for.
package decider

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Client calls a /v1/systemone endpoint.
type Client struct {
	URL   string // base URL, e.g. http://100.108.100.25:8009
	Model string // model name sent with each request (servers may ignore it)
	HTTP  *http.Client
}

// New returns a client with a short timeout: a late decision is worthless, the widget falls back to rules.
func New(url, model string) *Client {
	return &Client{URL: strings.TrimRight(url, "/"), Model: model, HTTP: &http.Client{Timeout: 3 * time.Second}}
}

// Decide sends the state and questions (as the widget built them) and returns the answers object
// ({"<question>": {"type": ..., "choice"/"noul"/"score": ..., "probabilities": ...}}).
func (c *Client) Decide(ctx context.Context, state string, questions json.RawMessage) (json.RawMessage, error) {
	body, err := json.Marshal(map[string]any{"model": c.Model, "state": state, "questions": questions})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.URL+"/v1/systemone", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("decider: %s: %s", resp.Status, bytes.TrimSpace(data))
	}
	// Kev answers {"answers": ...}, Clef (Workers AI style) {"result": {"answers": ...}}
	var out struct {
		Answers json.RawMessage `json:"answers"`
		Result  struct {
			Answers json.RawMessage `json:"answers"`
		} `json:"result"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, fmt.Errorf("decider: decode: %w", err)
	}
	if len(out.Answers) > 0 {
		return out.Answers, nil
	}
	if len(out.Result.Answers) > 0 {
		return out.Result.Answers, nil
	}
	return nil, fmt.Errorf("decider: no answers in response")
}
