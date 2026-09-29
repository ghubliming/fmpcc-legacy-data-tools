import re, pathlib
src = pathlib.Path('/workspaces/FM-PCC/logs_in_develop/Writing/Working_Space/v5/chapters/06_results.tex').read_text()
heads = list(re.finditer(r'^\\((?:sub){0,2})section\{([^\n]*?)\}((?:\\label\{[^}]*\})*)', src, flags=re.M))
def strip_blocks(t):
    # drop floats, drafting notes, comments
    t = re.sub(r'\\begin\{(table|figure)\}.*?\\end\{\1\}', lambda m: f'<<{m.group(1).upper()}>>', t, flags=re.S)
    for mac in ['dataref', 'srcnote', 'guard', 'provisional']:
        # balanced-brace removal (one level of nesting is enough here: use a loop)
        while True:
            m = re.search(r'\\' + mac + r'\{', t)
            if not m: break
            i = m.end(); depth = 1
            while depth and i < len(t):
                depth += {'{': 1, '}': -1}.get(t[i], 0); i += 1
            t = t[:m.start()] + (f'<<{mac.upper()}>>' if mac in ('guard', 'provisional') else '') + t[i:]
    t = re.sub(r'(?m)^%.*\n', '', t)
    t = re.sub(r'\\FloatBarrier', '', t)
    return t
n = [0, 0, 0]
for k, m in enumerate(heads):
    level = len(m.group(1)) // 3; title = m.group(2)
    n[level] += 1
    for j in range(level + 1, 3): n[j] = 0
    num = '6.' + '.'.join(str(x) for x in n[:level + 1])
    end = heads[k + 1].start() if k + 1 < len(heads) else len(src)
    body = src[m.end():end]
    nt, nf = body.count('\\begin{table}'), body.count('\\begin{figure}')
    clean = strip_blocks(body)
    kps = re.findall(r'\\paragraph\{([^}]*)\}', clean)
    paras = [p.strip() for p in re.split(r'\n\s*\n', clean) if p.strip() and not p.strip().startswith('<<') and not p.strip().startswith('\\paragraph')]
    print(f'\n### {num} {title}   [lines {body.count(chr(10))}, tables {nt}, figures {nf}, paragraphs {len(paras)}, key points {len(kps)}]')
    if kps:
        for i, kp in enumerate(kps, 1): print(f'  KP{i}: {kp}')
    else:
        for i, p in enumerate(paras, 1):
            first = re.sub(r'\s+', ' ', p)
            sent = re.split(r'(?<=[.!?])\s', first, 1)[0]
            print(f'  P{i}: {sent[:190]}')
