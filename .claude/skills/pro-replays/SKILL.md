---
name: pro-replays
description: Fetch, play back and mine strong human players' BAR 1v1 replays in this repo - pro_replays.py, replays.sh, the data logger, rebuilding the economy benchmark and building imitation/fight training sets. Use when the task needs data from good players' games.
---

# Strong players' replays

Design and findings: `design/pro-replays.md`.

## Pipeline

```sh
# 1. find and download duels where both players are rated 30+, on our engine, 8+ minutes long
uv run --quiet --with certifi python testenv/pro_replays.py --pages 10 --min-skill 30 --max 25
# 2. play each with the data logger (about 2-4 minutes per game; skips replays already logged)
testenv/replays.sh                       # -> testenv/data/pro/<id>.jsonl
# 3. rebuild the economy benchmark used by gamereport and the strategist's pace line
make benchmarks                          # -> internal/analysis/benchmarks/pro-duel.json (commit it; make up)
# 4. training sets (fight, unit, turret, produce, turretpick)
go run ./cmd/decidedata -in testenv/data/pro -out /tmp/sets-pro
```

- Run in the background and in a session where no test game runs (one game environment at a time).
- `testenv/demos/pro/manifest.json` lists players, ratings, factions, winners, map and game version.
- The API: `https://api.bar-rts.com/replays?page=&limit=100&preset=duel&hasBots=false&endedNormally=true`,
  details at `/replays/<id>`. Only replays on the installed engine (2026.07.04) play back; the game
  version is fetched with BAR's pr-downloader, which needs `PRD_RAPID_REPO_MASTER` and
  `PRD_HTTP_SEARCH_URL` pointing at BAR's CDN (the script sets them).
- macOS system Python lacks CA certificates: always `uv run --with certifi`.

## What the logger records

`fight`, `unit`, `turret` (outcomes), `build` / `turretbuild` (what a factory or constructor started and
the options it had: imitation labels), `eco` (per minute, per team). Both players are logged (full view).

## Failures

`testenv/force-replays.sh` ends with the number of replays that produced no data; each keeps its log in
`~/bar-sim/replay-failed/<id>.log` on force with the exit code (124 = time limit) and the first line that
matters. Group them (by game version, length, team size) and find the cause before using the data.

## Caveats

- Rated duels are almost all Armada and Cortex; Legion is rare.
- Humans micro and scout; our executor doesn't. Their compositions are a reference, their economy pace a
  fair target, their fight outcomes a fair label.
- Maps vary: benchmarks mix maps. Compare within a map when a finding hinges on it.
