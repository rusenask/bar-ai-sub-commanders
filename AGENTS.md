# Working on this repo

## After every change

1. Check it: `make lint` (luac + go vet), `go test ./...`, `make build`.
2. Commit and push to `main` (`git push origin main`). Don't leave finished work uncommitted.
3. Bring the running setup up to date, depending on what changed:

| Changed | Run |
|---|---|
| `cmd/`, `internal/`, `go.mod`, `Dockerfile`, `docker/` | `make up` (rebuilds and restarts the bridge container) |
| `strategist/` (prompt, agent config) only | `make restart` |
| `widget/LuaUI/Widgets/*.lua` | `make install`, then `/luaui reload` in game |

Restarting the bridge drops the strategist's sessions (each sub-commander starts a fresh conversation) and the
widget reconnects by itself within a few seconds. Sub-commanders survive `/luaui reload`.

## Testing without disturbing a running game

- `make test-game SCENARIO=...` and the Docker bridge both use port 7878, and a new game connection replaces
  the old one. If a game is running, test the bridge in a separate container on other ports with
  `bin/fakegame -addr 127.0.0.1:<port>` instead.
- `MAPVIEW_OUT=/tmp/x go test ./internal/mapview` writes sample map pictures to look at.
