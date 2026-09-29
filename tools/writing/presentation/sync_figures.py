#!/usr/bin/env python3
"""Copy the thesis figures the deck uses from the pinned thesis release into deck/assets/figures/.

The deck never edits a thesis figure: it copies it. The list of figures is whatever
presentation.qmd references as assets/figures/<name>; the source is <release>/latex/figures/<name>.
MANIFEST.md records each copy's sha256, so syncing from a newer release reports exactly which
figures changed (and so which slides to look at).

  python3 tools/sync_figures.py                 # from the release named in deck/PINNED_RELEASE
  python3 tools/sync_figures.py --release <dir> # from another release folder name (then update the pin)
  python3 tools/sync_figures.py --check         # verify only: every referenced figure present and as recorded
"""
import argparse, hashlib, re, shutil, sys
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent            # .../Writing/Presentation
DECK = HERE / 'deck'
FIG = DECK / 'assets' / 'figures'
RELEASES = HERE.parent / 'Working_Space' / 'RELEASE' / 'output'


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def old_hashes():
    m = FIG / 'MANIFEST.md'
    if not m.exists():
        return {}
    return dict(re.findall(r'^\| `([^`]+)` \| `([0-9a-f]{64})`', m.read_text(), re.M))


def check():
    qmd = (DECK / 'presentation.qmd').read_text()
    wanted = sorted(set(re.findall(r'assets/(figures|media)/([A-Za-z0-9_.-]+)', qmd)))
    recorded, bad = old_hashes(), 0
    for kind, name in wanted:
        f = DECK / 'assets' / kind / name
        if not f.exists():
            print(f'MISSING  assets/{kind}/{name}'); bad += 1
        elif kind == 'figures' and recorded.get(name) != sha(f):
            print(f'UNSYNCED assets/figures/{name} (not as recorded in MANIFEST.md; run sync)'); bad += 1
    print(f'assets   {len(wanted)} referenced, {bad} problem(s)')
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--release', default=(DECK / 'PINNED_RELEASE').read_text().strip())
    ap.add_argument('--check', action='store_true', help='verify only, write nothing')
    a = ap.parse_args()
    if a.check:
        return check()
    src_dir = RELEASES / a.release / 'latex' / 'figures'
    if not src_dir.is_dir():
        sys.exit(f'no such release figures folder: {src_dir}')
    qmd = (DECK / 'presentation.qmd').read_text()
    wanted = sorted(set(re.findall(r'assets/figures/([A-Za-z0-9_.-]+\.(?:png|svg|jpg|pdf))', qmd)))
    FIG.mkdir(parents=True, exist_ok=True)
    before, rows, missing = old_hashes(), [], []
    for name in wanted:
        s = src_dir / name
        if not s.exists():
            missing.append(name)
            continue
        shutil.copy2(s, FIG / name)
        h = sha(FIG / name)
        state = 'new' if name not in before else ('CHANGED' if before[name] != h else 'same')
        rows.append((name, h, state))
    unused = sorted(p.name for p in FIG.iterdir()
                    if p.suffix in {'.png', '.svg', '.jpg', '.pdf'} and p.name not in wanted)
    lines = ['# Figure manifest', '',
             f'Copied from `Working_Space/RELEASE/output/{a.release}/latex/figures/` by '
             f'`tools/sync_figures.py` on {datetime.now():%Y-%m-%d %H:%M}. Never edit these copies.', '',
             '| file | sha256 | vs previous sync |', '| :-- | :-- | :-- |']
    lines += [f'| `{n}` | `{h}` | {st} |' for n, h, st in rows]
    (FIG / 'MANIFEST.md').write_text('\n'.join(lines) + '\n')
    for n, h, st in rows:
        print(f'{st:8s} {n}')
    for n in missing:
        print(f'MISSING  {n}  (not in this release)')
    for n in unused:
        print(f'unused   {n}  (in assets/figures but not referenced by the deck)')
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main())
