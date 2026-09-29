#!/usr/bin/env python3
"""logarch_summarize.py - machine summary of a log-archive bundle (the INPUT of the AI catalog step).

usage:  logarch_summarize.py <bundle>/meta [--stamp STAMP]
reads:  meta/receipts/<stem>.<tier>.{packed,empty,pulled,gdrive}   key=value lines
        meta/manifests/<stem>.<tier>.tsv.gz                         type, bytes, mtime, path (TAB-separated)
writes: meta/SHA256SUMS  meta/units.tsv  meta/SUMMARY.json  meta/SUMMARY.md
Stdlib only, Python >= 3.6, so it runs on the cluster and in the local container alike.
"""
import collections
import datetime
import gzip
import json
import os
import re
import sys

TIERS = ("core", "media", "weights")
KINDS = ("packed", "empty", "pulled", "gdrive")
BACKUP = re.compile(r"\((Bf_|Archive|smoke|legacy|Outdated|Abandoned)", re.I)
MARKERS = ("results.json", "args.json", "state_best.pt", "losses.pkl", "run_config.csv")


def human(n):
    n = float(n or 0)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or unit == "TiB":
            return ("%d B" % n) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024.0


def read_kv(path):
    out = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if "=" in line:
                key, val = line.rstrip("\n").split("=", 1)
                out[key] = val
    return out


def scan(manifests, root, top_n=25):
    """Aggregate the manifests of one unit: sizes, dates, extensions, sub-folders, marker files."""
    acc = {"files": 0, "bytes": 0, "oldest": None, "newest": None}
    ext_n, ext_b, markers = collections.Counter(), collections.Counter(), collections.Counter()
    sub, backups = {}, set()
    prefix = root.rstrip("/") + "/"
    for man in manifests:
        with gzip.open(man, "rt", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) != 4 or parts[0] != "f":
                    continue
                size, mtime, path = int(parts[1]), parts[2][:16], parts[3]   # display to the minute
                acc["files"] += 1
                acc["bytes"] += size
                acc["oldest"] = mtime if acc["oldest"] is None else min(acc["oldest"], mtime)
                acc["newest"] = mtime if acc["newest"] is None else max(acc["newest"], mtime)
                base = path.rsplit("/", 1)[-1]
                ext = base.rsplit(".", 1)[-1].lower() if "." in base.lstrip(".") else "(none)"
                ext_n[ext] += 1
                ext_b[ext] += size
                if base in MARKERS:
                    markers[base] += 1
                elif ext == "npz":
                    markers["*.npz"] += 1
                rel = path[len(prefix):] if path.startswith(prefix) else path
                dirs = rel.split("/")[:-1]
                key = "/".join(dirs[:2]) if dirs else "."
                entry = sub.setdefault(key, [0, 0, ""])
                entry[0] += 1
                entry[1] += size
                entry[2] = max(entry[2], mtime)
                for i, name in enumerate(dirs):
                    if BACKUP.search(name):
                        backups.add("/".join(dirs[: i + 1]))
                        break
    top = sorted(sub.items(), key=lambda kv: -kv[1][1])[:top_n]
    acc.update({
        "extensions": [[e, ext_n[e], ext_b[e]] for e, _ in ext_b.most_common(8)],
        "subfolders": [[k, v[0], v[1], v[2]] for k, v in top],
        "n_subfolders": len(sub),
        "markers": dict(markers),
        "backup_folders": sorted(backups)[:20],
    })
    return acc


def main(argv):
    if len(argv) < 2 or not os.path.isdir(argv[1]):
        sys.stderr.write(__doc__)
        return 2
    meta = argv[1]
    stamp = argv[argv.index("--stamp") + 1] if "--stamp" in argv else os.path.basename(os.path.dirname(os.path.abspath(meta)))
    rdir, mdir = os.path.join(meta, "receipts"), os.path.join(meta, "manifests")

    rec = collections.defaultdict(dict)                       # (stem, tier) -> {kind: kv}
    for name in sorted(os.listdir(rdir)) if os.path.isdir(rdir) else []:
        base, _, kind = name.rpartition(".")
        stem, _, tier = base.rpartition(".")
        if kind in KINDS and tier in TIERS:
            rec[(stem, tier)][kind] = read_kv(os.path.join(rdir, name))

    units = collections.OrderedDict()
    for (stem, tier), kinds in sorted(rec.items()):
        u = units.setdefault(stem, {"stem": stem, "unit": None, "mode": None, "root": None, "tiers": {}})
        info = kinds.get("packed") or kinds.get("empty") or {}
        u["unit"] = u["unit"] or info.get("unit")
        u["mode"] = u["mode"] or info.get("mode")
        u["root"] = u["root"] or info.get("root")
        p = kinds.get("packed")
        if p:
            u["tiers"][tier] = {
                "archive": p.get("archive"), "files": int(p.get("files") or 0),
                "raw_bytes": int(p.get("raw_bytes") or 0), "arc_bytes": int(p.get("arc_bytes") or 0),
                "sha256": p.get("sha256"), "tar_rc": p.get("tar_rc"), "packed_at": p.get("packed_at"),
                "pulled": "pulled" in kinds, "gdrive": (kinds.get("gdrive") or {}).get("remote"),
            }
        elif "empty" in kinds:
            u["tiers"][tier] = None

    for stem, u in units.items():
        mans = [os.path.join(mdir, "%s.%s.tsv.gz" % (stem, t)) for t in TIERS if u["tiers"].get(t)]
        mans = [m for m in mans if os.path.exists(m)]
        u["scan"] = scan(mans, u["root"] or "logs") if mans else None

    packed = [(u, t, v) for u in units.values() for t, v in u["tiers"].items() if v]
    with open(os.path.join(meta, "SHA256SUMS"), "w") as fh:
        for _, _, v in sorted(packed, key=lambda x: x[2]["archive"]):
            fh.write("%s  %s\n" % (v["sha256"], v["archive"]))
    with open(os.path.join(meta, "units.tsv"), "w") as fh:
        fh.write("unit\tmode\tstem\ttier\tstatus\tfiles\traw_bytes\tarc_bytes\tsha256\tarchive\n")
        for u in units.values():
            for t in TIERS:
                if t not in u["tiers"]:
                    continue
                v = u["tiers"][t]
                if v is None:
                    fh.write("%s\t%s\t%s\t%s\tempty\t0\t0\t0\t\t\n" % (u["unit"], u["mode"], u["stem"], t))
                    continue
                status = "+".join(["packed"] + (["pulled"] if v["pulled"] else []) + (["gdrive"] if v["gdrive"] else []))
                fh.write("%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%s\t%s\n" % (u["unit"], u["mode"], u["stem"], t, status,
                         v["files"], v["raw_bytes"], v["arc_bytes"], v["sha256"], v["archive"]))

    now = datetime.datetime.now().isoformat(timespec="seconds")
    tot_files = sum(v["files"] for _, _, v in packed)
    tot_raw = sum(v["raw_bytes"] for _, _, v in packed)
    tot_arc = sum(v["arc_bytes"] for _, _, v in packed)
    dates = [u["scan"][k] for u in units.values() if u["scan"] for k in ("oldest", "newest") if u["scan"][k]]
    with open(os.path.join(meta, "SUMMARY.json"), "w") as fh:
        json.dump({"stamp": stamp, "generated": now, "units": list(units.values()),
                   "totals": {"units": len(units), "archives": len(packed), "files": tot_files,
                              "raw_bytes": tot_raw, "arc_bytes": tot_arc}}, fh, indent=1)

    md = ["# Log archive `%s` - machine summary" % stamp, "",
          "Generated %s by `logarch_summarize.py` from `meta/receipts` + `meta/manifests`. raw = bytes on disk before "
          "packing, archive = `.tar.zst` bytes, ratio = archive / raw. This file is the input of the catalog step "
          "(`README.md`, `units/*.md`); it states sizes, not meaning." % now, "",
          "**Totals:** %d units · %d archives · %d files · raw %s → archive %s (x%.2f) · %s → %s" % (
              len(units), len(packed), tot_files, human(tot_raw), human(tot_arc),
              (tot_arc / tot_raw) if tot_raw else 0, min(dates) if dates else "-", max(dates) if dates else "-"), "",
          "| # | unit | archives (size) | files | raw | archive | ratio | oldest → newest | flags |",
          "|---:|---|---|---:|---:|---:|---:|---|---|"]
    for i, u in enumerate(units.values(), 1):
        live = [(t, v) for t, v in u["tiers"].items() if v]
        raw = sum(v["raw_bytes"] for _, v in live)
        arc = sum(v["arc_bytes"] for _, v in live)
        flags = []
        if any(v["tar_rc"] == "1" for _, v in live):
            flags.append("changed-while-packing")
        if live and all(v["pulled"] for _, v in live):
            flags.append("pulled")
        if live and all(v["gdrive"] for _, v in live):
            flags.append("on-drive")
        if u["scan"] and u["scan"]["backup_folders"]:
            flags.append("has-backup-folders")
        sc = u["scan"] or {}
        md.append("| %d | `%s` | %s | %d | %s | %s | %s | %s → %s | %s |" % (
            i, u["unit"], " · ".join("%s %s" % (t, human(v["arc_bytes"])) for t, v in live) or "(empty)",
            sum(v["files"] for _, v in live), human(raw), human(arc), ("%.2f" % (arc / raw)) if raw else "-",
            sc.get("oldest") or "-", sc.get("newest") or "-", ", ".join(flags)))
    for u in units.values():
        sc = u["scan"]
        live = [(t, v) for t, v in u["tiers"].items() if v]
        md += ["", "## `%s`" % u["unit"], ""]
        for t, v in live:
            md.append("- `%s` - %d files, %s → %s, sha256 `%s`" % (v["archive"], v["files"], human(v["raw_bytes"]),
                                                                  human(v["arc_bytes"]), (v["sha256"] or "")[:16]))
        if not sc:
            continue
        if sc["markers"]:
            md.append("- markers: " + " · ".join("%s ×%d" % kv for kv in sorted(sc["markers"].items())))
        if sc["backup_folders"]:
            md.append("- backup-style folders: " + ", ".join("`%s`" % b for b in sc["backup_folders"]))
        md.append("- by extension: " + " · ".join("%s %s (%d)" % (e, human(b), n) for e, n, b in sc["extensions"]))
        md += ["", "| sub-folder (≤ 2 levels, top %d of %d by size) | files | size | newest |" % (
            len(sc["subfolders"]), sc["n_subfolders"]), "|---|---:|---:|---|"]
        md += ["| `%s` | %d | %s | %s |" % (k, n, human(b), t) for k, n, b, t in sc["subfolders"]]
    with open(os.path.join(meta, "SUMMARY.md"), "w") as fh:
        fh.write("\n".join(md) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
