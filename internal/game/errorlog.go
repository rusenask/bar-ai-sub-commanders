package game

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// WidgetError is one line of the widget error log: a Lua error our widgets caught (sc_guard.lua) and
// skipped instead of BAR removing the widget. Count is how often it happened in that game so far (the
// widget reports the 1st, 10th, 100th...); the traceback comes with the first.
type WidgetError struct {
	Time      time.Time `json:"time"`
	Map       string    `json:"map,omitempty"`
	Faction   string    `json:"faction,omitempty"`
	Where     string    `json:"where"`
	Message   string    `json:"message"`
	Count     int       `json:"count"`
	Frame     int       `json:"frame,omitempty"`
	Traceback string    `json:"traceback,omitempty"`
}

func widgetError(info *Info, args map[string]any, now time.Time) WidgetError {
	e := WidgetError{Time: now.UTC()}
	if info != nil {
		e.Map, e.Faction = info.Map, info.Faction
	}
	e.Where, _ = args["where"].(string)
	e.Message, _ = args["message"].(string)
	e.Traceback, _ = args["traceback"].(string)
	if n, ok := args["count"].(float64); ok {
		e.Count = int(n)
	}
	if f, ok := args["frame"].(float64); ok {
		e.Frame = int(f)
	}
	return e
}

// appendWidgetError adds e to the JSONL file at path (made with its directory if missing).
func appendWidgetError(path string, e WidgetError) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	b, err := json.Marshal(e)
	if err != nil {
		f.Close()
		return err
	}
	if _, err := f.Write(append(b, '\n')); err != nil {
		f.Close()
		return fmt.Errorf("write %s: %w", path, err)
	}
	return f.Close()
}
