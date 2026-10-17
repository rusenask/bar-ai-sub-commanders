#!/usr/bin/env python3
# usage: python3 scripts/spend_breakdown.py <batch dir> <minute>
# Metal spent by category (army, energy, constructors, factories, turrets, extractors) by a minute, per
# game: what is standing then (units: line) plus what was lost before, valued at docs/research/units.jsonl.
import json, re, sys, glob, collections
units = {}
for line in open('docs/research/units.jsonl'):
    u = json.loads(line); units[u['name']] = u
def cat(n):
    u = units.get(n)
    if n.endswith('com'): return None  # the commander comes free
    if not u: return 'other'
    if u.get('extractsMetal', 0) > 0: return 'extractor'
    if u.get('buildSpeed', 0) > 0 and u.get('mobile') : return 'constructor'
    if u.get('buildSpeed', 0) > 0 and not u.get('mobile') and n.endswith(('lab','vp','ap','alab','avp','aap','hp','plat','gant','shltx')) : return 'factory'
    if u.get('buildSpeed', 0) > 0: return 'nano/factory'
    if u.get('weapons') and u.get('mobile'): return 'army'
    if u.get('weapons'): return 'turret'
    if u.get('energyMake',0) > 0 or u.get('windGenerator',0) > 0 or u.get('tidalGenerator',0)>0 or 'sol' in n or 'win' in n or 'makr' in n or 'fus' in n: return 'energy'
    return 'other'
M = int(sys.argv[2])
tot = collections.Counter(); n = 0
for f in glob.glob(sys.argv[1] + '/[0-9]*.txt'):
    lines = open(f).read().splitlines()
    alive = None; minute = 0; lost = collections.Counter()
    for l in lines:
        m = re.search(r'eco minute=(\d+)', l)
        if m: minute = int(m.group(1))
        m = re.search(r'lost minute=(\d+) kind=\S+ name=(\S+) cost=(\d+)', l)
        if m and int(m.group(1)) < M and cat(m.group(2)): lost[cat(m.group(2))] += int(m.group(3))
        if minute == M and alive is None and '] units: ' in l:
            alive = collections.Counter()
            for k, v in re.findall(r'(\w+)=(\d+)', l.split('units: ')[1]):
                if k in units and cat(k):
                    alive[cat(k)] += int(v) * units[k].get('cost', 0)
    if alive is None: continue
    n += 1
    for k in set(alive) | set(lost): tot[k] += alive[k] + lost[k]
print(sys.argv[1], 'games', n, 'metal spent by minute', M, '(alive + lost)')
s = sum(tot.values())
for k, v in tot.most_common(): print(f'  {k:14s} {v/n:8.0f}  {100*v/s:4.1f}%')
