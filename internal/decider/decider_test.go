package decider

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestDecideReadsBothResponseShapes(t *testing.T) {
	for name, body := range map[string]string{
		"kev":  `{"model":"kev-latest","answers":{"unit":{"type":"choice","choice":"legcen"}},"latency_ms":40}`,
		"clef": `{"result":{"answers":{"unit":{"type":"choice","choice":"legcen"}},"usage":{"input_tokens":10}}}`,
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/v1/systemone" {
				t.Errorf("%s: path %s", name, r.URL.Path)
			}
			var in map[string]json.RawMessage
			if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in["state"] == nil || in["questions"] == nil {
				t.Errorf("%s: request %v %v", name, in, err)
			}
			w.Write([]byte(body))
		}))
		answers, err := New(srv.URL, "x").Decide(context.Background(), "state", json.RawMessage(`{"unit":{"type":"choice","instructions":"?","criteria":{"legcen":"riot"}}}`))
		srv.Close()
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		var a map[string]struct{ Choice string }
		if err := json.Unmarshal(answers, &a); err != nil || a["unit"].Choice != "legcen" {
			t.Errorf("%s: answers %s (%v)", name, answers, err)
		}
	}
}
