#!/usr/bin/env python3
"""Log a test batch to Lightning's experiment tracker (litlogger, teamspace lightning-ai/agents-teamspace):
one experiment per batch (an A/B: its two arms), with what was tested (commit, sides, opponent, map, the
doctrine difference between the arms), each arm's results, every verdict with its 95% interval, each
feature on its own (spent, killed, lost, return), and the reports, the comparison and any LLM reviews as
files. The history of experiments then lives in one place, comparable across versions.

usage: uv run --quiet --with litlogger python scripts/track.py <batch dir> [--name NAME] [--step N]
  <batch dir>: the interleaved batch (its <dir>-A / <dir>-B arms are found) or a single batch
  --step: for sequential tests, the round (verdicts are logged as a series over rounds)
Credentials: `lightning login` (~/.lightning/credentials.json). BAR_TRACK=0 in batch scripts skips it.
"""
import argparse
import difflib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEAMSPACE = os.environ.get("BAR_TEAMSPACE", "lightning-ai/agents-teamspace")


def meta(d):
    out = {}
    f = Path(d) / "meta.txt"
    if f.exists():
        for line in f.read_text().splitlines():
            k, _, v = line.partition(":")
            if v and k.strip() in ("label", "commit", "widgets", "scenario", "minutes", "side", "opponent", "map", "started"):
                out.setdefault(k.strip(), v.strip())
        # "scenario: duelrules  script: ...  opponent: medium  map: All That Simmers ..." on one line
        txt = f.read_text()
        for k in ("opponent", "map", "side"):
            m = re.search(rf"\b{k}: (.+?)(?:  |\n|$)", txt)
            if m:
                out[k] = m.group(1).strip()
    return out


def doctrine_diff(wa, wb):
    """The doctrine (and any Include file) difference between two arms' widget dirs."""
    if not wa or not wb:
        return ""
    a, b = Path(wa).parent / "Include", Path(wb).parent / "Include"
    if not a.is_dir() or not b.is_dir():
        return ""
    out = []
    for fa in sorted(a.glob("*.lua")):
        fb = b / fa.name
        if fb.exists():
            d = list(difflib.unified_diff(fa.read_text().splitlines(), fb.read_text().splitlines(), f"A/{fa.name}", f"B/{fa.name}", n=0, lineterm=""))
            out += d
    return "\n".join(out)


def key(s):
    return re.sub(r"[^A-Za-z0-9_/.-]+", "_", s).strip("_")[:120]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("batch")
    ap.add_argument("--name", default="")
    ap.add_argument("--step", type=int, default=0)
    args = ap.parse_args()
    batch = Path(args.batch).resolve()
    arms = [p for p in (Path(str(batch) + "-A"), Path(str(batch) + "-B")) if p.is_dir()] or [batch]
    gr = [str(ROOT / "bin/gamereport")] if (ROOT / "bin/gamereport").exists() else ["go", "run", "./cmd/gamereport"]
    data = json.loads(subprocess.run(gr + ["-json", "-compare"] + [str(a) for a in arms], cwd=ROOT, capture_output=True, text=True, check=True).stdout)
    compare_md = subprocess.run(gr + ["-compare"] + [str(a) for a in arms], cwd=ROOT, capture_output=True, text=True).stdout

    import litlogger

    m = meta(batch)
    wa = meta(arms[0]).get("widgets") if len(arms) > 1 else m.get("widgets")
    wb = meta(arms[1]).get("widgets") if len(arms) > 1 else ""
    diff = doctrine_diff(wa, wb)
    md = {k: v[:200] for k, v in m.items()}
    md.update({"batch": batch.name, "arms": ", ".join(a.name for a in arms), "widgets_A": (wa or "")[:200], "widgets_B": (wb or "")[:200],
               "doctrine_diff": " | ".join(l for l in diff.splitlines() if l[:1] in "+-" and not l.startswith(("+++", "---")))[:500]})
    name = args.name or "bar-" + re.sub(r"^\d{8}-\d{4}-", "", batch.name)
    exp = litlogger.init(name=name, teamspace=TEAMSPACE, metadata=md, print_url=False, verbose=False)

    metrics = {}
    for i, a in enumerate(arms):
        tag = "AB"[i] if len(arms) > 1 else "arm"
        r = data.get(a.name, {})
        av = r.get("averages", {})
        games = r.get("games", [])
        metrics[f"{tag}/games"] = len(games)
        metrics[f"{tag}/wins"] = sum(1 for g in games if g.get("result") == "WIN")
        for k in ("lossRate", "metal", "killed", "lost", "constructorsLost", "dealtTaken"):
            if k in av:
                metrics[f"{tag}/{k}"] = float(av[k])
        for f in r.get("features") or []:
            for k in ("spent", "killed", "lost", "count"):
                metrics[f"{tag}/feature/{f['name']}/{k}"] = float(f.get(k) or 0)
            if f.get("spent"):
                metrics[f"{tag}/feature/{f['name']}/return"] = float(f.get("killed") or 0) / float(f["spent"])
    for arm, vs in (data.get("verdicts") or {}).items():
        for v in vs:
            k = key(re.sub(r"\(.*?\)", "", v["metric"]).strip())
            metrics[f"verdict/{k}/diff"] = float(v["arm"] - v["base"])
            metrics[f"verdict/{k}/lo"] = float(v["lo"])
            metrics[f"verdict/{k}/hi"] = float(v["hi"])
            metrics[f"verdict/{k}/decided"] = {"better": 1.0, "worse": -1.0}.get(v["verdict"], 0.0)
    for k, v in metrics.items():
        exp[k].append(float(v), step=args.step)

    tmp = Path("/tmp") / f"track-{batch.name}"
    tmp.mkdir(exist_ok=True)
    (tmp / "compare.md").write_text(compare_md)
    files = [tmp / "compare.md"]
    if diff:
        (tmp / "doctrine.diff").write_text(diff)
        files.append(tmp / "doctrine.diff")
    for d in [batch] + arms:
        for f in [d / "report.md", d / "meta.txt"] + sorted(d.glob("llm-*.md")):
            if f.exists():
                files.append(f)
    for f in files:
        rel = f.name if f.parent == tmp else f"{f.parent.name}/{f.name}"
        exp[key("file/" + rel)] = litlogger.File(str(f))
    exp.finalize("completed", print_summary=False)
    print(f"tracked: {exp.url}")


if __name__ == "__main__":
    sys.exit(main())
