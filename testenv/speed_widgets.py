#!/usr/bin/env python3
"""Disables BAR's own UI widgets in a write dir's LuaUI/Config/BYAR.lua for faster test games
(docs/research/speed.md). Keeps our widgets, the APIs they use and the widgets that give units orders
(so the game plays the same); drops drawing, sound and interface widgets.

usage: speed_widgets.py <write dir> [minimal|all]   (all = disable everything but ours)
"""
import re
import sys

KEEP_EXACT = {
    # ours and the harness
    "Sub-Commanders", "Sub-Commanders AI link", "Sub-Commanders Autopilot",
    "ZZ SubCommander Test", "ZZ Decision Data Logger", "ZZ Smoke",
    # used by our widget (WG.resource_spot_finder, WG.fonts)
    "Font handler",
    # widgets that give our units orders or set their states
    "Auto Cloak Units", "Auto First Build Facing", "Auto Repair Idle Builders", "Builder Priority",
    "Cloak Fire State", "Cloaked Buildpower Default Move", "DGun Stall Assist", "Factory Assist Fix",
    "Factory Guard Default On", "Factory hold position", "Guard Remove", "Guard damaged constructors",
    "Holdfire Fix", "Idle Constructor Guard After Build", "Onoff for Hound and trajectory",
    "Preserve Commands", "Priority Construction Turrets", "Set fighters on Fly mode", "Stop means Stop",
    "Transport Factory Guard", "State Prefs V2", "Factory Quotas", "Attack no Ally", "DGun no ally",
    "Clean Builder Queue", "Exclude walls from area attacks", "Skip Allied Upgrade Toggle",
    "Headless environment overrides",
    # not in the saved order table (named like their files); kept: orders, or used by other widgets
    "BombersDefaultHoldFire", "ImmobileBuilder", "NoDuplicateOrders", "CommandInsert", "FlowUI",
    "Language", "Autoquit",
}

# widgets the game loads that the saved order table doesn't list (BYAR.lua only has those a player has
# toggled or that the game listed once): added with 0 unless kept
UNLISTED = [
    "AdvPlayersList", "AllyCursors", "Autoquit", "Awards", "Blueprint", "BombersDefaultHoldFire", "BuildETA",
    "CameraFlip", "CameraShake", "Chat", "CommandInsert", "Cursor", "CustomFormations2", "Ecostats",
    "Factionpicker", "FlowUI", "GameTypeInfo", "Geothermalspots", "ImmobileBuilder", "Info", "Language",
    "Lockcamera", "Messages", "Metalspots", "Minimap", "NoDuplicateOrders", "Notifications", "Options",
    "Prospector", "ReclaimInfo", "RelativeMinimap", "SSAO", "Selectionbox", "SmartSelect", "Snow",
    "TeamStats", "Tooltip",
]


def keep(name, mode):
    if name.startswith("ZZ ") or name.startswith("Sub-Commanders"):
        return True
    if mode == "all":
        return False
    return name in KEEP_EXACT or name.startswith("API ") or name.endswith(" API")


def main():
    wdir = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else "minimal"
    p = wdir + "/LuaUI/Config/BYAR.lua"
    s = open(p).read()
    m = re.search(r"(\border\s*=\s*\{)(.*?)(\n\t\})", s, re.S)
    off = 0

    def sub(e):
        nonlocal off
        name, val = e.group(1), e.group(2)
        if val != "0" and not keep(name, mode):
            off += 1
            return '["%s"] = 0' % name
        return e.group(0)

    body = re.sub(r'\["(.*?)"\] = (\d+)', sub, m.group(2))
    listed = set(re.findall(r'\["(.*?)"\] = \d+', body))
    for name in UNLISTED:
        if name not in listed and not keep(name, mode):
            body += '\n\t\t["%s"] = 0,' % name
            off += 1
    s = s[: m.start(2)] + body + s[m.end(2):]
    open(p, "w").write(s)
    print("disabled %d widgets (%s)" % (off, mode), file=sys.stderr)


main()
