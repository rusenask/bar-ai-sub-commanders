#!/usr/bin/env python3
"""Summarise the widgets' Lua errors (make errors).

Reads the bridge's error logs (logs/widget-errors*.jsonl from real games, testenv/records/widget-errors.jsonl
from the test bridge: sc_guard.lua reports each error's 1st, 10th, 100th... time) and BAR's infolog (the
"Sub-Commanders ERROR" lines, and the engine's "Error in ..." lines of an error nothing caught, which
removes the widget). One line per distinct error, most frequent first.

usage: scripts/widget_errors.py [--days N] [--infolog PATH] [jsonl...]
"""

import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

INFOLOG = os.path.expanduser("~/Library/Application Support/Beyond-All-Reason-mac/infolog.txt")
CAUGHT = re.compile(r"Sub-Commanders ERROR \((?P<where>[^,]+), (?P<count>\d+)x\): (?P<msg>.*)")
UNCAUGHT = re.compile(r"Error in (?P<where>\w+)\(\): (?P<msg>.*(gui_subcommanders|sc_[a-z]+\.lua).*)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=float, default=7, help="only errors from the last N days (bridge logs)")
    ap.add_argument("--infolog", default=INFOLOG, help="BAR's infolog (the current or last game)")
    ap.add_argument("logs", nargs="*")
    a = ap.parse_args()
    paths = a.logs or sorted(glob.glob("logs/widget-errors*.jsonl")) + glob.glob("testenv/records/widget-errors.jsonl")
    since = datetime.now(timezone.utc) - timedelta(days=a.days)

    errors = {}  # (where, message) -> summary

    def note(where, msg, count, when, source, tb=None):
        e = errors.setdefault((where, msg), {"count": 0, "reports": 0, "last": "", "sources": set(), "tb": None})
        e["count"] = max(e["count"], count)
        e["reports"] += 1
        e["last"] = max(e["last"], when)
        e["sources"].add(source)
        e["tb"] = e["tb"] or tb

    for p in paths:
        if not os.path.exists(p):
            continue
        name = os.path.basename(p)
        with open(p) as f:
            for line in f:
                try:
                    e = json.loads(line)
                    t = datetime.fromisoformat(e["time"].replace("Z", "+00:00"))
                except (ValueError, KeyError):
                    continue
                if t < since:
                    continue
                src = f"{name}: {e.get('faction', '?')} on {e.get('map', '?')}"
                note(e.get("where", "?"), e.get("message", "?"), e.get("count", 1), t.strftime("%Y-%m-%d %H:%M"), src, e.get("traceback"))

    if os.path.exists(a.infolog):
        stamp = datetime.fromtimestamp(os.path.getmtime(a.infolog)).strftime("%Y-%m-%d %H:%M")
        with open(a.infolog, errors="replace") as f:
            for line in f:
                m = CAUGHT.search(line)
                if m:
                    note(m["where"], m["msg"].strip(), int(m["count"]), stamp, "infolog")
                    continue
                m = UNCAUGHT.search(line)
                if m:
                    note(m["where"] + " (UNCAUGHT: widget removed)", m["msg"].strip(), 1, stamp, "infolog")

    if not errors:
        print(f"no widget errors (read {', '.join(paths) or 'no bridge logs'}, {a.infolog})")
        return 0
    print(f"{len(errors)} distinct widget errors (count = most repeats in one game; the widget reports the 1st, 10th, 100th...)\n")
    for (where, msg), e in sorted(errors.items(), key=lambda kv: (-kv[1]["count"], kv[1]["last"])):
        print(f"{e['count']:>6}x  {where}: {msg}")
        print(f"         last {e['last']}, {e['reports']} reports from {'; '.join(sorted(e['sources']))}")
        if e["tb"]:
            frames = [l.strip() for l in e["tb"].splitlines()[1:] if "sc_guard.lua" not in l][:4]
            for fr in frames:
                print(f"           {fr}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
