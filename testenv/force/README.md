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
games' raw output is in `remote/`. Widget errors are flagged the same way (`WIDGET CRASHED`).

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
