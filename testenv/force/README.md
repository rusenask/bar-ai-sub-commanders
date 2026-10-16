# Test games on the force host (headless, Linux)

`force` (Ubuntu, 12 cores, 60 GB, RTX 4090; also serves the decision models) runs test batches with the
Recoil headless engine: no window, no GPU, up to 100x speed, 6 games at a time. A 10-minute game takes
about 25 s of wall time (12 s of it loading). The laptop stays free.

```sh
WIDGET_SRC=$(testenv/arm.sh v22 <commit>) LABEL=force-v22 testenv/force-batch.sh 16            # duelrules
WIDGET_SRC=$(testenv/arm.sh v22ap <commit>) LABEL=force-v22-ap testenv/force-batch.sh 8 autopilot
# options: PARALLEL=6 SPEED=100 DUEL_MINUTES=60 AI_PROFILE=medium MAP="..." FORCE_HOST=force
```

Results land in `testenv/batch/<stamp>-<label>/` like a local batch (`make compare`, `make report`); the
games' raw output is in `remote/`. A batch dir with only `meta.txt` (the laptop side died: a closed session,
sleep) may have finished on force anyway: `ls ~/bar-sim/batches/<dir>` there, then collect it with
`RESUME=<dir> WIDGET_SRC_B=<same> SIDE=<same> testenv/force-batch.sh <games>` (g93). `BAR_TRACK=0` skips
the Lightning experiment upload. Widget errors are flagged the same way (`WIDGET CRASHED`).

## Setup (done once; redo for a new engine or game version)

`~/bar-sim/` on force:

- `engine/`: the Linux engine of the version BAR uses (`spring --version` in the Mac app):
  `curl -LO https://github.com/beyond-all-reason/RecoilEngine/releases/download/<ver>/recoil_<ver>_amd64-linux.7z`,
  `7z x -oengine recoil_<ver>_amd64-linux.7z` (apt `7zip`). It contains `spring-headless` and BARbarian.
- `data/`: the game version our script pins (`gametype=` in `testenv/script_vsai.txt`) and the maps, copied
  from the Mac install: the version's `.sdp` (look it up by name in `rapid/.../byar/versions.gz`), the pool
  files it lists, `rapid/`, and `maps/<map>.sd7`. A python snippet that lists them is in the git history of
  this file's first commit message; `rsync -a --files-from=list ~/Library/Application\ Support/Beyond-All-Reason-mac/ force:bar-sim/data/`.
- `run_game.sh`: copied by force-batch.sh on every run.

The harness is copied with `setmaxspeed 20` raised to 1000 (nothing renders, so the game runs as fast as
the CPU allows); everything else is the same files as a local batch. The only error in a headless log is
BAR's own picture-in-picture minimap widget (needs shaders), harmless.

## Strong players' replays

```sh
ssh force 'cd bar-sim && BAR_PRD=$HOME/bar-sim/engine/pr-downloader BAR_DATA=$HOME/bar-sim/data \
  BAR_DEMOS=$HOME/bar-sim/demos python3 pro_replays.py --pages 40 --max 150'   # fetch (scp pro_replays.py first)
python3 testenv/force/sync_games.py $(game versions the manifest lists) > /tmp/f.txt  # see below
testenv/force-replays.sh                     # play them all with the logger -> testenv/data/pro/
go run ./cmd/gamereport -micro testenv/data/pro   # per-kind unit behaviour and the D.micro it suggests
```

Maps download on force; game versions don't (the rapid streamer answers force with an HTTP error), so
fetch them on the Mac (`pr-downloader --download-game "<version>"` with the PRD_* variables in
pro_replays.py) and copy them with `testenv/force/sync_games.py` and rsync. A replay whose game or map is
missing logs "no data (... Dependent archive ...)".
