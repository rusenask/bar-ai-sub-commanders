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
	return c.decide(ctx, map[string]any{"state": state, "questions": questions})
}

// decide posts a request body (model is added); System One servers ignore fields they don't know, so task
// requests also carry the task name and flat features for models that take numbers.
func (c *Client) decide(ctx context.Context, fields map[string]any) (json.RawMessage, error) {
	fields["model"] = c.Model
	body, err := json.Marshal(fields)
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

// Router sends each request to the right model: task requests ({task, features}) are rendered here and go
// to that task's model (or the default one); plain requests ({state, questions}) go to the default model.
type Router struct {
	Default *Client
	Tasks   map[string]*Client
}

// ParseRoutes reads "fight=http://host:8011,unit=http://host:8012" into per-task clients.
func ParseRoutes(spec, model string) (map[string]*Client, error) {
	routes := map[string]*Client{}
	for part := range strings.SplitSeq(spec, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		task, url, ok := strings.Cut(part, "=")
		if !ok || task == "" || url == "" {
			return nil, fmt.Errorf("decider route %q: want task=url", part)
		}
		routes[task] = New(url, model)
	}
	return routes, nil
}

// Enabled reports whether any model is configured.
func (r *Router) Enabled() bool {
	return r != nil && (r.Default != nil || len(r.Tasks) > 0)
}

// Decide answers one widget request.
func (r *Router) Decide(ctx context.Context, args map[string]any) (json.RawMessage, error) {
	if task, _ := args["task"].(string); task != "" {
		features, err := json.Marshal(args["features"])
		if err != nil {
			return nil, err
		}
		state, questions, err := Render(task, features)
		if err != nil {
			return nil, err
		}
		c := r.Tasks[task]
		if c == nil {
			c = r.Default
		}
		if c == nil {
			return nil, fmt.Errorf("no decision model for task %q", task)
		}
		flat, err := Flat(task, features)
		if err != nil {
			return nil, err
		}
		return c.decide(ctx, map[string]any{"state": state, "questions": questions, "task": task, "flat": flat})
	}
	if r.Default == nil {
		return nil, fmt.Errorf("no default decision model")
	}
	state, _ := args["state"].(string)
	q, err := json.Marshal(args["questions"])
	if err != nil {
		return nil, err
	}
	return r.Default.Decide(ctx, state, q)
}
