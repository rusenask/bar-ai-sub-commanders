"""Run a test batch in Lightning AI sandboxes (testenv/sandbox/README.md).

usage: uvx --with lightning-sdk python testenv/sandbox/batch.py <games> [--sandboxes 4] [--instance cpu-8]
       [--parallel 3] [--label name] [--widgets /tmp/arm-x/Widgets] [--scenario duelrules|autopilot]
       [--minutes 60] [--opponent medium] [--map "All That Simmers v1.1.1"] [--side Legion] [--enemy-side Armada]

Each sandbox is restored from a warm snapshot that already has the Linux engine, the game version our
script pins and the maps (the recipe below; the first create bakes it). The widgets and harness are
uploaded, the games split across the sandboxes, and the results collected into testenv/batch/<stamp>-<label>/
like batch.sh (make compare / make report). Sandboxes are always deleted at the end.
"""
import argparse
import base64
import io
import random
import os
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from pathlib import Path

# the SDK's HTTP read timeout (30 s) is shorter than a cold create that bakes the warm recipe inline
os.environ.setdefault("LIGHTNING_CLOUD_READ_TIMEOUT", "1800")

from lightning_sdk.sandbox import RunCommandOpts, Sandbox, WarmRecipe, wait_for_file

ROOT = Path(__file__).resolve().parents[2]
T = ROOT / "testenv"
TEAMSPACE = os.environ.get("BAR_TEAMSPACE", "lightning-ai/agents-teamspace")
ENGINE = "2026.07.04"
GAME = "Beyond All Reason test-31578-8247b61"
MAPS = ["All That Simmers v1.1.1", "Isidis crack 1.1", "Comet Catcher Remake 1.8"]
PRD_ENV = ("PRD_RAPID_USE_STREAMER=false PRD_RAPID_REPO_MASTER=https://repos-cdn.beyondallreason.dev/repos.gz "
           "PRD_HTTP_SEARCH_URL=https://files-cdn.beyondallreason.dev/find")

# The warm recipe: everything that doesn't change between batches. It is the cache key: change it and the
# next create bakes a new snapshot. BAR's rapid streamer answers 'error' to Linux pr-downloader; without
# it (PRD_RAPID_USE_STREAMER=false) a game version comes down file by file in ~20 s.
RECIPE = WarmRecipe(
    run_cmd=[
        "export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get install -y -qq p7zip-full iproute2 >/dev/null",
        f"mkdir -p /opt/bar/engine /opt/bar/data && cd /opt/bar && curl -sSLo recoil.7z https://github.com/beyond-all-reason/RecoilEngine/releases/download/{ENGINE}/recoil_{ENGINE}_amd64-linux.7z && 7z x -y -oengine recoil.7z >/dev/null && rm recoil.7z",
        f"cd /opt/bar && {PRD_ENV} engine/pr-downloader --filesystem-writepath data --download-game '{GAME}' >/dev/null",
        # a map the search doesn't know mustn't fail the bake (a failed recipe step fails the create)
        *[f"cd /opt/bar && {PRD_ENV} engine/pr-downloader --filesystem-writepath data --download-map '{m}' >/dev/null 2>&1 || true" for m in MAPS],
        "touch /opt/bar/ready",
    ],
    ready_cmd=wait_for_file("/opt/bar/ready"),
    ready_timeout_ms=20 * 60 * 1000,
)


def key():
    return os.environ.get("LIGHTNING_SANDBOX_API_KEY") or open(os.path.expanduser("~/.config/bar-sim/lightning-key")).read().strip()


def sh(sb, script, timeout=3 * 3600):
    r = sb.run_command(RunCommandOpts(cmd="bash", args=["-lc", script], detached=True))
    r.wait(timeout=timeout)
    return r.exit_code, r.output or ""


def put_bytes(sb, data, remote):
    b64 = base64.b64encode(data).decode()
    sh(sb, f"mkdir -p $(dirname {remote}) && : > {remote}.b64")
    for i in range(0, len(b64), 400000):
        sb.write_file(f"{remote}.part", b64[i:i + 400000])
        sh(sb, f"cat {remote}.part >> {remote}.b64")
    sh(sb, f"base64 -d {remote}.b64 > {remote} && rm -f {remote}.b64 {remote}.part")


def get_bytes(sb, remote):
    code, out = sh(sb, f"base64 -w0 {remote}")
    return base64.b64decode(out.strip()) if code == 0 else b""


def stage(args):
    """The write dir every game starts from, as a tar.gz."""
    d = Path(tempfile.mkdtemp())
    w, inc = d / "LuaUI/Widgets", d / "LuaUI/Include"
    w.mkdir(parents=True)
    inc.mkdir(parents=True)
    src = Path(args.widgets) if args.widgets else ROOT / "widget/LuaUI/Widgets"
    for f in src.glob("gui_subcommanders*.lua"):
        text = f.read_text()
        if args.scenario == "autopilot" and f.name == "gui_subcommanders_autopilot.lua":
            text = text.replace("enabled = false,", "enabled = true,")
        (w / f.name).write_text(text)
    incsrc = src.parent / "Include" if (src.parent / "Include").exists() else ROOT / "widget/LuaUI/Include"
    for f in incsrc.glob("sc_*.lua"):
        (inc / f.name).write_text(f.read_text())
    # no rendering: the game may run as fast as the CPU allows
    (w / "zz_sctest.lua").write_text((T / "LuaUI/Widgets/zz_sctest.lua").read_text().replace("setmaxspeed 20", "setmaxspeed 1000"))
    (d / "springsettings.cfg").write_text((T / "springsettings.template.cfg").read_text())
    script = (T / "script_vsai.txt").read_text()
    import re
    script = re.sub(r"profile=[a-z_]*;", f"profile={args.opponent};", script)
    script = re.sub(r"mapname=[^;]*;", f"mapname={args.map};", script)
    # sides: team0 is ours, team1 BARbarian's
    parts = script.split("[team1]")
    parts[0] = re.sub(r"side=[A-Za-z]+;", f"side={args.side};", parts[0])
    parts[1] = re.sub(r"side=[A-Za-z]+;", f"side={args.enemy_side};", parts[1], count=1)
    (d / "script.txt").write_text("[team1]".join(parts))
    (d / "sctest_minutes.txt").write_text(f"{args.minutes}\n")
    (d / "sctest_scenario.txt").write_text(f"{args.scenario}\n")
    (d / "sctest_speed.txt").write_text("100 0\n")
    # BAR from test-31614 lets widgets read only under LuaUI/: the inputs there too
    (d / "LuaUI/Config").mkdir(parents=True, exist_ok=True)
    for name in ("sctest_minutes.txt", "sctest_scenario.txt", "sctest_speed.txt"):
        (d / "LuaUI/Config" / name).write_text((d / name).read_text())
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        tar.add(d, arcname=".")
    return buf.getvalue()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("games", type=int)
    ap.add_argument("--sandboxes", type=int, default=4)
    ap.add_argument("--instance", default="cpu-8")
    ap.add_argument("--parallel", type=int, default=3, help="games at a time per sandbox (about cores / 3)")
    ap.add_argument("--label", default="sandbox")
    ap.add_argument("--widgets", default=os.environ.get("WIDGET_SRC"))
    ap.add_argument("--scenario", default="duelrules")
    ap.add_argument("--minutes", type=int, default=60)
    ap.add_argument("--opponent", default="medium")
    ap.add_argument("--map", default="All That Simmers v1.1.1")
    ap.add_argument("--side", default="Legion")
    ap.add_argument("--enemy-side", default="Armada")
    ap.add_argument("--learn", default="", help="a learning key (internal/learn): each game plays a sampled rule set, "
                    "each generation updates learn/<key>.json")
    ap.add_argument("--generations", type=int, default=1, help="with --learn: generations to run on the same sandboxes")
    args = ap.parse_args()
    Sandbox.configure(api_key=key())
    commit = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    tgz = stage(args)
    runner = (T / "sandbox/run_games.sh").read_bytes()
    limit = args.minutes * 60 // 2 + 300
    # the pool is shared with the teamspace (others' jobs fail with 503 when it's full): all our bar-*
    # sandboxes together stay under BAR_MAX_SANDBOXES (default 12); a run that would pass it gets fewer
    cap = int(os.environ.get("BAR_MAX_SANDBOXES", "12"))
    try:
        running = sum(1 for sb in Sandbox().list(teamspace=TEAMSPACE).sandboxes
                      if (sb.name or "").startswith("bar-") and str(sb.status).lower() == "running")
    except Exception:
        running = 0
    allowed = max(1, cap - running)
    if args.sandboxes > allowed:
        print(f"{running} of our sandboxes already run (cap {cap}): using {allowed} instead of {args.sandboxes}", flush=True)
        args.sandboxes = allowed
    n = min(args.sandboxes, args.games)
    per = [(args.games * k // n + 1, args.games * (k + 1) // n) for k in range(n)]
    gens = args.generations if args.learn else 1
    boxes, errors = [None] * n, []
    par = [args.parallel] * n  # games at a time per sandbox (lower on a fallback instance)

    def create(k, first, last):
        """The shared pool runs out ("503 no sandbox capacity available; retry shortly", or a bare 500):
        retry with backoff for ~20 minutes, from the fourth try alternating with the next smaller
        instance (half the games at a time)."""
        smaller = {"cpu-16": "cpu-8", "cpu-8": "cpu-4"}.get(args.instance)
        delay, last_err = 15, None
        for attempt in range(12):
            inst = args.instance if attempt < 3 or not smaller or attempt % 2 == 0 else smaller
            p = args.parallel if inst == args.instance else max(1, args.parallel // 2)
            try:
                sb = Sandbox.create(name=f"bar-{args.label}-{k}", teamspace=TEAMSPACE, instance_type=inst, runtime="python313",
                                    warm=RECIPE, timeout=gens * (limit * ((last - first) // p + 2) + 1800) * 1000)
                par[k] = p
                if inst != args.instance:
                    print(f"sandbox {k}: {inst} (no {args.instance} capacity), {p} games at a time", flush=True)
                return sb
            except Exception as e:
                last_err = e
                time.sleep(delay + random.random() * 10)
                delay = min(delay * 2, 180)
        raise RuntimeError(f"no capacity after retries: {last_err}")

    def setup(k):
        first, last = per[k]
        try:
            sb = create(k, first, last)
            boxes[k] = sb
            warm = getattr(sb, "warm", None)
            print(f"sandbox {k}: games {first}-{last}, warm={getattr(warm, 'state', '?')} {getattr(warm, 'reason', '')}", flush=True)
            code, _ = sh(sb, "test -f /opt/bar/ready")
            if code != 0:
                raise RuntimeError("not set up (/opt/bar/ready missing)")
            put_bytes(sb, tgz, "/opt/bar/stage.tgz")
            put_bytes(sb, runner, "/opt/bar/run_games.sh")
            sh(sb, "rm -rf /opt/bar/stage && mkdir -p /opt/bar/stage && tar xzf /opt/bar/stage.tgz -C /opt/bar/stage")
        except Exception as e:
            errors.append(f"sandbox {k} setup: {e}")
            print(f"sandbox {k} setup failed: {e}", flush=True)
            if boxes[k] is not None:
                try:
                    boxes[k].delete()
                except Exception:
                    pass
                boxes[k] = None

    def parallel(fn, *a):
        threads = [threading.Thread(target=fn, args=(k, *a)) for k in range(n)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

    try:
        parallel(setup)
        up = sum(1 for b in boxes if b is not None)
        print(f"{up}/{n} sandboxes up", flush=True)
        if up == 0:
            sys.exit("no sandbox came up: " + "; ".join(errors[:3]))
        for gen in range(gens):
            stamp = time.strftime("%Y%m%d-%H%M")
            label = args.label if gens == 1 else f"{args.label}-g{gen + 1}"
            out = T / "batch" / f"{stamp}-{label}"
            (out / "remote").mkdir(parents=True)
            (out / "meta.txt").write_text(
                f"label: {label}\ncommit: {commit}\nwidgets: {args.widgets or 'working tree'}\n"
                f"scenario: {args.scenario}  script: script_vsai.txt  opponent: {args.opponent}  map: {args.map}  speed: 100  lockstep: 0  "
                f"minutes: {args.minutes}  workers: {n}x{args.parallel} ({args.instance} sandboxes)  side: {args.side} vs {args.enemy_side}\n"
                + (f"learn: {args.learn}\n" if args.learn else "") + f"started: {time.strftime('%Y-%m-%d %H:%M')}\n")
            overlays = None
            if args.learn:
                overlays = out / "overlays"
                subprocess.run(["go", "run", "./cmd/learn", "sample", "-key", args.learn, "-n", str(args.games), "-out", str(overlays)],
                               cwd=ROOT, check=True)
                buf = io.BytesIO()
                with tarfile.open(fileobj=buf, mode="w:gz") as tar:
                    tar.add(overlays, arcname=".")
                otgz = buf.getvalue()
            start = time.time()
            gen_errors = []

            def play(k):
                sb, (first, last) = boxes[k], per[k]
                if sb is None:
                    return
                try:
                    if overlays is not None:
                        put_bytes(sb, otgz, "/opt/bar/overlays.tgz")
                        sh(sb, "rm -rf /opt/bar/overlays && mkdir -p /opt/bar/overlays && tar xzf /opt/bar/overlays.tgz -C /opt/bar/overlays")
                    else:
                        sh(sb, "rm -rf /opt/bar/overlays")
                    code, log = sh(sb, f"rm -rf /opt/bar/games /opt/bar/results.tgz; bash /opt/bar/run_games.sh {first} {last} {par[k]} {limit}")
                    print(f"sandbox {k}: {log.strip()[-200:]}", flush=True)
                    data = get_bytes(sb, "/opt/bar/results.tgz")
                    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
                        tar.extractall(out / "remote", filter="data")
                except Exception as e:  # this sandbox's games count as not run
                    gen_errors.append(f"sandbox {k}: {e}")
                    print(f"sandbox {k} failed: {e}", flush=True)

            parallel(play)
            if errors or gen_errors:
                with open(out / "meta.txt", "a") as f:
                    f.write("".join(f"error: {e}\n" for e in errors + gen_errors))
            subprocess.run(["bash", str(T / "collect-results.sh"), str(out), str(args.games), str(int(start)), args.scenario,
                            args.opponent, args.map, str(args.minutes)])
            if args.learn:
                subprocess.run(["go", "run", "./cmd/learn", "update", "-key", args.learn, "-batch", str(out), "-samples", str(overlays),
                                "-minutes", str(args.minutes)], cwd=ROOT)
    finally:
        for sb in boxes:
            if sb is not None:
                try:
                    sb.delete()
                except Exception as e:
                    print(f"delete failed: {e}", flush=True)


if __name__ == "__main__":
    main()
