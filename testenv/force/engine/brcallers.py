import re, subprocess, sys, collections
data, binary = sys.argv[1], sys.argv[2]
# engine load address from mmap events
base = None
for line in subprocess.run(['perf', 'script', '-i', data, '--show-mmap-events', '-F', 'comm'], capture_output=True, text=True).stdout.splitlines():
    if 'PERF_RECORD_MMAP' in line and 'spring-headless' in line and ' r-xp ' in line:
        m = re.search(r'\[(0x[0-9a-f]+)\((0x[0-9a-f]+)\) @ (0x[0-9a-f]+|\d+)', line)
        if m:
            base = int(m.group(1), 16) - int(m.group(3), 16)
            break
print('base', hex(base) if base else None)
nm = subprocess.run(['nm', '-C', binary], capture_output=True, text=True).stdout
SYM = sys.argv[3] if len(sys.argv) > 3 else 'std::chrono::_V2::system_clock::now()'
now = [int(l.split()[0], 16) for l in nm.splitlines() if l.endswith(' ' + SYM) or (' T ' in l and SYM in l)]
print('now at', [hex(a) for a in now])
targets = set(base + a for a in now)
callers = collections.Counter(); total = 0
p = subprocess.Popen(['perf', 'script', '-i', data, '-F', 'brstack'], stdout=subprocess.PIPE, text=True)
for line in p.stdout:
    for e in line.split():
        f, t = e.split('/')[:2]
        if int(t, 16) in targets:
            callers[int(f, 16) - base] += 1; total += 1
print('calls into now() seen', total)
top = callers.most_common(25)
for a, c in top:
    r = subprocess.run(['addr2line', '-C', '-f', '-i', '-e', binary, hex(a)], capture_output=True, text=True).stdout.strip().split('\n')
    chain = [r[k] for k in range(0, len(r), 2)]
    where = r[-1].split('/rts/')[-1]
    print('%5.1f%%  %s  (%s)' % (100 * c / total, ' <- '.join(f[:60] for f in chain[-3:][::-1]), where))
