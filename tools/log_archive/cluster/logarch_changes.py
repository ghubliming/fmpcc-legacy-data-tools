#!/usr/bin/env python3
"""logarch_changes.py - did logs/ change after it was archived? (files added, removed or modified per unit)

usage:  logarch_changes.py <bundle>/meta <tree_now.tsv.gz> [--split "A B"] [--only "u1 u2"] [--skip "u3"]
tree_now: `find logs` listing in manifest format (type, bytes, mtime, path) - logarch_common.sh capture_tree
compares it with meta/manifests/*.tsv.gz (what the archives hold) and writes
        meta/CHANGES.tsv   one line per changed file
        meta/CHANGES.md    per unit: added / removed / modified, and the FORCE_UNITS line that re-packs them
exit 0 = logs/ still equals the archives · 3 = changes found (units listed) · 2 = usage error
Stdlib only, Python >= 3.6.
"""
import argparse
import collections
import datetime
import gzip
import os
import sys

DEFAULT_SPLIT = "aligning-d3il-visual avoiding-d3il UAV_MIX UAV_FM"


def unit_of(path, split, logs="logs"):
    rel = path[len(logs) + 1:] if path.startswith(logs + "/") else path
    comps = rel.split("/")
    if len(comps) == 1:
        return "_toplevel_files"
    if comps[0] in split:
        return comps[0] + "/_files" if len(comps) == 2 else comps[0] + "/" + comps[1]
    return comps[0]


def load(path):
    out = {}
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) == 4 and p[0] in ("f", "l"):
                out[p[3]] = (p[0], int(p[1]), p[2])
    return out


def human(n):
    n = float(n or 0)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or unit == "TiB":
            return ("%d B" % n) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024.0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("meta")
    ap.add_argument("tree_now")
    ap.add_argument("--split", default=os.environ.get("SPLIT_UNITS", DEFAULT_SPLIT))
    ap.add_argument("--only", default=os.environ.get("ONLY_UNITS", ""))
    ap.add_argument("--skip", default=os.environ.get("SKIP_UNITS", ""))
    a = ap.parse_args(argv[1:])
    split, only, skip = set(a.split.split()), set(a.only.split()), set(a.skip.split())
    mdir = os.path.join(a.meta, "manifests")
    if not os.path.isdir(mdir):
        sys.stderr.write("no %s\n" % mdir)
        return 2
    then = {}
    for name in sorted(os.listdir(mdir)):
        if name.endswith(".tsv.gz"):
            then.update(load(os.path.join(mdir, name)))
    now = load(a.tree_now)
    keep = lambda u: (not only or u in only) and u not in skip
    archived_units = {unit_of(p, split) for p in then}
    rows = []
    for p in sorted(set(then) | set(now)):
        u = unit_of(p, split)
        if not keep(u):
            continue
        t, n = then.get(p), now.get(p)
        if t == n:
            continue
        kind = "added" if t is None else ("removed" if n is None else "modified")
        if u not in archived_units:
            kind = "not-archived"
        rows.append((kind, u, p, t, n))
    with open(os.path.join(a.meta, "CHANGES.tsv"), "w", encoding="utf-8") as fh:
        fh.write("change\tunit\tsize_archived\tsize_now\tmtime_archived\tmtime_now\tpath\n")
        for kind, u, p, t, n in rows:
            fh.write("%s\t%s\t%s\t%s\t%s\t%s\t%s\n" % (kind, u, t[1] if t else "", n[1] if n else "",
                                                       t[2] if t else "", n[2] if n else "", p))
    per, newest = collections.OrderedDict(), {}
    for kind, u, p, t, n in rows:
        c = per.setdefault(u, collections.Counter())
        c[kind] += 1
        c[kind + "_b"] += (n or t)[1]
        newest[u] = max(newest.get(u, ""), (n or t)[2][:16])
    stale = [u for u in per if per[u]["added"] + per[u]["removed"] + per[u]["modified"] > 0]
    fresh = [u for u in per if per[u]["not-archived"] > 0]
    md = ["# CHANGES - logs/ now vs the archives", "",
          "Generated %s by `logarch_changes.py`: %d archived entries compared with %d entries in logs/ now%s." % (
              datetime.datetime.now().isoformat(timespec="seconds"), len(then), len(now),
              (" (only: %s)" % " ".join(sorted(only))) if only else ""), ""]
    if not rows:
        md.append("**No changes** - every file in logs/ is exactly what the archives hold (path, size, mtime).")
    else:
        md += ["| unit | added | removed | modified | not archived | newest change |", "|---|---:|---:|---:|---:|---|"]
        for u, c in per.items():
            md.append("| `%s` | %d (%s) | %d | %d | %d (%s) | %s |" % (u, c["added"], human(c["added_b"]), c["removed"],
                      c["modified"], c["not-archived"], human(c["not-archived_b"]), newest.get(u, "")))
        md.append("")
        if stale:
            md += ["**Re-pack the changed units** (their archives are replaced; finished units are untouched):", "",
                   "```", 'FORCE_UNITS="%s" ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_pack_gdrive.sh <STAMP>'
                   % " ".join(stale), "```", ""]
        if fresh:
            md += ["**Units with no archive yet** (created after packing, or outside ONLY_UNITS) are packed by simply "
                   "re-submitting the same pack job: %s" % ", ".join("`%s`" % u for u in fresh), ""]
        md.append("Every changed file is listed in `CHANGES.tsv`.")
    with open(os.path.join(a.meta, "CHANGES.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(md) + "\n")
    if rows:
        print("[changes] %d changed file(s) in %d unit(s): %s → %s/CHANGES.md" % (
            len(rows), len(per), " ".join(sorted(per))[:300], a.meta))
        return 3
    print("[changes] none - logs/ equals the archives")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
