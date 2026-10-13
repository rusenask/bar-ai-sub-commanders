# Working on this repo

## Before you start

- Read [docs/research/lessons.md](docs/research/lessons.md): causes found, fixes that failed, process traps.
- Skills for the recurring work are in `.claude/skills/`: `improve` (the improvement loop), `analyze-games`
  (`make report`, reading the logs), `ab-test` (measuring a change), `pro-replays` (strong players' games),
  `decision-models` (training and serving our models).

## After every change

1. Check it: `make lint` (luac + go vet), `go test ./...`, `make build`.
2. Commit and push to `main` (`git push origin main`). Don't leave finished work uncommitted.
3. Bring the running setup up to date, depending on what changed:

| Changed | Run |
|---|---|
| `cmd/`, `internal/`, `go.mod`, `Dockerfile`, `docker/` | `make up` (rebuilds and restarts the bridge container) |
| `strategist/` (prompt, agent config) only | `make restart` |
| `widget/LuaUI/Widgets/*.lua`, `widget/LuaUI/Include/*.lua` | `make install`, then `/luaui reload` in game |

Restarting the bridge drops the strategist's sessions (each sub-commander starts a fresh conversation) and the
widget reconnects by itself within a few seconds. Sub-commanders survive `/luaui reload`.

## After every experiment

- Results (arm tables from `make compare`) go into `docs/research/test-games.md`, durable lessons into
  `docs/research/lessons.md`, also for ideas that failed.
- If something about the process slowed you down or nearly went wrong, fix it where it lives (a skill, a
  script, a make target, `internal/analysis`, this file) in the same commit. Keep skills short and true.

## Testing without disturbing a running game

- Test games connect to a separate test bridge on port 17878 (`make test-bridge`), not the Docker bridge on
  7878 that a real game uses. To exercise the bridge without BAR, use `bin/fakegame -addr 127.0.0.1:<port>`
  against a separate bridge container.
- One batch at a time: a batch runs its games in parallel on separate write dirs (`testenv/workers/<n>`,
  `WORKERS`, default 3; strategist batches use one, the test bridge serves one game). Single test games,
  `testenv/collect.sh` and `testenv/replays.sh` use `testenv/` itself. Check with
  `pgrep -fl "[b]atch.sh|[r]eplays.sh|[c]ollect.sh"` first, and don't edit `testenv/run.sh`,
  `batch.sh` or the harness while a batch runs.
- `MAPVIEW_OUT=/tmp/x go test ./internal/mapview` writes sample map pictures to look at.
