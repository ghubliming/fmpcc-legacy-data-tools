import re, pathlib
V = pathlib.Path('/workspaces/FM-PCC/logs_in_develop/Writing/Working_Space/v5/chapters')
def strip_notes(t):
    for mac in ['dataref', 'srcnote']:
        while True:
            m = re.search(r'\\' + mac + r'\{', t)
            if not m: break
            i = m.end(); depth = 1
            while depth and i < len(t):
                depth += {'{': 1, '}': -1}.get(t[i], 0); i += 1
            t = t[:m.start()] + t[i:]
    t = re.sub(r'(?m)^%.*\n', '', t)
    return t
def tables_of(t):
    return re.findall(r'\\begin\{table\}.*?\\end\{table\}', t, flags=re.S)
def prose_of(t):
    t = re.sub(r'\\begin\{(table|figure)\}.*?\\end\{\1\}', ' ', t, flags=re.S)
    return strip_notes(t)
NUM = re.compile(r'(?<![\w.])(\d+/\d+|\d+\.\d+|\d{3,})(?![\w.])')
def nums(t):
    t = t.replace('\\,', '').replace('\\%', '%')
    out = []
    for m in NUM.finditer(t):
        s = m.group(1)
        if re.fullmatch(r'\d{4}', s) and s.startswith(('19', '20')): continue   # years
        if re.fullmatch(r'\d{3,}', s) and int(s) > 5000: continue                 # job ids
        out.append(s)
    return out
def tofloat(s):
    if '/' in s: return None
    return float(s)
# the table corpus: chapter 6 + appendix
ch6 = (V/'06_results.tex').read_text(); app = (V/'09_appendix.tex').read_text()
tab_strings = set(); tab_floats = []
for tb in tables_of(ch6) + tables_of(app):
    for s in nums(strip_notes(tb)):
        tab_strings.add(s); f = tofloat(s)
        if f is not None: tab_floats.append(f)
def in_table(s):
    if s in tab_strings: return True
    f = tofloat(s)
    if f is None: return False
    d = len(s.split('.')[1]) if '.' in s else 0
    return any(abs(round(t, d) - f) < 1e-9 for t in tab_floats)
heads = list(re.finditer(r'^\\((?:sub){0,2})section\{([^\n]*?)\}((?:\\label\{[^}]*\})*)', ch6, flags=re.M))
n = [0, 0, 0]; rows = []
for k, m in enumerate(heads):
    level = len(m.group(1)) // 3; title = m.group(2); n[level] += 1
    for j in range(level + 1, 3): n[j] = 0
    num = '6.' + '.'.join(str(x) for x in n[:level + 1])
    end = heads[k + 1].start() if k + 1 < len(heads) else len(ch6)
    body = ch6[m.end():end]; pr = prose_of(body)
    words = len(re.findall(r'[A-Za-z]+', pr)); ns = nums(pr)
    dup = [s for s in ns if in_table(s)]
    rows.append((num, title, body.count('\n'), words, len(ns), len(dup), sorted(set(dup), key=lambda x: -dup.count(x))[:12]))
print(f'{"block":10s} {"title":46s} {"lines":>5s} {"words":>6s} {"nums":>5s} {"inTab":>5s}  examples of prose numbers that a table prints')
for r in rows:
    print(f'{r[0]:10s} {r[1][:46]:46s} {r[2]:5d} {r[3]:6d} {r[4]:5d} {r[5]:5d}  {" ".join(r[6])}')
tot = sum(r[3] for r in rows); print('\nchapter 6 prose words', tot, '| prose numbers', sum(r[4] for r in rows), '| of which in a table', sum(r[5] for r in rows))
print('\n== words per chapter (prose only, floats and notes stripped)')
for f in sorted(V.glob('0*.tex')):
    t = prose_of(f.read_text()); w = len(re.findall(r'[A-Za-z]+', t)); print(f'{f.name:24s} {w:7d} words  {t.count(chr(10)):6d} lines')
