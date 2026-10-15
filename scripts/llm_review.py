#!/usr/bin/env python3
"""How one feature worked, game by game, read by a fast LLM (DeepSeek-V4.1-Flash on code.lightning.ai, the
OpenCode "dsv41-flash" provider): each game's events for the feature (deduplicated log lines, kills and
losses tagged with it, the feature ledger, the economy every 5 minutes, the result) go to the model in
parallel; it answers what the feature did, when, what went wrong and what to change; a last call
synthesises the batch. Complements gamereport's feature table (the numbers) with the why.

usage: uv run --quiet --with certifi python scripts/llm_review.py <batch dir> [<batch dir>...] --feature firebase|lrpc|nuke|antinuke|shield|juno|rez
       [--games 24] [--parallel 8] [--model lightning-ai/deepseek-v4.1-flash] [--out file.md]
writes <first batch>/llm-<feature>.md (and llm-<feature>.jsonl: the per-game answers)
"""
import argparse
import concurrent.futures as cf
import glob
import json
import os
import re
import ssl
import sys
import urllib.request

try:  # macOS system Python has no CA certificates: uv run --with certifi
    import certifi
    CTX = ssl.create_default_context(cafile=certifi.where())
except ImportError:
    CTX = None

BASE = os.environ.get("LLM_BASE_URL", "https://code.lightning.ai/v1")
TOKEN_FILE = os.path.expanduser(os.environ.get("LLM_TOKEN_FILE", "~/.config/lightning-glm53/code-worker.token"))

# what each feature is (design/engine.md) and which log lines belong to it
FEATURES = {
    "firebase": ("Forward firebases: Defense grows layered turret groups (light turret, radar, light, heavy, "
                 "anti-air once they fly, heavy, long-range) just past our frontier toward the enemy, only where "
                 "our army covers the site; once one is complete the next goes further out, so the line creeps "
                 "forward; the army rallies behind the furthest; metal spots under a firebase are ours to take.",
                 r"firebase|founding"),
    "lrpc": ("Long-range plasma cannons (Basilica / Basilisk / Olympus, range ~4800): built when their own "
             "cannons are known or with a metal surplus, at a safe site with enough of their structures in "
             "reach; fire control picks their cannons and silos first, then labs, big power, shields.",
             r"lrpc|long-range cannon|Olympus|Basilica|Basilisk|fires on"),
    "nuke": ("Nukes: a silo late with a big economy; one missile stockpiled; fired at the richest cluster of "
             "theirs no anti-nuke covers, never near our army or base.",
             r"nuke|silo|Armageddon|Apocalypse|Supernova"),
    "antinuke": ("Anti-nuke: built once their nuke silo is seen; interceptors stockpiled.",
                 r"anti-nuke|antinuke|Citadel|Prevailer|Aegis"),
    "shield": ("Shield generator over our labs once their long-range cannons or a real air force are seen.",
               r"shield|Keeper|Overseer|Soteria"),
    "juno": ("Juno: a missile that destroys radar, jammers and mines in a radius; built by Intelligence and "
             "fired at their radar/jammer clusters, weighted toward our air strikes, army pushes and cannon "
             "targets (blind them where we strike).",
             r"Juno|juno"),
    "army": ("The Army sub-commander: one squad that engages where it wins (arc / concave, focus fire, kiting),"
             " regroups, holds, falls back to our turrets, raids their economy, sends a response squad to raids;"
             " its factories build a mix countering what the enemy fields. Judge how its fights went: when it"
             " engaged, at what odds, what it lost, and why fights were lost.",
             r"engag|holding|regroup|falling back|fall back|push|raid|response squad|lost |army style|team plan|factory:"),
    "rez": ("Resurrection bots (Lazarus / Graverobber / Zagreus): two kept, raising the most metal among the "
            "wrecks near home or the army, out of known threat.",
            r"resurrect|Zagreus|Lazarus|Graverobber|rezbot|raised"),
}

SYSTEM = ("You are an expert Beyond All Reason (BAR) player and analyst reviewing logs of our AI sub-commanders "
          "(a widget that runs the player's economy, defense, army, intelligence and air) in a 1v1 against the "
          "BARbarian AI. Be concrete: cite minutes and numbers from the log. Judge the one feature you're asked "
          "about on its own merits, not the game's result.")


def token():
    t = os.environ.get("LLM_API_KEY")
    if t:
        return t.strip()
    return open(TOKEN_FILE).read().strip()


def chat(model, messages, max_tokens=1500, timeout=300):
    body = json.dumps({"model": model, "messages": messages, "max_tokens": max_tokens, "temperature": 0.2}).encode()
    req = urllib.request.Request(BASE + "/chat/completions", data=body, method="POST",
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
                return json.load(r)["choices"][0]["message"]["content"] or ""
        except Exception as e:  # transient: retry
            err = e
    return f"(request failed: {err})"


def digest(path, feature, limit=24000):
    """The feature's story in one game: result, economy every 5 min, the ledger, its events (each log
    message once, first time seen: status blocks repeat them), kills/losses tagged with it."""
    pat = re.compile(FEATURES[feature][1], re.I)
    tag = "feature=" + ("rez" if feature == "rez" else feature)
    seen, out, result, features = set(), [], "", ""
    for line in open(path, errors="replace"):
        line = line.rstrip()
        m = re.match(r"\[(\d+)\]\s+(.*)", line)
        if not m:
            continue
        minute = int(m.group(1)) // 1800
        body = m.group(2)
        if body.startswith("RESULT"):
            result = body
        elif body.startswith("features "):
            features = body
        elif body.startswith("eco ") and re.search(r"minute=(\d+)", body) and int(re.search(r"minute=(\d+)", body).group(1)) % 5 == 0:
            out.append(f"m{minute} {body}")
        elif body.startswith(("killed ", "lost ")):
            if tag in body or (feature == "rez" and "feature=raised" in body):
                out.append(f"m{minute} {body}")
        elif body.startswith(("log:", "AI:")) or "log: " in body:
            msg = body.split("log:", 1)[-1].strip()
            key = re.sub(r"\d+", "N", msg)
            if pat.search(msg) and key not in seen:
                seen.add(key)
                out.append(f"m{minute} log: {msg}")
        elif body.startswith("player:") and pat.search(body):
            out.append(f"m{minute} {body}")
    text = "\n".join(out)
    if len(text) > limit:
        text = text[:limit // 2] + "\n...\n" + text[-limit // 2:]
    return f"{result}\nledger at the end: {features or '(none)'}\n{text}"


def review(model, path, feature):
    d = digest(path, feature)
    q = (f"Feature: {feature}. What it is: {FEATURES[feature][0]}\n\nThe game's log for it (m<minute>):\n{d}\n\n"
         "Answer in this shape:\n"
         "VERDICT: worked / partly / didn't / not used (one word or two)\n"
         "TIMELINE: when it was built and used (minutes)\n"
         "EFFECT: what it achieved (metal killed, raised, territory, what it protected), with numbers\n"
         "PROBLEMS: what went wrong or was wasted (bullets)\n"
         "CHANGE: the one change to its rules that would have helped most here")
    return chat(model, [{"role": "system", "content": SYSTEM}, {"role": "user", "content": q}])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("batches", nargs="+")
    ap.add_argument("--feature", required=True, choices=sorted(FEATURES))
    ap.add_argument("--games", type=int, default=24)
    ap.add_argument("--parallel", type=int, default=8)
    ap.add_argument("--model", default="lightning-ai/deepseek-v4.1-flash")
    ap.add_argument("--out", default="")
    args = ap.parse_args()
    files = []
    for b in args.batches:
        files += sorted(glob.glob(os.path.join(b, "*.txt")), key=lambda p: int(re.sub(r"\D", "", os.path.basename(p)) or 0))
    files = [f for f in files if os.path.basename(f) != "meta.txt"][:args.games]
    if not files:
        sys.exit("no games")
    with cf.ThreadPoolExecutor(args.parallel) as ex:
        answers = list(ex.map(lambda f: (f, review(args.model, f, args.feature)), files))
    out = args.out or os.path.join(args.batches[0], f"llm-{args.feature}.md")
    with open(out.replace(".md", ".jsonl"), "w") as j:
        for f, a in answers:
            j.write(json.dumps({"game": f, "answer": a}) + "\n")
    joined = "\n\n".join(f"### {os.path.relpath(f)}\n{a}" for f, a in answers)
    synth = chat(args.model, [{"role": "system", "content": SYSTEM}, {"role": "user", "content":
        f"Feature: {args.feature}. What it is: {FEATURES[args.feature][0]}\n\nPer-game reviews:\n{joined}\n\n"
        "Synthesise across the games: how often it worked; the recurring problems, most costly first, with how "
        "many games showed each; and the three rule changes for its next version, most promising first, each "
        "with the evidence. Markdown, under 500 words."}], max_tokens=2500)
    with open(out, "w") as o:
        o.write(f"# {args.feature}: LLM review of {len(answers)} games ({args.model})\n\n{synth}\n\n## Per game\n\n{joined}\n")
    print(out)
    print(synth)


if __name__ == "__main__":
    main()
