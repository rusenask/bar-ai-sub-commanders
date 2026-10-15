#!/usr/bin/env python3
"""The unit catalogue from the game's own data (testenv/unit-catalogue.sh -> docs/research/units.jsonl):
every unit each faction can reach from its commander's build tree, tagged with what it can do, grouped
per faction by ability, with whether our widget uses that ability. Writes docs/research/units.md and
docs/research/units-catalogue.json (the compact tags, for the widget and the strategist).
usage: unit_catalogue.py [units.jsonl] [out.md]"""
import collections
import json
import sys

src = sys.argv[1] if len(sys.argv) > 1 else "docs/research/units.jsonl"
out_md = sys.argv[2] if len(sys.argv) > 2 else "docs/research/units.md"
U = {}
for line in open(src):
    u = json.loads(line)
    U[u["name"]] = u

FACTIONS = (("armcom", "Armada"), ("corcom", "Cortex"), ("legcom", "Legion"))
faction, depth = {}, {}
for com, f in FACTIONS:
    q, seen = [(com, 0)], {com}
    while q:
        n, dpt = q.pop(0)
        faction.setdefault(n, f)
        depth[n] = min(depth.get(n, 99), dpt)
        for b in U.get(n, {}).get("builds") or []:
            if b and b in U and b not in seen:
                seen.add(b)
                q.append((b, dpt + 1))


def weapons(u):
    return u.get("weapons") or []


def cp(u):
    return u.get("customParams") or {}


def tags(u):
    """What a unit can do, as short tags (an ability's name in units.md)."""
    t = []
    mobile, air = u.get("mobile"), u.get("air")
    ws = weapons(u)
    if u.get("canCloak") and not u.get("factory") and u["kind"] != "commander":
        t.append("cloak")
    if u.get("stealth") and mobile:
        t.append("radar stealth")
    if u.get("sonarStealth") and mobile and not air:
        t.append("sonar stealth")
    if (u.get("radar") or 0) >= 1000 and u["kind"] not in ("commander",):
        t.append("radar")
    if (u.get("jammer") or 0) > 0:
        t.append("jammer")
    if (u.get("sonar") or 0) >= 600:
        t.append("sonar")
    if (u.get("seismic") or 0) > 0:
        t.append("seismic detector")
    if u.get("canResurrect"):
        t.append("resurrect")
    if u.get("canCapture"):
        t.append("capture")
    if (u.get("transportCapacity") or 0) > 0:
        t.append("transport")
    if u.get("canKamikaze") or cp(u).get("instantselfd"):
        t.append("kamikaze / self-destruct bomb")
    if cp(u).get("mine"):
        t.append("mine")
    if cp(u).get("minesweeper"):
        t.append("minesweeper")
    if cp(u).get("decoyfor"):
        t.append("decoy")
    if cp(u).get("geothermal"):
        t.append("geothermal")
    if cp(u).get("energyconv_capacity"):
        t.append("energy converter")
    if mobile and not air and not u.get("naval") and (u.get("maxWaterDepth") or 0) > 200 and not u.get("hover"):
        t.append("amphibious")
    if u.get("canSubmerge") and air:
        t.append("seaplane")
    elif u.get("canSubmerge") or (u.get("naval") and u.get("sonarStealth") and mobile):
        t.append("submarine")
    if u.get("onOffable"):
        t.append("on/off")
    for w in ws:
        typ = w.get("type") or ""
        wcp = w.get("customParams") or {}
        if w.get("paralyzer"):
            t.append("EMP (paralyses)")
        if (w.get("interceptor") or 0) > 0:
            t.append("anti-nuke / interceptor")
        if w.get("stockpile"):
            t.append("stockpiled missile")
            if (w.get("aoe") or 0) >= 500 and "juno" not in (w.get("name") or "").lower() and not (w.get("interceptor") or 0):
                t.append("nuke")
        if typ == "Shield" or (w.get("shieldPower") or 0) > 0:
            t.append("shield")
        if typ == "DGun" or w.get("manualFire"):
            t.append("manual fire (D-gun style)")
        if typ == "Flame":
            t.append("flamethrower")
        if typ == "LightningCannon":
            t.append("lightning")
        if typ == "TorpedoLauncher" or w.get("waterWeapon"):
            t.append("torpedo")
        if typ == "StarburstLauncher" and not w.get("stockpile"):
            t.append("vertical-launch missiles")
        if wcp.get("cluster_number"):
            t.append("cluster munitions")
        if wcp.get("spawns_surface") or wcp.get("maxunits"):
            t.append("drone carrier")
        if wcp.get("speceffect") == "juno" or cp(u).get("juno_kill"):
            pass
        if (w.get("range") or 0) >= 2000 and not air and not w.get("stockpile") and not (w.get("interceptor") or 0):
            t.append("long-range artillery (2000+)")
    if any("juno" in (w.get("name") or "").lower() for w in ws):
        t.append("juno (kills mines, radar, jammers)")
    if cp(u).get("smart_weapon_cmddesc") or cp(u).get("weapons_smart_select"):
        t.append("switchable weapon modes")
    seen = []
    for x in t:
        if x not in seen:
            seen.append(x)
    return seen


# does our widget use the ability? (searched by hand; update when a behaviour lands)
USED = {
    "cloak": "Armada overlay: kept cloaked, raids (2026-10-15)",
    "radar": "Intelligence sub-commander", "jammer": "Intelligence sub-commander", "sonar": "Intelligence",
    "seismic detector": "Intelligence (structures)", "transport": "no (only excluded from the air force)",
    "manual fire (D-gun style)": "commander D-gun only", "energy converter": "economy (surplus energy)",
    "geothermal": "economy (if a constructor offers it)",
    "anti-nuke / interceptor": "doctrine.strategic.antinuke (under test): built, interceptors stockpiled",
    "shield": "doctrine.strategic.shield (under test): one over the labs",
    "long-range artillery (2000+)": "doctrine.strategic.lrpc (under test): the cheapest cannon, fire control",
    "juno (kills mines, radar, jammers)": "doctrine.strategic.juno (under test): silo, fired on clusters",
    "resurrect": "doctrine.strategic.resurrect (under test): rez bots raise wrecks",
    "stockpiled missile": "anti-nuke and Juno stockpiles (under test)",
}

rows = []
for n, f in faction.items():
    u = U[n]
    if n.endswith("_scav") or cp(u).get("decoration"):
        continue
    rows.append((f, n, u, tags(u)))

compact = {n: {"faction": f, "human": u.get("human"), "kind": u.get("kind"), "cost": u.get("cost"),
               "tech": cp(u).get("techlevel"), "health": u.get("health"), "tags": tg} for f, n, u, tg in rows}
json.dump(compact, open(out_md.replace("units.md", "units-catalogue.json"), "w"), indent=0, sort_keys=True)

with open(out_md, "w") as o:
    o.write("# Unit catalogue (from the game's own data)\n\n")
    o.write("Generated by `scripts/unit_catalogue.py` from `docs/research/units.jsonl` "
            "(`testenv/unit-catalogue.sh`: every unit definition of the installed BAR). A faction's units are "
            "what its commander's build tree reaches. Tags come from the definitions (abilities, weapon types "
            "and properties, custom parameters). *Used*: whether our widget does anything with it.\n\n")
    counts = collections.Counter(f for f, *_ in rows)
    o.write("Units per faction: " + ", ".join(f"{f} {counts[f]}" for _, f in FACTIONS) + "\n\n")
    by_tag = collections.defaultdict(lambda: collections.defaultdict(list))
    for f, n, u, tg in rows:
        for x in tg:
            by_tag[x][f].append(u)
    o.write("## Abilities by faction\n\n| Ability | Used by us | Armada | Cortex | Legion |\n|---|---|---|---|---|\n")
    for x in sorted(by_tag, key=lambda k: -sum(len(v) for v in by_tag[k].values())):
        cells = []
        for _, f in FACTIONS:
            us = sorted(by_tag[x][f], key=lambda u: u.get("cost") or 0)
            cells.append(", ".join(f"{u.get('human')} ({u['name']}, {int(u.get('cost') or 0)})" for u in us[:12])
                         + (f" +{len(us) - 12} more" if len(us) > 12 else ""))
        o.write(f"| {x} | {USED.get(x, '**no**')} | " + " | ".join(cells) + " |\n")
    for _, f in FACTIONS:
        o.write(f"\n## {f}\n\n| Unit | Name | Tech | Kind | Metal | Health | Range | Speed | Abilities |\n|---|---|---|---|---|---|---|---|---|\n")
        for _, n, u, tg in sorted([r for r in rows if r[0] == f], key=lambda r: (r[2].get("kind") or "", r[2].get("cost") or 0)):
            rng = max([w.get("range") or 0 for w in weapons(u)] or [0])
            o.write(f"| {u.get('human')} | {n} | {cp(u).get('techlevel', '')} | {u.get('kind')} | {int(u.get('cost') or 0)} | "
                    f"{int(u.get('health') or 0)} | {int(rng)} | {int(u.get('speed') or 0)} | {', '.join(tg)} |\n")
print(f"{len(rows)} units: {dict(counts)}; {len(by_tag)} abilities -> {out_md}")
