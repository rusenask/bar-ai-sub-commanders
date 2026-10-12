// Package tools exposes the game to the opencode strategist as MCP tools.
// opencode prefixes them with the server name, e.g. bar_set_posture.
package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/rusenask/bar-ai-sub-commanders/internal/game"
)

// Guard decides whether the agent may act for a sub-commander right now.
type Guard func(subID int) error

type subArg struct {
	SubID int `json:"sub_id" jsonschema:"your sub-commander id (given in every report)"`
}

type postureArgs struct {
	SubID   int    `json:"sub_id" jsonschema:"your sub-commander id"`
	Posture string `json:"posture" jsonschema:"conserve | balanced | spend"`
}

type roleArgs struct {
	SubID int    `json:"sub_id" jsonschema:"your sub-commander id"`
	Role  string `json:"role" jsonschema:"economy | defense | airdefense | army"`
}

type focusArgs struct {
	SubID int      `json:"sub_id" jsonschema:"your sub-commander id"`
	Units []string `json:"units" jsonschema:"unit names from get_build_options (e.g. legcen); empty list = automatic production"`
}

type zoneArgs struct {
	SubID int     `json:"sub_id" jsonschema:"your sub-commander id"`
	Kind  string  `json:"kind" jsonschema:"circle or rect"`
	X     float64 `json:"x,omitempty" jsonschema:"circle centre x (elmos, 0..mapX)"`
	Z     float64 `json:"z,omitempty" jsonschema:"circle centre z (elmos, 0..mapZ)"`
	R     float64 `json:"r,omitempty" jsonschema:"circle radius 200..3000"`
	X1    float64 `json:"x1,omitempty" jsonschema:"rect min x"`
	Z1    float64 `json:"z1,omitempty" jsonschema:"rect min z"`
	X2    float64 `json:"x2,omitempty" jsonschema:"rect max x"`
	Z2    float64 `json:"z2,omitempty" jsonschema:"rect max z"`
}

type pausedArgs struct {
	SubID  int  `json:"sub_id" jsonschema:"your sub-commander id"`
	Paused bool `json:"paused" jsonschema:"true stops all of your automatic decisions"`
}

type tellArgs struct {
	SubID   int    `json:"sub_id" jsonschema:"your sub-commander id"`
	Message string `json:"message" jsonschema:"short message for the player (shown in their console), e.g. a request for more constructors"`
}

func text(s string) *mcp.CallToolResult {
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: s}}}
}

func fail(err error) *mcp.CallToolResult {
	r := text("error: " + err.Error())
	r.IsError = true
	return r
}

func asJSON(v any) *mcp.CallToolResult {
	b, err := json.Marshal(v)
	if err != nil {
		return fail(err)
	}
	return text(string(b))
}

// Handler returns an HTTP handler serving the MCP tools (streamable HTTP).
func Handler(g *game.Server, guard Guard) http.Handler {
	s := mcp.NewServer(&mcp.Implementation{Name: "bar", Version: "0.1.0"}, nil)

	// tell_player is rate limited per sub-commander so a worried model can't spam the console
	var tellMu sync.Mutex
	lastTell := map[int]int{}
	const tellEveryFrames = 30 * 90

	act := func(ctx context.Context, sub int, op string, args map[string]any, done string) *mcp.CallToolResult {
		if err := guard(sub); err != nil {
			return fail(err)
		}
		data, err := g.Do(ctx, sub, op, args)
		if err != nil {
			return fail(err)
		}
		if len(data) > 0 && string(data) != "null" {
			return text(string(data))
		}
		return text(done)
	}

	mcp.AddTool(s, &mcp.Tool{
		Name:        "get_overview",
		Description: "Whole-team picture: economy, every sub-commander (role, posture, zones, threats, last activity) and enemy intel. Use when you need more than your report.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in subArg) (*mcp.CallToolResult, any, error) {
		if err := guard(in.SubID); err != nil {
			return fail(err), nil, nil
		}
		info, state, ok := g.Snapshot()
		if !ok || state == nil {
			return fail(game.ErrOffline), nil, nil
		}
		return asJSON(map[string]any{"game": info, "state": state}), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "get_build_options",
		Description: "What your constructors and factories can build: unit name, display name, kind, metal/energy cost, tech level. Needed before set_focus.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in subArg) (*mcp.CallToolResult, any, error) {
		return act(ctx, in.SubID, "build_options", nil, "[]"), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "set_posture",
		Description: "How freely you spend the shared team resources. conserve: only from excess, cheap builds, low build priority. balanced: normal. spend: use everything, biggest affordable options, larger unit caps.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in postureArgs) (*mcp.CallToolResult, any, error) {
		return act(ctx, in.SubID, "set_posture", map[string]any{"posture": in.Posture}, "posture set to "+in.Posture), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "set_role",
		Description: "Change what you do. Only when the player's orders call for it or the situation clearly demands it; the player chose your role.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in roleArgs) (*mcp.CallToolResult, any, error) {
		return act(ctx, in.SubID, "set_role", map[string]any{"role": in.Role}, "role set to "+in.Role), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "set_focus",
		Description: "Restrict what your FACTORIES produce to these mobile unit types (names from get_build_options, by=factory). It cannot make constructors build a structure and does nothing if you own no factory. Empty list returns to automatic production for your role.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in focusArgs) (*mcp.CallToolResult, any, error) {
		units := in.Units
		if units == nil {
			units = []string{}
		}
		return act(ctx, in.SubID, "set_focus", map[string]any{"units": units}, fmt.Sprintf("focus set to %v", units)), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "add_zone",
		Description: "Add an area you build and fight in (world coordinates in elmos: x east, z south). Zones are additive; use clear_zones first to move.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in zoneArgs) (*mcp.CallToolResult, any, error) {
		zone := map[string]any{"kind": in.Kind}
		switch in.Kind {
		case "circle":
			zone["x"], zone["z"], zone["r"] = in.X, in.Z, in.R
		case "rect":
			zone["x1"], zone["z1"], zone["x2"], zone["z2"] = in.X1, in.Z1, in.X2, in.Z2
		default:
			return fail(fmt.Errorf("kind must be circle or rect")), nil, nil
		}
		return act(ctx, in.SubID, "add_zone", map[string]any{"zone": zone}, "zone added"), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "clear_zones",
		Description: "Remove all your zones (then add new ones; without zones you act anywhere).",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in subArg) (*mcp.CallToolResult, any, error) {
		return act(ctx, in.SubID, "clear_zones", nil, "zones cleared"), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "set_paused",
		Description: "Pause or resume all your automatic decisions (units keep their current orders).",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in pausedArgs) (*mcp.CallToolResult, any, error) {
		return act(ctx, in.SubID, "set_paused", map[string]any{"paused": in.Paused}, fmt.Sprintf("paused=%v", in.Paused)), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "tell_player",
		Description: "Send the player a short message (requests, warnings). Use sparingly; your final reply is already shown in your log.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in tellArgs) (*mcp.CallToolResult, any, error) {
		frame := 0
		if _, state, _ := g.Snapshot(); state != nil {
			frame = state.Frame
		}
		tellMu.Lock()
		last, told := lastTell[in.SubID]
		tooSoon := told && frame-last < tellEveryFrames
		tellMu.Unlock()
		if tooSoon {
			return fail(fmt.Errorf("you messaged the player %ds ago; they saw it, don't repeat it (put it in your one-sentence reply instead)", (frame-last)/30)), nil, nil
		}
		r := act(ctx, in.SubID, "tell_player", map[string]any{"text": in.Message}, "sent")
		if !r.IsError {
			tellMu.Lock()
			lastTell[in.SubID] = frame
			tellMu.Unlock()
		}
		return r, nil, nil
	})

	return mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return s }, &mcp.StreamableHTTPOptions{Stateless: true, JSONResponse: true})
}
