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
    args = ap.parse_args()
    Sandbox.configure(api_key=key())
    stamp = time.strftime("%Y%m%d-%H%M")
    out = T / "batch" / f"{stamp}-{args.label}"
    (out / "remote").mkdir(parents=True)
    commit = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    (out / "meta.txt").write_text(
        f"label: {args.label}\ncommit: {commit}\nwidgets: {args.widgets or 'working tree'}\n"
        f"scenario: {args.scenario}  script: script_vsai.txt  opponent: {args.opponent}  map: {args.map}  speed: 100  lockstep: 0  "
        f"minutes: {args.minutes}  workers: {args.sandboxes}x{args.parallel} ({args.instance} sandboxes)  side: {args.side} vs {args.enemy_side}\n"
        f"started: {time.strftime('%Y-%m-%d %H:%M')}\n")
    tgz = stage(args)
    runner = (T / "sandbox/run_games.sh").read_bytes()
    limit = args.minutes * 60 // 2 + 300
    n = min(args.sandboxes, args.games)
    per = [(args.games * k // n + 1, args.games * (k + 1) // n) for k in range(n)]
    start = time.time()
    boxes, errors = [None] * n, []

    def work(k):
        first, last = per[k]
        try:
            sb = Sandbox.create(name=f"bar-{args.label}-{k}", teamspace=TEAMSPACE, instance_type=args.instance,
                                runtime="python313", warm=RECIPE, timeout=(limit * ((last - first) // args.parallel + 2) + 1800) * 1000)
            boxes[k] = sb
            warm = getattr(sb, "warm", None)
            print(f"sandbox {k}: games {first}-{last}, warm={getattr(warm, 'state', '?')} {getattr(warm, 'reason', '')}", flush=True)
            sh(sb, "test -f /opt/bar/ready || exit 1")
            put_bytes(sb, tgz, "/opt/bar/stage.tgz")
            put_bytes(sb, runner, "/opt/bar/run_games.sh")
            sh(sb, "rm -rf /opt/bar/stage && mkdir -p /opt/bar/stage && tar xzf /opt/bar/stage.tgz -C /opt/bar/stage")
            code, log = sh(sb, f"bash /opt/bar/run_games.sh {first} {last} {args.parallel} {limit}")
            print(f"sandbox {k}: {log.strip()[-200:]}", flush=True)
            data = get_bytes(sb, "/opt/bar/results.tgz")
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
                tar.extractall(out / "remote", filter="data")
        except Exception as e:  # keep the others going; this sandbox's games count as not run
            errors.append(f"sandbox {k}: {e}")
            print(f"sandbox {k} failed: {e}", flush=True)
        finally:
            if boxes[k] is not None:
                try:
                    boxes[k].delete()
                except Exception as e:
                    print(f"sandbox {k}: delete failed: {e}", flush=True)

    threads = [threading.Thread(target=work, args=(k,)) for k in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if errors:
        with open(out / "meta.txt", "a") as f:
            f.write("".join(f"error: {e}\n" for e in errors))
    subprocess.run(["bash", str(T / "collect-results.sh"), str(out), str(args.games), str(int(start)), args.scenario,
                    args.opponent, args.map, str(args.minutes)])


if __name__ == "__main__":
    main()
