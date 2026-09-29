import re, pathlib, collections
V = pathlib.Path('/workspaces/FM-PCC/logs_in_develop/Writing/Working_Space/v5/chapters'); B = pathlib.Path('/tmp/claude-1000/-workspaces-FM-PCC/c237bedd-9a5c-4d2e-aa3b-e1623286bf8e/scratchpad/chapters_before_tone')
def strip_notes(t):
    for mac in ['dataref', 'srcnote']:
        while True:
            m = re.search(r'\\' + mac + r'\{', t)
            if not m: break
            i = m.end(); d = 1
            while d and i < len(t): d += {'{': 1, '}': -1}.get(t[i], 0); i += 1
            t = t[:m.start()] + t[i:]
    return re.sub(r'(?m)^%.*\n', '', t)
def prose_of(t): return strip_notes(re.sub(r'\\begin\{(table|figure)\}.*?\\end\{\1\}', ' ', t, flags=re.S))
NUM = re.compile(r'(?<![\w.])(\d+/\d+|\d+\.\d+|\d{3,})(?![\w.])')
def nums(t):
    t = t.replace('\\,', '').replace('\\%', '%'); out = []
    for m in NUM.finditer(t):
        s = m.group(1)
        if re.fullmatch(r'\d{4}', s) and s.startswith(('19', '20')): continue
        if re.fullmatch(r'\d{3,}', s) and int(s) > 5000: continue
        out.append(s)
    return out
for f in sorted(p.name for p in V.glob('0*.tex')):
    b = collections.Counter(nums(prose_of((B/f).read_text()))); a = collections.Counter(nums(prose_of((V/f).read_text())))
    gone, new = b - a, a - b
    print(f'{f:22s} before {sum(b.values()):4d} after {sum(a.values()):4d}  removed {dict(gone) if gone else "-"}  added {dict(new) if new else "-"}')
