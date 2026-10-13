"""List the files of BAR game versions in the Mac install, for rsync --files-from to the force host.

usage: python3 testenv/force/sync_games.py "Beyond All Reason test-31604-de18957" ... > /tmp/files.txt
       rsync -a --files-from=/tmp/files.txt ~/Library/Application\\ Support/Beyond-All-Reason-mac/ force:bar-sim/data/

The rapid streamer refuses game downloads from force (HTTP error), maps download there fine; game
versions come from the Mac (fetch them there first with pr-downloader or by playing a replay).
"""
import gzip
import sys
from pathlib import Path

BAR = Path.home() / "Library/Application Support/Beyond-All-Reason-mac"
versions = gzip.open(BAR / "rapid/repos-cdn.beyondallreason.dev/byar/versions.gz").read().decode()
by_name = {}
for line in versions.splitlines():
    parts = line.split(",")
    if len(parts) >= 4:
        by_name[parts[3]] = parts[1]
print("rapid/repos-cdn.beyondallreason.dev/byar/versions.gz")
print("rapid/repos-cdn.beyondallreason.dev/repos.gz")
for name in sys.argv[1:]:
    h = by_name.get(name)
    sdp = BAR / f"packages/{h}.sdp" if h else None
    if not sdp or not sdp.exists():
        print(f"missing on the Mac: {name}", file=sys.stderr)
        continue
    print(f"packages/{h}.sdp")
    data = gzip.open(sdp).read()
    i = 0
    while i < len(data):
        n = data[i]
        i += 1 + n
        md5 = data[i:i + 16].hex()
        i += 24
        print(f"pool/{md5[:2]}/{md5[2:]}.gz")
