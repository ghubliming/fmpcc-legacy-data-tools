import re, pathlib, json
V = pathlib.Path('/workspaces/FM-PCC/logs_in_develop/Writing/Working_Space/v5/chapters'); B = pathlib.Path('/tmp/claude-1000/-workspaces-FM-PCC/c237bedd-9a5c-4d2e-aa3b-e1623286bf8e/scratchpad/chapters_before_tone')
def prose(t):
    t = re.sub(r'\\begin\{(table|figure)\}.*?\\end\{\1\}', ' ', t, flags=re.S)
    for mac in ['dataref', 'srcnote']:
        while True:
            m = re.search(r'\\' + mac + r'\{', t)
            if not m: break
            i = m.end(); d = 1
            while d and i < len(t): d += {'{': 1, '}': -1}.get(t[i], 0); i += 1
            t = t[:m.start()] + t[i:]
    t = re.sub(r'(?m)^%.*\n', '', t); t = re.sub(r'\\paragraph\{[^}]*\}', '', t); t = re.sub(r'\\(?:sub)*section\*?\{[^}]*\}(\\label\{[^}]*\})*', '', t)
    t = re.sub(r'\s+', ' ', t)
    return [x.strip() for x in re.split(r'(?<=[.!?])\s+(?=[A-Z\\$(])', t) if len(x.strip()) > 25]
norm = lambda x: re.sub(r'[^a-z0-9]', '', x.lower())
out = ['## Verification of the tone-only rule: every prose sentence removed or reworded, per chapter', '', 'Old wording first, new wording second (headings, captions inside floats and drafting notes are not sentences here; the log of all 229 anchored replacements is in the Orchestra job).', '']
tot_r = tot_a = 0
for f in sorted(p.name for p in V.glob('0*.tex')):
    old = prose((B/f).read_text()); new = prose((V/f).read_text())
    ns = {norm(x) for x in new}; os_ = {norm(x) for x in old}
    removed = [x for x in old if norm(x) not in ns]; added = [x for x in new if norm(x) not in os_]
    if not removed and not added: continue
    tot_r += len(removed); tot_a += len(added)
    out += [f'### `{f}` — {len(removed)} old sentences reworded or removed, {len(added)} new wordings', '', '**Old:**', ''] + [f'- {x}' for x in removed] + ['', '**New:**', ''] + [f'- {x}' for x in added] + ['']
out.insert(3, f'Totals: {tot_r} old sentences reworded or removed, {tot_a} new wordings, over Chapters 1–9.')
pathlib.Path('/tmp/claude-1000/-workspaces-FM-PCC/c237bedd-9a5c-4d2e-aa3b-e1623286bf8e/scratchpad/tone_sentdiff.md').write_text('\n'.join(out) + '\n')
print('removed/reworded', tot_r, 'new', tot_a)
log = json.load(open('/tmp/claude-1000/-workspaces-FM-PCC/c237bedd-9a5c-4d2e-aa3b-e1623286bf8e/scratchpad/tone_log.json'))
print('R073:', [e for e in log if e[1] == 'R073'] or 'applied')
