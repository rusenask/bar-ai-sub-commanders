// Command scbridge connects the BAR Sub-Commanders widget to an LLM strategist
// running in opencode.
//
//	game widget ──tcp json lines──▶ scbridge ──http──▶ opencode serve (agent "subcommander")
//	                                    ▲                       │
//	                                    └──── MCP tools (bar_*) ┘
package main

import (
	"cmp"
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/rusenask/bar-ai-sub-commanders/internal/decider"
	"github.com/rusenask/bar-ai-sub-commanders/internal/game"
	"github.com/rusenask/bar-ai-sub-commanders/internal/opencode"
	"github.com/rusenask/bar-ai-sub-commanders/internal/strategist"
	"github.com/rusenask/bar-ai-sub-commanders/internal/tools"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "scbridge:", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		gameAddr    = flag.String("game-addr", "127.0.0.1:7878", "address the game widget connects to")
		mcpAddr     = flag.String("mcp-addr", "127.0.0.1:7879", "address of the MCP tool server (must match strategist/opencode.json)")
		opencodeURL = flag.String("opencode-url", "", "use an already running `opencode serve` instead of starting one")
		opencodeBin = flag.String("opencode-bin", "opencode", "opencode binary")
		port        = flag.Int("opencode-port", 4517, "port for the opencode server scbridge starts")
		dir         = flag.String("strategist-dir", "strategist", "opencode project directory with the subcommander agent")
		model       = flag.String("model", cmp.Or(os.Getenv("SCBRIDGE_MODEL"), "lightning/deepseek-v4.1-flash"), "provider/model as configured in opencode")
		variant     = flag.String("variant", "", "model variant (reasoning effort), e.g. low")
		agent       = flag.String("agent", "subcommander", "opencode agent")
		interval    = flag.Duration("interval", 30*time.Second, "game time between routine reviews of one sub-commander")
		urgent      = flag.Duration("urgent", 8*time.Second, "minimum game time between reviews when something happens")
		turnTimeout = flag.Duration("turn-timeout", 3*time.Minute, "limit for one review")
		host        = flag.String("opencode-host", "127.0.0.1", "interface for the opencode server scbridge starts (0.0.0.0 in a container)")
		deciderURL  = flag.String("decider-url", os.Getenv("SCBRIDGE_DECIDER_URL"), "optional System One decision model (Kev, Clef: /v1/systemone) for the widget's fast choices, e.g. http://100.108.100.25:8009")
		deciderName = flag.String("decider-model", cmp.Or(os.Getenv("SCBRIDGE_DECIDER_MODEL"), "kev-latest"), "model name sent to the decision model")
	)
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	m, err := opencode.ParseModel(*model)
	if err != nil {
		return err
	}
	absDir, err := filepath.Abs(*dir)
	if err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(absDir, "opencode.json")); err != nil {
		return fmt.Errorf("strategist dir %s: %w (run from the repo root or pass -strategist-dir)", absDir, err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	g := game.NewServer(*gameAddr, log)
	if *deciderURL != "" {
		g.Decide = decider.New(*deciderURL, *deciderName).Decide
		log.Info("decision model", "url", *deciderURL, "model", *deciderName)
	}
	var strat *strategist.Strategist
	guard := func(sub int) error {
		if strat == nil {
			return errors.New("strategist not ready")
		}
		return strat.Guard(sub)
	}

	// MCP tools first: opencode connects to them when it starts.
	mux := http.NewServeMux()
	mux.Handle("/mcp", tools.Handler(g, guard))
	ln, err := net.Listen("tcp", *mcpAddr)
	if err != nil {
		return fmt.Errorf("mcp listen: %w", err)
	}
	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go srv.Serve(ln)
	context.AfterFunc(ctx, func() { srv.Close() })
	log.Info("MCP tools", "url", "http://"+*mcpAddr+"/mcp")

	errc := make(chan error, 1)
	go func() { errc <- g.Run(ctx) }()

	var oc *opencode.Client
	if *opencodeURL != "" {
		oc = &opencode.Client{BaseURL: *opencodeURL, HTTP: &http.Client{Timeout: 5 * time.Minute}}
		if !oc.Healthy(ctx) {
			return fmt.Errorf("opencode at %s is not reachable", *opencodeURL)
		}
	} else {
		oc, err = opencode.Serve(ctx, *opencodeBin, absDir, *host, *port, log)
		if err != nil {
			return err
		}
	}
	log.Info("watch the strategist with: opencode attach " + oc.BaseURL)

	strat = strategist.New(strategist.Config{
		Agent:       *agent,
		Model:       m,
		Variant:     *variant,
		Interval:    *interval,
		Urgent:      *urgent,
		TurnTimeout: *turnTimeout,
	}, g, oc, log)
	log.Info("strategist ready", "model", *model, "interval", *interval)

	go strat.Run(ctx)
	select {
	case <-ctx.Done():
		return nil
	case err := <-errc:
		return err
	}
}
