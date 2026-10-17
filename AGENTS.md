# Working on this repo

## Before you start

- Read [docs/research/lessons.md](docs/research/lessons.md): causes found, fixes that failed, process traps.
- Know what the game offers: [docs/research/units.md](docs/research/units.md) is every unit of every
  faction with its abilities (cloak, EMP, shields, anti-nuke, resurrection, mines, drones...) from the game's
  own data, and which ones we use (`testenv/unit-catalogue.sh` + `scripts/unit_catalogue.py` after a BAR
  update).
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

- **Check for failures first, and understand each one before using the results.** Games that "did not
  run", replays with "no data", `WIDGET CRASHED`, sandboxes that failed, a batch with fewer games than
  asked: read the kept log (`failed/`, `remote/g<i>/run.log`, `~/bar-sim/replay-failed/` on force),
  name the cause, fix it or write down why it's harmless. A silent failure is usually a skewed sample
  (17 "failed" team replays were every game of one new BAR version: the small-team data was missing).

- Results (arm tables from `make compare`) go into `docs/research/test-games.md`, durable lessons into
  `docs/research/lessons.md`, also for ideas that failed.
- If something about the process slowed you down or nearly went wrong, fix it where it lives (a skill, a
  script, a make target, `internal/analysis`, this file) in the same commit. Keep skills short and true.

## Testing without disturbing a running game

- Batches run on the `force` host by default now (`testenv/force-batch.sh`, headless, 6 games at a time at
  up to 100x: [testenv/force/README.md](testenv/force/README.md)); the laptop stays free. Local batches
  (`testenv/batch.sh`) are for watching games; when the laptop has to run a batch, `FAST=1 WORKERS=6
  SPEED=100` is ~5x the old default ([docs/research/speed.md](docs/research/speed.md)).

- Micro (targeting, focus fire, kiting, movement, retreats) is measured in the **battle lab**: one
  engagement in isolation, ~16 s each (`SCENARIO=battle testenv/force-batch.sh 72 battle`, specs in
  [testenv/battles](testenv/battles/README.md), `gamereport -battles`). Whole games are for economy,
  macro and anything that depends on the game's course.
- Test games connect to a separate test bridge on port 17878 (`make test-bridge`), not the Docker bridge on
  7878 that a real game uses. To exercise the bridge without BAR, use `bin/fakegame -addr 127.0.0.1:<port>`
  against a separate bridge container.
- One batch at a time: a batch runs its games in parallel on separate write dirs (`testenv/workers/<n>`,
  `WORKERS`, default 1 so the machine stays usable; strategist batches always use one). Single test games,
  `testenv/collect.sh` and `testenv/replays.sh` use `testenv/` itself. Check with
  `pgrep -fl "[b]atch.sh|[r]eplays.sh|[c]ollect.sh"` first, and don't edit `testenv/run.sh`,
  `batch.sh` or the harness while a batch runs.
- `MAPVIEW_OUT=/tmp/x go test ./internal/mapview` writes sample map pictures to look at.
- `testenv/*` is git-ignored: a new script there needs a `!testenv/<name>` line in `.gitignore`, or the
  commit silently leaves it out (force-ab.sh was missing from its own commit). Check `git show --stat`.
- `force` is on the personal tailnet; with Tailscale on another tailnet it doesn't resolve and batches
  stop (`testenv/force-ab.sh` checks first). Don't switch tailnets without asking.
