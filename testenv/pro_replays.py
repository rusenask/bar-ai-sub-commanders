"""Fetch replays of strong players' 1v1 games from BAR's public replay archive, with what they need to play.

usage: uv run --with certifi python testenv/pro_replays.py [--pages 5] [--min-skill 30] [--max 20]
On the force host (testenv/force/README.md): BAR_PRD=~/bar-sim/engine/pr-downloader BAR_DATA=~/bar-sim/data
BAR_DEMOS=~/bar-sim/demos python3 pro_replays.py ... (system CA certificates; certifi optional)

For each human 1v1 that ended normally, on the installed engine, longer than 8 minutes, where both players
are rated at least --min-skill: downloads the replay into testenv/demos/pro/, and its map and game version
into the BAR data folder with BAR's own pr-downloader and content network. testenv/demos/pro/manifest.json
lists what was fetched (players, ratings, factions, map, game version). Play them with testenv/replays.sh.
"""

import argparse
import json
import os
import re
import ssl
import subprocess
import urllib.parse
import urllib.request
from pathlib import Path

try:
    import certifi
except ImportError:  # Linux: the system's CA certificates
    certifi = None

API = "https://api.bar-rts.com/replays"
STORAGE = "https://storage.uk.cloud.ovh.net/v1/AUTH_10286efc0d334efd917d476d7183232e/BAR/demos"
ENGINE = "2026.07.04"
PRD = os.environ.get("BAR_PRD", "/Applications/BAR Launcher.app/Contents/MacOS/pr-downloader")
BAR = Path(os.environ.get("BAR_DATA", Path.home() / "Library/Application Support/Beyond-All-Reason-mac"))
OUT = Path(os.environ.get("BAR_DEMOS", Path(__file__).resolve().parent / "demos/pro"))
CTX = ssl.create_default_context(cafile=certifi.where()) if certifi else ssl.create_default_context()


def get(url):
    return json.load(urllib.request.urlopen(url, timeout=30, context=CTX))


def skill(p):
    m = re.search(r"[\d.]+", p.get("skill") or "")
    return float(m.group()) if m else 0.0


def prd(*args):
    env = dict(os.environ, PRD_RAPID_REPO_MASTER="https://repos-cdn.beyondallreason.dev/repos.gz",
               PRD_HTTP_SEARCH_URL="https://files-cdn.beyondallreason.dev/find")
    r = subprocess.run([PRD, "--filesystem-writepath", str(BAR), *args], env=env, capture_output=True, text=True)
    return r.returncode == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pages", type=int, default=5, help="pages of 100 recent duels to scan")
    ap.add_argument("--min-skill", type=float, default=30)
    ap.add_argument("--max", type=int, default=20)
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    manifest_path = OUT / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    have_maps, have_games = set(), set()
    fetched = 0
    for page in range(1, args.pages + 1):
        listing = get(f"{API}?page={page}&limit=100&preset=duel&hasBots=false&endedNormally=true")["data"]
        if not listing:
            break
        for item in listing:
            if fetched >= args.max:
                break
            if item["id"] in manifest:
                continue
            r = get(f"{API}/{item['id']}")
            players = [p for at in r["AllyTeams"] for p in at["Players"]]
            if (r["engineVersion"] != ENGINE or len(players) != 2 or r["durationMs"] < 8 * 60000
                    or min(skill(p) for p in players) < args.min_skill):
                continue
            path = OUT / f"{r['id']}.sdfz"
            if not path.exists():
                with urllib.request.urlopen(f"{STORAGE}/{urllib.parse.quote(r['fileName'])}", timeout=120, context=CTX) as resp:
                    path.write_bytes(resp.read())
            game, mapname = r["gameVersion"], r["Map"]["scriptName"]
            ok = (mapname in have_maps or prd("--download-map", mapname)) and (game in have_games or prd("--download-game", game))
            if not ok:
                print("could not fetch the map or game for", r["id"], mapname, game)
                continue
            have_maps.add(mapname)
            have_games.add(game)
            winners = [p["name"] for at in r["AllyTeams"] if at.get("winningTeam") for p in at["Players"]]
            manifest[r["id"]] = {
                "file": path.name, "map": mapname, "game": game, "minutes": r["durationMs"] // 60000,
                "players": [{"name": p["name"], "skill": skill(p), "faction": p.get("faction")} for p in players],
                "winners": winners, "start": r["startTime"],
            }
            fetched += 1
            print(f"{r['id']}  {mapname}  {[round(skill(p), 1) for p in players]}  {r['durationMs'] // 60000} min")
            manifest_path.write_text(json.dumps(manifest, indent=1))
        if fetched >= args.max:
            break
    print(f"{fetched} new replays, {len(manifest)} in {OUT}")


if __name__ == "__main__":
    main()
