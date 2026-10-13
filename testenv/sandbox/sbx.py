"""Small Lightning sandbox helper for this repo (the key: LIGHTNING_SANDBOX_API_KEY or ~/.config/bar-sim/lightning-key).

usage: uvx --with lightning-sdk python testenv/sandbox/sbx.py <command> ...
  run <id> <shell command>          run in bash, print output, exit with its code
  put <id> <local file> <remote>    copy a file in (base64 over run_command; text and binary)
  get <id> <remote> <local>         copy a file out
  delete <id>
"""
import base64
import os
import sys

# the SDK's HTTP read timeout (30 s) is shorter than a cold create that bakes the warm recipe inline
os.environ.setdefault("LIGHTNING_CLOUD_READ_TIMEOUT", "1800")

from lightning_sdk.sandbox import RunCommandOpts, Sandbox

TEAMSPACE = os.environ.get("BAR_TEAMSPACE", "lightning-ai/agents-teamspace")


def configure():
    key = os.environ.get("LIGHTNING_SANDBOX_API_KEY") or open(os.path.expanduser("~/.config/bar-sim/lightning-key")).read().strip()
    Sandbox.configure(api_key=key)


def get(sid):
    return Sandbox().get(sid)


def sh(sb, script, timeout=3600):
    """Run a bash script and wait for it. Detached and polled: a synchronous call times out after 30 s
    of HTTP read, and games run for minutes."""
    r = sb.run_command(RunCommandOpts(cmd="bash", args=["-lc", script], detached=True))
    r.wait(timeout=timeout)
    return r.exit_code, r.output or ""


def main():
    configure()
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "run":
        code, out = sh(get(args[0]), args[1])
        sys.stdout.write(out)
        sys.exit(code or 0)
    elif cmd == "put":
        sb = get(args[0])
        data = base64.b64encode(open(args[1], "rb").read()).decode()
        sh(sb, f"mkdir -p $(dirname {args[2]}) && : > {args[2]}.b64")
        for i in range(0, len(data), 400000):
            sb.write_file(f"{args[2]}.part", data[i:i + 400000])
            sh(sb, f"cat {args[2]}.part >> {args[2]}.b64")
        code, out = sh(sb, f"base64 -d {args[2]}.b64 > {args[2]} && rm -f {args[2]}.b64 {args[2]}.part && ls -la {args[2]}")
        print(out.strip())
    elif cmd == "get":
        sb = get(args[0])
        code, out = sh(sb, f"base64 -w0 {args[1]}")
        open(args[2], "wb").write(base64.b64decode(out.strip()))
    elif cmd == "delete":
        get(args[0]).delete()
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
