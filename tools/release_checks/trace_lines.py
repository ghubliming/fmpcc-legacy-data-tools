"""Line tracer for the release smoke test (standard library only; not part of the release).

  python trace_lines.py run --root DIR --out FILE.json -- SCRIPT [ARGS ...]
      runs SCRIPT as __main__ and records every executed line of the Python files under DIR (merged into FILE.json)
  python trace_lines.py report --root DIR FILE.json [FILE.json ...]
      executed / executable lines per file under DIR/fmpcc and DIR/scripts, and the lines that never ran
"""
import argparse
import json
import os
import runpy
import sys
import threading
import traceback
import types

VENDORED = ('fmpcc/envs/d3il/', 'fmpcc/envs/quadrotor/predictive_sampling.py')


def run(root, out, argv):
    root = os.path.realpath(root) + os.sep
    hits, owner = {}, {}

    def lines_of(filename):
        if filename not in owner:
            real = os.path.realpath(filename)
            owner[filename] = hits.setdefault(real, set()) if real.startswith(root) else None
        return owner[filename]

    def tracer(frame, event, arg):
        lines = lines_of(frame.f_code.co_filename)
        if lines is None:
            return None

        def local(frame, event, arg):
            if event == 'line':
                lines.add(frame.f_lineno)
            return local
        return local

    script = argv[0]
    sys.argv = list(argv)
    sys.path[0] = os.path.dirname(os.path.abspath(script))
    code = 0
    sys.settrace(tracer)
    threading.settrace(tracer)
    try:
        runpy.run_path(script, run_name='__main__')
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    except BaseException:
        traceback.print_exc()
        code = 1
    finally:
        sys.settrace(None)
        threading.settrace(None)
        merged = {}
        if os.path.exists(out):
            with open(out) as f:
                merged = json.load(f)
        for path, lines in hits.items():
            rel = path[len(root):]
            merged[rel] = sorted(set(merged.get(rel, [])) | lines)
        with open(out, 'w') as f:
            json.dump(merged, f)
    return code


def executable(path):
    with open(path, encoding='utf-8') as f:
        code = compile(f.read(), path, 'exec')
    lines, stack = set(), [code]
    while stack:
        c = stack.pop()
        lines.update(line for _, _, line in c.co_lines() if line)
        stack.extend(k for k in c.co_consts if isinstance(k, types.CodeType))
    return lines


def ranges(missed, lines):
    """Missed lines as ranges; a range runs on while the next executable line is missed too."""
    out, start, prev = [], None, None
    for line in sorted(lines):
        if line in missed:
            start = line if start is None else start
            prev = line
        elif start is not None:
            out.append(f'{start}' if start == prev else f'{start}-{prev}')
            start = None
    if start is not None:
        out.append(f'{start}' if start == prev else f'{start}-{prev}')
    return ', '.join(out)


def report(root, files):
    root = os.path.realpath(root)
    hits = {}
    for name in files:
        with open(name) as f:
            for rel, lines in json.load(f).items():
                hits.setdefault(rel, set()).update(lines)
    own, vendored = [0, 0], {v: [0, 0] for v in VENDORED}
    rows = []
    for top in ('fmpcc', 'scripts'):
        for base, dirs, names in os.walk(os.path.join(root, top)):
            dirs[:] = sorted(d for d in dirs if d != '__pycache__')
            for n in sorted(names):
                if not n.endswith('.py'):
                    continue
                path = os.path.join(base, n)
                rel = os.path.relpath(path, root)
                lines = executable(path)
                ran = hits.get(rel, set()) & lines
                group = next((v for v in VENDORED if rel.startswith(v)), None)
                if group:
                    vendored[group][0] += len(ran)
                    vendored[group][1] += len(lines)
                    continue
                own[0] += len(ran)
                own[1] += len(lines)
                if lines:
                    missed = ranges(lines - ran, lines)
                    rows.append(f'[ trace ] {rel:52s} {len(ran):5d}/{len(lines):<5d} {100 * len(ran) / len(lines):5.1f} %'
                                + (f'   never ran: {missed}' if missed else ''))
    print('\n'.join(rows))
    print(f'[ trace ] own code (fmpcc without the vendored parts, scripts): {own[0]}/{own[1]} lines ran, '
          f'{100 * own[0] / max(own[1], 1):.1f} %')
    for v, (ran, total) in vendored.items():
        print(f'[ trace ] vendored {v}: {ran}/{total} lines ran, {100 * ran / max(total, 1):.1f} %')


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'run':
        p = argparse.ArgumentParser(prog='trace_lines.py run')
        p.add_argument('--root', required=True)
        p.add_argument('--out', required=True)
        args, rest = p.parse_known_args(sys.argv[2:])
        if rest[:1] == ['--']:
            rest = rest[1:]
        sys.exit(run(args.root, args.out, rest))
    p = argparse.ArgumentParser(prog='trace_lines.py report')
    p.add_argument('mode', choices=['report'])
    p.add_argument('--root', required=True)
    p.add_argument('files', nargs='+')
    args = p.parse_args()
    report(args.root, args.files)


if __name__ == '__main__':
    main()
