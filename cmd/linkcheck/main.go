// Command linkcheck is the bridge's game link without the strategist: it serves the widget over TCP and
// the file transport, sends a test "learned" rule set, and prints what arrives. For checking the AI
// widget's link in a real (headless) game.
//
//	linkcheck -addr 127.0.0.1:17890 -files /path/to/LuaUI/Config/scbridge -for 120s
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/rusenask/bar-ai-sub-commanders/internal/game"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:17890", "TCP address")
	files := flag.String("files", "", "file transport directory (optional)")
	dur := flag.Duration("for", 2*time.Minute, "how long to listen")
	flag.Parse()
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	s := game.NewServer(*addr, log)
	s.OnHello = func(info *game.Info) map[string]any {
		fmt.Printf("HELLO map=%s faction=%s enemies=%v ais=%v\n", info.Map, info.Faction, info.Enemies, info.AIs)
		return map[string]any{"key": "linkcheck", "generation": 1, "rules": map[string]any{"engage_attack": 1.33}}
	}
	s.OnGameOver = func(info *game.Info, summary map[string]any) { fmt.Printf("GAMEOVER %v\n", summary) }
	ctx, cancel := context.WithTimeout(context.Background(), *dur)
	defer cancel()
	go s.Run(ctx)
	if *files != "" {
		fl, err := game.ListenFiles(*files)
		if err != nil {
			fmt.Println("files:", err)
			os.Exit(1)
		}
		go s.Serve(ctx, fl)
	}
	states := 0
	for ctx.Err() == nil {
		time.Sleep(5 * time.Second)
		if _, st, online := s.Snapshot(); st != nil {
			states++
			fmt.Printf("STATE online=%v frame=%d subs=%d\n", online, st.Frame, len(st.Subs))
		}
	}
	fmt.Println("states seen:", states)
}
