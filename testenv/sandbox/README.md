# Test games and replays in Lightning AI sandboxes

Sandboxes are cloud VMs (cpu-4 / cpu-8 / cpu-16) in the `lightning-ai/agents-teamspace` teamspace. A warm
recipe (in `batch.py`: apt tools, the Linux engine, the game version our script pins, maps) is baked once
into a snapshot; later sandboxes restore from it and only get the widgets, the harness and the job.

```sh
# 12 games, 3 cpu-16 sandboxes x 4 games at a time; results in testenv/batch/<stamp>-<label>/ as usual
WIDGET_SRC=$(testenv/arm.sh v24) uvx --with lightning-sdk python testenv/sandbox/batch.py 12 \
  --sandboxes 3 --instance cpu-16 --parallel 4 --label sbx-v24 [--side Cortex --enemy-side Armada]
uvx --with lightning-sdk python testenv/sandbox/sbx.py run <id> 'ls /opt/bar'   # poke at one
```

- Key: an org-scoped API key in `~/.config/bar-sim/lightning-key` (or `LIGHTNING_SANDBOX_API_KEY`); a
  personal login can't create sandboxes. `uvx lightning-sdk api-key create --org lightning-ai --json`
  prints `raw_key` once: save it before anything else.
- The SDK's HTTP read timeout is 30 s; a cold create bakes the recipe inline, so the scripts set
  `LIGHTNING_CLOUD_READ_TIMEOUT=1800`. Commands run detached and are polled (games take minutes).
- A failing recipe step fails the create with a bare `500 failed to create sandbox`: test steps in a plain
  sandbox first (a map name the search doesn't know did it once).
- BAR's rapid streamer refuses Linux pr-downloader; `PRD_RAPID_USE_STREAMER=false` downloads a game
  version file by file in ~20 s (also on force).
- Sandboxes are deleted at the end of every batch, and have a create-time timeout as a safety net.
- `--side` / `--enemy-side` pick the factions (team 0 is ours): the harness's scripted player takes its
  units from our commander's prefix (leg / arm / cor).
- The pool is shared with the teamspace: creation can fail with `503 no sandbox capacity available` (or
  a bare 500). batch.py retries with backoff for ~20 minutes, alternating with the next smaller instance
  (half the games at a time), and stops if none comes up. 36 cpu-16 at once was refused; 9 worked.
- Throughput varies with the shared pool: on a quiet afternoon a cpu-16 ran 4 games of 60 minutes in ~13
  minutes (4.6x each); during a capacity crunch the same ran at ~1x (a pure-Python loop 2x slower, games
  CPU-bound). force measured 15x for two games at once at the same time. Check the game minute vs wall
  time early (`sbx.py run <id> 'tail -1 /opt/bar/games/g*/sctest_out.txt'`) before planning on a run.
- Be a good neighbour: other teams' jobs fail with 503 when the pool is full. All our `bar-*` sandboxes
  together stay under `BAR_MAX_SANDBOXES` (default 12; batch.py shrinks a run to fit). Prefer fewer
  sandboxes for longer: the cost is the same.
- The pool's production host is shared (one 192-core host at times): 12 cpu-16 sandboxes created and
  loaded together filled it, and everyone else's creates were turned away ("host under pressure",
  shown to them as 503 no capacity). batch.py staggers: sandbox k is created, and starts its games,
  k x `--stagger` seconds after the first (default 45, `BAR_SBX_STAGGER`), so a 12-sandbox run ramps up
  over ~8 minutes.
- A batch stopped by a signal (`pkill`) leaves its sandboxes running: `sbx.py list`, then
  `sbx.py clean bar-<label>`.
- A sandbox that fails (its host went down: "sandbox unreachable ... connection refused"; setup failed)
  is replaced and its games re-run, up to `--retries` (2) times. Games that still didn't run can be
  filled in later: `batch.py 48 --only 17-32 --into testenv/batch/<dir> --widgets ... --widgets-b ...`
  (same arms; on pair boundaries for an A/B); the batch's report and arms are rebuilt.
