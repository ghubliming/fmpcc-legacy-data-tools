#!/usr/bin/env python3
"""make_review_tex.py -- the author's standalone review file, regenerated from the CURRENT v5 sources.

    python3 tools/make_review_tex.py                 # abstract + Chapter 8 -> review_tmp/CH8_REVIEW_20260926.tex
    python3 tools/make_review_tex.py --check         # exit 1 if the file on disk no longer matches the v5 sources
    python3 tools/make_review_tex.py --chapters 08 07 --out review_tmp/CH7_CH8_REVIEW.tex

Rule (author, 2026-09-26, the manual review): v5 and the review file move together -- every pass that touches the
abstract or a reviewed chapter ends with this script, and `--check` is part of the pass's checks. The file is one
`pdflatex` document: the release tool's cleaner applied to the chapter(s) (comments and drafting macros gone, so the
text is the delivered one), the abstract from the standalone block of parts/01_frontmatter.tex, and a minimal
preamble whose stubs print cross-references to absent chapters as their grey label. Not read by the build.
Python 3 stdlib only; imports ../RELEASE/tools/make_release.py for the cleaner.
"""
import argparse, importlib.util, os, re, sys, datetime, subprocess

HERE = os.path.dirname(os.path.abspath(__file__)); V5 = os.path.normpath(os.path.join(HERE, '..'))
REL = os.path.join(V5, '..', 'RELEASE', 'tools', 'make_release.py')
STATES = {'standalone': False, 'submission': True, 'pillarsflawed': False, 'appendixfull': True}
STUBBED = {'chapter', 'section', 'subsection', 'subsubsection', 'paragraph', 'label', 'begin', 'end', 'item', 'autoref',
           'eqref', 'ac', 'nfe', 'emph', 'textbf', 'texttt', 'enquote', 'parencite', 'cite', 'textcite', 'addlinespace', 'bottomrule', 'caption', 'centering', 'footnotesize', 'linewidth', 'midrule', 'toprule', 'setlength', 'tabcolsep', 'multicolumn', 'FloatBarrier', 'selectedmark', 'baselinemark', 'mainconfig', 'appendix'}
HEAD = r"""% =====================================================================================================
%  TEMPORARY REVIEW FILE  --  the abstract + %(chap)s exactly as the delivered thesis will read them
%  (the release tool's cleaner applied: comments and drafting macros removed).  Not part of the thesis;
%  the build does not read this file.  Generated from v5 %(ver)s on %(when)s by tools/make_review_tex.py.
%
%  HOW TO COMPILE ON OVERLEAF:  New Project -> Blank Project, delete its main.tex, upload THIS file and
%  set it as the main document (Menu -> Settings -> Main document).  Compiler: pdfLaTeX.  Do NOT add it
%  to the thesis project: that project compiles its own main.tex, and this file carries its own preamble.
%
%  Cross-references to chapters not in this file print their label in grey brackets; citations print
%  their key.  Everything else is the delivered wording.
% =====================================================================================================
\documentclass[11pt,a4paper]{report}
\usepackage[T1]{fontenc}
\usepackage[utf8]{inputenc}
\usepackage{lmodern}
\usepackage{amsmath,amssymb}
\usepackage{xcolor}
\usepackage[margin=2.6cm]{geometry}
% --- stubs for the thesis macros; \providecommand so the file also compiles where they already exist
\providecommand{\nfe}{K}
\providecommand{\ac}[1]{#1}
\providecommand{\enquote}[1]{``#1''}
\providecommand{\parencite}[2][]{\textcolor{gray}{[#2]}}
\usepackage{array,tabularx,booktabs,placeins}
\newcolumntype{L}{>{\raggedright\arraybackslash}X}
\providecommand{\vect}[1]{\boldsymbol{#1}}
\providecommand{\matr}[1]{\boldsymbol{#1}}
\providecommand{\trans}{^{\textrm{T}}}
\providecommand{\sidx}[1]{_{\textrm{#1}}}
\providecommand{\Id}[1]{\textbf{Id}_{#1}}
\providecommand{\unitvec}[1]{\textbf{e}_{#1}}
\providecommand{\R}{\mathbb{R}}
\providecommand{\E}{\mathbb{E}}
\providecommand{\Unif}{\mathcal{U}}
\providecommand{\Normal}{\mathcal{N}}
\providecommand{\sg}{\operatorname{sg}}
\providecommand{\proj}[1]{\Pi_{#1}}
\providecommand{\dd}{\mathrm{d}}
\providecommand{\vfield}{v}
\providecommand{\afield}{u}
\providecommand{\ftime}{\tau}
\providecommand{\includegraphics}[2][]{\fbox{\footnotesize figure \texttt{\detokenize{#2}}}}
\providecommand{\selectedmark}{\ensuremath{\blacktriangleright}}
\providecommand{\baselinemark}{\ensuremath{\bullet}}
\providecommand{\mainconfig}[1]{\textbf{#1}}
\providecommand{\autoref}[1]{}
\renewcommand{\autoref}[1]{\textcolor{gray}{{[}#1{]}}}
\renewcommand{\eqref}[1]{\textcolor{gray}{{(}#1{)}}}
"""


class _Any(dict):
    def append(self, x): self.setdefault('_list', []).append(x)
    def __call__(self, *a, **k): return None   # rep.hole(...) and other recorder methods of the release cleaner


class _Rep:
    def __init__(self): self._d = {}
    def __getattr__(self, name):
        if name.startswith('_'): raise AttributeError(name)
        return self._d.setdefault(name, _Any())


def cleaner():
    spec = importlib.util.spec_from_file_location('M', REL); M = importlib.util.module_from_spec(spec); spec.loader.exec_module(M)
    return M


def version():
    for ln in open(os.path.join(V5, 'CHANGELOG.md'), encoding='utf-8'):
        m = re.match(r'^## (v\d+\.\d+[a-z]?)\b', ln)
        if m: return m.group(1)
    return 'v5.?'


def abstract():
    t = open(os.path.join(V5, 'parts', '01_frontmatter.tex'), encoding='utf-8').read()
    m = re.search(r'\\ifstandalone\n(Diffusion planners.*?)\n\\fi', t, flags=re.S)
    if not m: sys.exit('abstract block not found in parts/01_frontmatter.tex')
    return m.group(1).strip()


ANNEX = {'08': ['app:candidates']}   # appendix sections a chapter's review file carries (the numbers behind its tables)


def appendix_section(label):
    """The \\section block of chapters/09_appendix.tex that carries \\label{<label>}, up to the next section or chapter."""
    t = open(os.path.join(V5, 'chapters', '09_appendix.tex'), encoding='utf-8').read()
    m = re.search(r'\\section\{[^\n]*\}\\label\{' + re.escape(label) + r'\}', t)
    if not m: sys.exit(f'appendix section {label} not found')
    n = re.search(r'\n(?=\\section\{|\\chapter\{|% The twenty-episode section)', t[m.end():])
    return t[m.start(): m.end() + (n.start() if n else len(t) - m.end())]


def chapter_title(src):
    m = re.search(r'\\chapter\{([^}]*)\}', src); return m.group(1) if m else '?'


def split_sections(src):
    """[(level, title, label, start, end)] over \\section / \\subsection / \\subsubsection (numbered)."""
    heads = list(re.finditer(r'^\\((?:sub){0,2})section\{([^\n]*?)\}((?:\\label\{[^}]*\})*)', src, flags=re.M))
    out = []
    for k, m in enumerate(heads):
        end = heads[k + 1].start() if k + 1 < len(heads) else len(src)
        labels = re.findall(r'\\label\{([^}]*)\}', m.group(3))
        out.append((len(m.group(1)) // 3, m.group(2), labels, m.start(), end))
    return out


def build_excerpt(labels, out_name, source=None):
    root = source or V5   # --source: a scratch copy of v5 (a PROPOSAL not yet applied)
    """Only the sections named by label, in document order, with grey ellipsis lines for what is left out.
    Section counters are set so the numbers match the thesis."""
    M = cleaner(); parts = []; wanted = set(labels); found = set()
    for f in sorted(os.listdir(os.path.join(root, 'chapters'))):
        if not re.match(r'0[1-8]_.*\.tex$', f): continue
        src = open(os.path.join(root, 'chapters', f), encoding='utf-8').read()
        secs = split_sections(src)
        if not any(set(l) & wanted for _, _, l, _, _ in secs): continue
        ch = int(f[:2]); parts.append(f'\\setcounter{{chapter}}{{{ch - 1}}}\\chapter{{{chapter_title(src)}}}')
        n = [0, 0, 0]; omitted = []
        def flush():
            if omitted:
                parts.append('\\noindent\\textcolor{gray}{\\ldots\\ unchanged: ' + '; '.join(omitted) + ' \\ldots}\n')
                omitted.clear()
        for level, title, labs, a, b in secs:
            n[level] += 1
            for k in range(level + 1, 3): n[k] = 0
            num = '.'.join(str(ch if i < 0 else n[i]) for i in range(-1, level + 1))
            if set(labs) & wanted:
                found |= set(labs) & wanted; flush()
                body = M.clean_tex(src[a:b], 'chapters/' + f, _Rep(), STATES).strip()
                parts.append(f'\\setcounter{{section}}{{{n[0] - (1 if level == 0 else 0)}}}\\setcounter{{subsection}}{{{n[1] - (1 if level == 1 else 0)}}}\\setcounter{{subsubsection}}{{{n[2] - (1 if level == 2 else 0)}}}\n' + body)
            else:
                # a parent of a wanted subsection is printed as a heading only
                child = any(set(l) & wanted and a2 > a and a2 < b for _, _, l, a2, _ in secs)
                if child:
                    flush(); parts.append(f'\\setcounter{{section}}{{{n[0] - (1 if level == 0 else 0)}}}\\setcounter{{subsection}}{{{n[1] - (1 if level == 1 else 0)}}}\n\\' + 'sub' * level + 'section{' + title + '}')
                elif not any(a2 <= a and b2 >= b and set(l) & wanted for _, _, l, a2, b2 in secs):
                    omitted.append(f'\\S{num} {title}')
        flush()
    missing = wanted - found
    if missing: sys.exit(f'sections not found: {sorted(missing)}')
    head = (HEAD.replace('%(chap)s', ('PROPOSAL (not yet in v5) -- ' if source else '') + 'excerpt: ' + ', '.join(labels)).replace('%(ver)s', version())
                .replace('%(when)s', datetime.datetime.now().strftime('%Y-%m-%d %H:%M')))
    return head + '\\begin{document}\n\n' + '\n\n'.join(parts) + '\n\n\\end{document}\n'


def build(chapters, with_abstract, annex=None, source=None):
    root = source or V5   # --source: a scratch copy of v5 (a PROPOSAL not yet applied)
    M = cleaner(); parts = []
    if with_abstract: parts.append('\\chapter*{Abstract}\n' + abstract())
    first = None
    for ch in chapters:
        f = [x for x in sorted(os.listdir(os.path.join(root, 'chapters'))) if x.startswith(ch + '_') and x.endswith('.tex')]
        if not f: sys.exit(f'no chapters/{ch}_*.tex')
        src = open(os.path.join(root, 'chapters', f[0]), encoding='utf-8').read()
        body = M.clean_tex(src, 'chapters/' + f[0], _Rep(), STATES).strip()
        left = sorted(set(re.findall(r'\\([A-Za-z]+)', body)) - STUBBED)
        if left: print(f'note: {f[0]} uses macros the review preamble does not stub: {left}', file=sys.stderr)
        if first is None: first = int(ch)
        parts.append(body)
    labels = [l for ch in chapters for l in ANNEX.get(ch, [])] if annex is None else annex
    if labels:
        blocks = [M.clean_tex(appendix_section(l), 'chapters/09_appendix.tex', _Rep(), STATES).strip() for l in labels]
        parts.append('\\appendix\n\\chapter*{Annex: the appendix sections this chapter reads}\n\n' + '\n\n'.join(blocks))
    head = (HEAD.replace('%(chap)s', ('PROPOSAL (not yet in v5) -- ' if source else '') + 'Chapter ' + ', '.join(str(int(c)) for c in chapters))
                .replace('%(ver)s', version()).replace('%(when)s', datetime.datetime.now().strftime('%Y-%m-%d %H:%M')))
    head += f'\\setcounter{{chapter}}{{{(first or 1) - 1}}}\n\\begin{{document}}\n\n'
    return head + '\n\n'.join(parts) + '\n\n\\end{document}\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--chapters', nargs='+', default=['08'], help='chapter numbers, two digits (default 08)')
    ap.add_argument('--no-abstract', action='store_true')
    ap.add_argument('--out', help='output path (default review_tmp/CH<n>_REVIEW_20260926.tex, the file the review opened with)')
    ap.add_argument('--annex', nargs='*', help='appendix section labels to append (default: ANNEX for the chapter; pass none to omit)')
    ap.add_argument('--source', help='excerpt mode: read the chapters from this v5-like folder instead (a proposal copy)')
    ap.add_argument('--sections', nargs='+', help='excerpt mode: only these section labels, the rest marked by an ellipsis line (with --out)')
    ap.add_argument('--check', action='store_true', help='compare the file on disk with the current sources; exit 1 on drift')
    a = ap.parse_args()
    out = a.out or os.path.join(V5, 'review_tmp', 'CH' + ''.join(str(int(c)) for c in a.chapters) + '_REVIEW_20260926.tex')
    tex = build_excerpt(a.sections, out, a.source) if a.sections else build(a.chapters, not a.no_abstract, a.annex, a.source)
    strip = lambda s: re.sub(r'Generated from v5 .*? by', 'Generated by', s)   # the stamp line is not drift
    if a.check:
        if not os.path.exists(out): sys.exit(f'DRIFT: {os.path.relpath(out, V5)} does not exist -- run without --check')
        if strip(open(out, encoding='utf-8').read()) != strip(tex):
            sys.exit(f'DRIFT: {os.path.relpath(out, V5)} no longer matches the v5 sources -- run without --check')
        print(f'in sync: {os.path.relpath(out, V5)} matches the v5 sources ({version()})'); return
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w', encoding='utf-8', newline='\n') as fh: fh.write(tex)
    assert tex.count('{') == tex.count('}') and tex.count('$') % 2 == 0
    print(f'wrote {os.path.relpath(out, V5)} ({len(tex.splitlines())} lines) from v5 {version()}')


if __name__ == '__main__':
    main()
