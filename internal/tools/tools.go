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
	"github.com/rusenask/bar-ai-sub-commanders/internal/mapview"
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

type autonomyArgs struct {
	SubID    int    `json:"sub_id" jsonschema:"your sub-commander id"`
	Autonomy string `json:"autonomy" jsonschema:"light | balanced | full"`
}

type raidsArgs struct {
	SubID int  `json:"sub_id" jsonschema:"your sub-commander id"`
	On    bool `json:"on" jsonschema:"true: fast units scout and raid; false: they stay with the army"`
}

type commanderArgs struct {
	SubID int    `json:"sub_id" jsonschema:"your sub-commander id"`
	Set   string `json:"set" jsonschema:"a mode (auto, builder, defender, frontline) or a personality (careful, bold)"`
}

type requestArgs struct {
	SubID int    `json:"sub_id" jsonschema:"your sub-commander id"`
	Kind  string `json:"kind" jsonschema:"defend, constructor or production"`
	X     *int   `json:"x,omitempty" jsonschema:"for defend: where (map x)"`
	Z     *int   `json:"z,omitempty" jsonschema:"for defend: where (map z)"`
	Need  int    `json:"need,omitempty" jsonschema:"how much (metal of enemy strength to answer, or of units)"`
	Note  string `json:"note,omitempty" jsonschema:"one line: why"`
}

type tuneArgs struct {
	SubID int     `json:"sub_id" jsonschema:"your sub-commander id"`
	Key   string  `json:"key" jsonschema:"a rule from 'rules' in the Rules engine line of your report, e.g. max_factories"`
	Value float64 `json:"value" jsonschema:"new value (clamped to the rule's bounds)"`
}

type roleArgs struct {
	SubID int    `json:"sub_id" jsonschema:"your sub-commander id"`
	Role  string `json:"role" jsonschema:"economy | defense | airdefense | army | intelligence"`
}

type focusArgs struct {
	SubID int      `json:"sub_id" jsonschema:"your sub-commander id"`
	Units []string `json:"units" jsonschema:"unit names from get_build_options: mobile units for factories, turret types for constructors (e.g. legcen, leglht); empty list = automatic"`
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

type structuresArgs struct {
	SubID        int    `json:"sub_id" jsonschema:"your sub-commander id"`
	Kind         string `json:"kind,omitempty" jsonschema:"only this kind, e.g. converter, energy, storage, metal extractor, defense turret, anti-air turret, radar, construction turret; empty = all"`
	BlockingOnly bool   `json:"blocking_only,omitempty" jsonschema:"only structures standing in a factory's exit lane or too close to a factory"`
}

type removeArgs struct {
	SubID   int   `json:"sub_id" jsonschema:"your sub-commander id"`
	UnitIDs []int `json:"unit_ids" jsonschema:"structure ids from get_structures (at most 30); empty list cancels pending removals"`
}

type mapArgs struct {
	SubID int    `json:"sub_id" jsonschema:"your sub-commander id"`
	View  string `json:"view,omitempty" jsonschema:"map = the whole map (default); zones = close-up of your zones and their surroundings"`
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

	// terrain doesn't change during a game: keep the height grids already fetched
	var terrainMu sync.Mutex
	terrainCache := map[string]*mapview.Terrain{}
	terrainFor := func(ctx context.Context, sub int, mapName string, scene *mapview.Scene, cells int) (*mapview.Terrain, error) {
		b := scene.Bounds
		key := fmt.Sprintf("%s|%.0f|%.0f|%.0f|%.0f|%d", mapName, b.X1, b.Z1, b.X2, b.Z2, cells)
		terrainMu.Lock()
		t := terrainCache[key]
		terrainMu.Unlock()
		if t != nil {
			return t, nil
		}
		data, err := g.Do(ctx, sub, "terrain", map[string]any{"x1": b.X1, "z1": b.Z1, "x2": b.X2, "z2": b.Z2, "cells": cells})
		if err != nil {
			return nil, err
		}
		if t, err = mapview.ParseTerrain(data); err != nil {
			return nil, err
		}
		terrainMu.Lock()
		if len(terrainCache) >= 32 {
			clear(terrainCache)
		}
		terrainCache[key] = t
		terrainMu.Unlock()
		return t, nil
	}

	mcp.AddTool(s, &mcp.Tool{
		Name:        "get_map_view",
		Description: "A top-down picture of the battlefield: terrain (water, steep slopes, cliffs), a coordinate grid in elmos, every sub-commander's zones, metal spots (free or taken), our and allied units and structures, enemies in sight and recent sightings. view=map shows the whole map, view=zones a close-up around your zones.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in mapArgs) (*mcp.CallToolResult, any, error) {
		if err := guard(in.SubID); err != nil {
			return fail(err), nil, nil
		}
		info, _, ok := g.Snapshot()
		if !ok || info == nil {
			return fail(game.ErrOffline), nil, nil
		}
		view, cells := "map", 256
		if in.View == "zones" {
			view, cells = "zones", 192
		}
		data, err := g.Do(ctx, in.SubID, "map_view", map[string]any{"view": view})
		if err != nil {
			return fail(err), nil, nil
		}
		var scene mapview.Scene
		if err := json.Unmarshal(data, &scene); err != nil {
			return fail(fmt.Errorf("map view: %w", err)), nil, nil
		}
		terrain, err := terrainFor(ctx, in.SubID, info.Map, &scene, cells)
		if err != nil {
			return fail(err), nil, nil
		}
		pic, desc, err := mapview.Render(terrain, &scene, mapview.Options{Title: info.Map, Focus: in.SubID})
		if err != nil {
			return fail(err), nil, nil
		}
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: desc}, &mcp.ImageContent{Data: pic, MIMEType: mapview.MIMEType}}}, nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "get_build_options",
		Description: "What your constructors and factories can build: unit name, display name, kind, metal/energy cost, tech level. Needed before set_focus.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in subArg) (*mcp.CallToolResult, any, error) {
		return act(ctx, in.SubID, "build_options", nil, "[]"), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "get_structures",
		Description: "Your own structures (factories excluded): id, name, kind, position, blocksFactory (stands in a factory's exit lane or too close to it), unfinished, marked (already queued for removal). Blocking ones first, at most 60 listed.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in structuresArgs) (*mcp.CallToolResult, any, error) {
		return act(ctx, in.SubID, "structures", map[string]any{"kind": in.Kind, "blocking_only": in.BlockingOnly}, "{}"), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "remove_structures",
		Description: "Have your constructors reclaim these structures of yours (ids from get_structures), refunding their metal. They are not rebuilt on the same spot for 5 minutes. Factories and anything not yours are refused. Empty list cancels pending removals.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in removeArgs) (*mcp.CallToolResult, any, error) {
		if len(in.UnitIDs) > 30 {
			return fail(fmt.Errorf("at most 30 structures per call")), nil, nil
		}
		ids := in.UnitIDs
		if ids == nil {
			ids = []int{}
		}
		return act(ctx, in.SubID, "remove_structures", map[string]any{"unit_ids": ids}, "queued for removal"), nil, nil
	})

	// posture flip-flopping starves production: at most one change per 90 s of game time per sub-commander
	var postureMu sync.Mutex
	lastPosture := map[int]int{}
	const postureEveryFrames = 30 * 90

	mcp.AddTool(s, &mcp.Tool{
		Name:        "set_posture",
		Description: "How freely you spend the shared team resources. conserve: only from excess, cheap builds, fewer constructors and units, low build priority (rarely right). balanced: normal. spend: use everything, biggest affordable options, larger unit caps. At most one change per 90 s.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in postureArgs) (*mcp.CallToolResult, any, error) {
		frame := 0
		if _, state, _ := g.Snapshot(); state != nil {
			frame = state.Frame
		}
		postureMu.Lock()
		last, changed := lastPosture[in.SubID]
		postureMu.Unlock()
		if changed && frame-last < postureEveryFrames {
			return fail(fmt.Errorf("you changed posture %ds ago; keep it at least 90 s so production can settle", (frame-last)/30)), nil, nil
		}
		r := act(ctx, in.SubID, "set_posture", map[string]any{"posture": in.Posture}, "posture set to "+in.Posture)
		if !r.IsError {
			postureMu.Lock()
			lastPosture[in.SubID] = frame
			postureMu.Unlock()
		}
		return r, nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "set_autonomy",
		Description: "How much you do on your own between reviews. light: only the basics of your role in your zones (no expansion, no factories, turrets only where threats showed up, the army defends its own area). balanced: also expands safely, covers exposed extractors, helps other areas, counter-pushes when clearly stronger. full: also builds factories as income grows, keeps a turret schedule, and the army attacks and raids on its own when the threat map says it wins. The player usually chooses this; change it when their orders ask for more or less initiative.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in autonomyArgs) (*mcp.CallToolResult, any, error) {
		return act(ctx, in.SubID, "set_autonomy", map[string]any{"autonomy": in.Autonomy}, "autonomy set to "+in.Autonomy), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "tune_rules",
		Description: "Tune the rules engine's fast loops (team-wide; they run several times a second, you review every so often). Current values are in the 'Rules engine' line of your report. Each rule belongs to one role and only that role may change it; the others ask via tell_player or their reply. economy: max_factories (lower stops new labs, cancels unstarted ones), nanos_per_lab (construction turrets per lab before another lab), construction_turret_rate (turrets per 10 metal/s of income; higher = more build power), second_factory_income, builder_bonus (mobile constructors). defense: turret_budget_scale (higher = more turrets), retreat_builder. army: engage_attack (ratio needed to start a fight away from home; higher = fewer fights), engage_hold (below it a fight is broken off), engage_defend, chase_distance, retreat_fighter (health at which units leave; higher = fewer losses but fewer kills), raid_share, raid_need, response_weight. One change per rule per 2 minutes, at most half the current value per step. Fix causes, not symptoms: if the army keeps losing fights, check what it builds and where it fights before raising engage thresholds again (a passive army doesn't kill anything). Say why in your reply.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in tuneArgs) (*mcp.CallToolResult, any, error) {
		return act(ctx, in.SubID, "tune_rules", map[string]any{"key": in.Key, "value": in.Value}, "tuned"), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "set_raids",
		Description: "Armies only (on by default): the army's fast units form a raid squad that scouts the enemy's side and hits what it beats (constructors, extractors, generators), routing around their defences and coming home when a fight turns. Off: they stay with the army (e.g. when the base needs every unit).",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in raidsArgs) (*mcp.CallToolResult, any, error) {
		return act(ctx, in.SubID, "set_raids", map[string]any{"on": in.On}, fmt.Sprintf("raids on=%v", in.On)), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "set_commander",
		Description: "The commander (team-wide; its death loses the game). Modes: auto (builder in the opening and while expanding, defender when enemies are near or the team defends, frontline only when the team pushes, the personality is bold and autonomy is full), builder, defender (stays in turret cover at home, D-guns raiders), frontline (follows the army's main body at a distance, D-guns expensive targets). Personality: careful (retreats at 60% health, stays within 1600 of home) or bold (45%, 3200). The current mode is in the team report (commander). Strong players keep it alive above all; bold only when the enemy has no artillery or air near the front.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in commanderArgs) (*mcp.CallToolResult, any, error) {
		return act(ctx, in.SubID, "set_commander", map[string]any{"set": in.Set}, "commander "+in.Set), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "request_help",
		Description: "Ask the team (the plan and open requests are in the team report). defend (x, z): the Army sends its squad there when it's in the base; constructor: the Economy builds you one; production: the Economy's lab builds combat units for the Army. Requests expire after 45 s unless asked again; the rules engine posts its own when an area is outgunned or a known enemy army outweighs ours.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in requestArgs) (*mcp.CallToolResult, any, error) {
		args := map[string]any{"kind": in.Kind, "need": in.Need, "note": in.Note}
		if in.X != nil && in.Z != nil {
			args["x"], args["z"] = *in.X, *in.Z
		}
		return act(ctx, in.SubID, "request_help", args, "asked the team for "+in.Kind), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "set_role",
		Description: "Change what you do. Only when the player's orders call for it or the situation clearly demands it; the player chose your role.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in roleArgs) (*mcp.CallToolResult, any, error) {
		return act(ctx, in.SubID, "set_role", map[string]any{"role": in.Role}, "role set to "+in.Role), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "set_focus",
		Description: "Restrict what you produce to these types (names from get_build_options): mobile units for your FACTORIES (by=factory), and turret types (kind defense turret / anti-air turret, by=constructors) for the defences your constructors build. Other structures can't be focused. Empty list returns to automatic choices for your role.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in focusArgs) (*mcp.CallToolResult, any, error) {
		units := in.Units
		if units == nil {
			units = []string{}
		}
		return act(ctx, in.SubID, "set_focus", map[string]any{"units": units}, fmt.Sprintf("focus set to %v", units)), nil, nil
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "add_zone",
		Description: "Add an area you build and fight in (world coordinates in elmos: x east, z south). Zones are additive; use clear_zones first to move. Without drawn zones you work in automatic zones chosen by role (economy: the base; defense: the base's front and exposed extractors; army: the safe edge toward the enemy); adding a zone switches to yours.",
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
		Description: "Remove your drawn zones and go back to automatic zones by role (or add new ones after this).",
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
		Description: "Send the player a short message (requests, warnings). At most once per 90 s; your one-sentence reply is already shown in your log, so put repeats there instead.",
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
