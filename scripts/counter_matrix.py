#!/usr/bin/env python3
"""The measured counter matrix from a battle batch on testenv/battles-counter: for each faction, our
category (row) against theirs (column), mean log2 battle efficiency (their share lost over ours; + = we
trade better) and battles. usage: counter_matrix.py <batch dir>..."""
import collections, glob, math, re, sys

cells = collections.defaultdict(list)
for d in sys.argv[1:]:
    for f in glob.glob(d + "/[0-9]*.txt"):
        for line in open(f):
            m = re.search(r"BATTLE spec=(\w+)-(\w+)-vs-(\w+) .*us_start=([\d.]+) us_left=([\d.]+) them_start=([\d.]+) them_left=([\d.]+)", line)
            if not m:
                continue
            fac, us, them = m.group(1), m.group(2), m.group(3)
            us0, us1, th0, th1 = map(float, m.groups()[3:])
            if us0 <= 0 or th0 <= 0:
                continue
            ours, theirs = (us0 - us1) / us0, (th0 - th1) / th0
            eff = 1.0 if ours <= 0.01 and theirs <= 0.01 else (8.0 if ours <= 0.01 else min(8.0, theirs / ours))
            cells[(fac, us, them)].append(math.log2(max(eff, 0.125)))
order = ["raider", "assault", "skirmisher", "heavy", "artillery"]
for fac in sorted({k[0] for k in cells}):
    cats = [c for c in order if any(k[0] == fac and k[1] == c for k in cells)]
    print(f"\n### {fac}: mean log2 efficiency, ours (rows) vs theirs (columns)\n")
    print("| ours \\ theirs | " + " | ".join(cats) + " |")
    print("|---|" + "---|" * len(cats))
    for us in cats:
        row = []
        for them in cats:
            v = cells.get((fac, us, them), [])
            row.append(f"{sum(v) / len(v):+.2f} ({len(v)})" if v else "")
        print(f"| {us} | " + " | ".join(row) + " |")
