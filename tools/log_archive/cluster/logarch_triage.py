#!/usr/bin/env python3
"""logarch_triage.py - find the runs in a raw log archive, label them with evidence, plan the curated layer.

usage
  logarch_triage.py scan <bundle> [--repo DIR] [--rules FILE]
  logarch_triage.py set  <bundle> --match GLOB [--match GLOB ...] [--include yes|no] [--group NAME] [--note TEXT]
  logarch_triage.py plan <bundle> [--repo DIR] [--rules FILE]

<bundle>  local folder of one STAMP holding raw/meta/{receipts,manifests} (logarch_local.sh fetch-meta / pull-rolling)
scan  →  triage/TRIAGE.tsv   one row per run (or loose-file group): label, evidence, include yes/no  (the thing you edit)
         triage/TRIAGE.md    the same, summarised for review
set   →  edits TRIAGE.tsv rows whose path matches GLOB (path under logs/, '*' crosses '/'), logged in triage/EDITS.log
plan  →  triage/CURATE_PLAN.tsv.gz + .sha256   exactly the files logarch_curate.sh packs / uploads (include = yes only)
         cards/<dest>/README.md                one card per curated folder
         catalog/INDEX_auto.md                 index of the curated tree
Reads manifests, writes text: never touches an archive, the cluster or Drive. Stdlib only, Python >= 3.6.
"""
import argparse
import collections
import datetime
import fnmatch
import gzip
import hashlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_RULES = os.path.join(HERE, "logarch_triage_rules.tsv")
DEFAULT_REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

FILE_MARKERS = {"seeds_config.json", "losses.pkl", "losses.json", "state_best.pt", "args.json",
                "trainer_config.json", "results.json", "run_config.csv"}
RENDER_EXT = {"gif", "mp4"}
PERIODIC = re.compile(r"^state_\d+\.pt$")
KEY_EXT = {"json", "csv", "yaml", "yml", "md", "txt", "png", "svg"}
KEY_MAX_BYTES = 2 * 1024 * 1024
KEY_MAX_N = 40
KEY_SKIP = re.compile(r"(^|/)(diagnostics|results|config_snapshot[^/]*)/|(^|/)rollout_|_\d+_stats\.json$|(^|/)snapshot_")
KEY_FIRST = re.compile(r"(^|/)(seeds_config\.json|[a-z]+_config\.json|losses\.json|results\.json|run_config\.csv|"
                       r"args\.json|readme[^/]*|[^/]*summary[^/]*)$", re.I)
GENERIC = {"plans", "results", "all_seeds", "plots", "diagnostics", "gifs", "logs"}
TAG_STOP = re.compile(r"^(T\d.*|K\d+|EP.*|mpc\d+|aw\d+|bs\d+|dp[\d.]+|as\d+|ae[\d.]+|\d+[a-z]?|H\d+|9D|6D)$")
TEXT_EXT = {".md", ".tex", ".py", ".json", ".csv", ".txt", ".yaml", ".yml", ".sh", ".tsv"}
CORPORA = (("thesis", "Data_Analysis/DA_in_Paper"), ("thesis", "logs_in_develop/Writing"),
           ("devlog", "logs_in_develop"), ("devlog", "Slurm_Codes/archived_temp_bash"))
SKIP_DIRS = {".git", "__pycache__", "Obsidian_knowledge_vault", "Log_Archive_Export", "node_modules"}
COLS = ["run_id", "include", "label", "flags", "group", "kind", "path", "files", "raw_bytes", "curated_bytes",
        "dropped_bytes", "key_files", "seeds", "newest", "evidence"]


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
                k, v = line.rstrip("\n").split("=", 1)
                out[k] = v
    return out


def run_id(path):
    return hashlib.sha1(path.encode("utf-8")).hexdigest()[:12]


def under_logs(path):
    return path[5:] if path.startswith("logs/") else ("" if path == "logs" else path)


def load_rules(path):
    rules = collections.defaultdict(list)
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = re.split(r"\t+| {2,}", line.strip(), maxsplit=3)
            if len(parts) < 3:
                sys.exit("bad rule line: %r" % line)
            kind, pat, val = parts[0], parts[1], parts[2]
            rules[kind].append((pat, val, parts[3] if len(parts) > 3 else ""))
    return rules


def first_match(rules, kind, rel):
    for pat, val, ev in rules.get(kind, []):
        if fnmatch.fnmatchcase(rel, pat):
            return val, ev
    return None


def snapshot_hit(rules, rel):
    for comp in rel.split("/"):
        low = comp.lower()
        for tok, val, ev in rules.get("snapshot", []):
            if ("(" + tok) in low or ("_" + tok) in low:
                return "%s: '%s'" % (val, comp), ev
    return None


# ── bundle + grouping ─────────────────────────────────────────────────────────
def load_bundle(bundle):
    meta = os.path.join(bundle, "raw", "meta")
    rdir, mdir = os.path.join(meta, "receipts"), os.path.join(meta, "manifests")
    if not os.path.isdir(rdir) or not os.path.isdir(mdir):
        sys.exit("no %s/{receipts,manifests} - run `logarch_local.sh fetch-meta <STAMP>` first" % meta)
    units = {}
    for name in os.listdir(rdir):
        base, _, kind = name.rpartition(".")
        if kind in ("packed", "empty"):
            stem = base.rpartition(".")[0]
            kv = read_kv(os.path.join(rdir, name))
            units[stem] = (kv.get("unit"), kv.get("mode"), kv.get("root"))
    files = []
    for name in sorted(os.listdir(mdir)):
        if not name.endswith(".tsv.gz"):
            continue
        stem, _, tier = name[:-7].rpartition(".")
        unit, mode, root = units.get(stem, (None, None, None))
        if root is None:
            sys.exit("manifest %s has no receipt" % name)
        with gzip.open(os.path.join(mdir, name), "rt", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                p = line.rstrip("\n").split("\t")
                if len(p) == 4:
                    files.append({"type": p[0], "size": int(p[1]), "mtime": p[2], "path": p[3], "tier": tier,
                                  "stem": stem, "mode": mode, "root": root})
    return units, files


def chain(d, stop):
    out = [d]
    while d != stop and d.startswith(stop + "/"):
        d = d.rsplit("/", 1)[0]
        out.append(d)
    return out


def group_files(files):
    """Runs = topmost folders holding run markers (a numbered seed folder promotes its parent); rest = loose groups."""
    marked = {}
    for f in files:
        if f["mode"] != "tree":
            continue
        d, _, base = f["path"].rpartition("/")
        root = f["root"]
        if f["type"] == "f" and base in FILE_MARKERS:
            marked[d] = root
        rel = d[len(root) + 1:] if d.startswith(root + "/") else ""
        comps = rel.split("/") if rel else []
        for i, c in enumerate(comps):
            if c == "results" or c.startswith("config_snapshot"):
                marked[root + ("/" + "/".join(comps[:i]) if i else "")] = root
                break
    for d, root in list(marked.items()):
        if d != root and d.rsplit("/", 1)[-1].isdigit():
            parent = d.rsplit("/", 1)[0]
            if parent == root or parent.startswith(root + "/"):
                marked[parent] = root
    roots = set()
    for d in sorted(marked, key=lambda x: x.count("/")):
        if not any(a in roots for a in chain(d, marked[d])):
            roots.add(d)
    groups = collections.OrderedDict()
    for f in sorted(files, key=lambda x: x["path"]):
        d = f["path"].rpartition("/")[0]          # an empty dir goes with its parent folder
        key, kind = None, "loose"
        if f["mode"] == "tree":
            for a in chain(d, f["root"]):
                if a in roots:
                    key, kind = a, "run"
                    break
        if key is None:
            if f["mode"] == "loose":
                key = f["root"]
            else:
                rel = d[len(f["root"]) + 1:] if d.startswith(f["root"] + "/") else ""
                comps = rel.split("/") if rel else []
                key = f["root"] + ("/" + "/".join(comps[:2]) if comps else "")
        g = groups.setdefault(key, {"path": key, "kind": kind, "files": []})
        g["files"].append(f)
    return groups


def split_files(g, rules):
    """→ (pack, dropped, key) for the curated layer."""
    best_dirs = {f["path"].rpartition("/")[0] for f in g["files"] if f["path"].endswith("/state_best.pt")}
    pack, dropped = [], []
    for f in g["files"]:
        base = f["path"].rsplit("/", 1)[-1]
        ext = base.rsplit(".", 1)[-1].lower() if "." in base else ""
        rel = under_logs(f["path"])
        if f["type"] == "f" and ext in RENDER_EXT and not first_match(rules, "keep_render", rel):
            dropped.append((f, "render"))
        elif f["type"] == "f" and PERIODIC.match(base) and f["path"].rpartition("/")[0] in best_dirs:
            dropped.append((f, "periodic checkpoint"))
        else:
            pack.append(f)
    prefix = g["path"] + "/"
    cands = []
    for f in pack:
        if f["type"] != "f" or f["size"] > KEY_MAX_BYTES:
            continue
        rel = f["path"][len(prefix):] if f["path"].startswith(prefix) else f["path"].rsplit("/", 1)[-1]
        ext = rel.rsplit(".", 1)[-1].lower() if "." in rel else ""
        if ext in KEY_EXT and not KEY_SKIP.search(rel):
            cands.append((0 if KEY_FIRST.search(rel) else 1, rel.count("/"), rel, f))
    key = [c[3] for c in sorted(cands, key=lambda c: c[:3])[:KEY_MAX_N]]
    return pack, dropped, key


# ── evidence: who cites a run ─────────────────────────────────────────────────
def candidate_keys(path):
    comps = path.split("/")
    name = comps[-1]
    pair = None
    if len(comps) >= 2 and name not in GENERIC and not name.isdigit():
        pair = (comps[-2], name)
    elif len(comps) >= 3:
        pair = (comps[-3], comps[-2])
    tag = None
    m = re.search(r"_msg([A-Za-z0-9]+)$", name)
    if m:
        tag = "msg" + m.group(1)
    elif re.match(r"^E[a-z]+_K\d+_", name):
        last = name.rsplit("_", 1)[-1]
        if re.search(r"\d", last) and re.search(r"[A-Za-z]", last) and not TAG_STOP.match(last) and len(last) >= 3:
            tag = last
    return pair, tag


def scan_corpus(repo, pairs_wanted, tags_wanted):
    hits_pair = collections.defaultdict(list)
    hits_tag = collections.defaultdict(list)
    seen = set()
    pathtok = re.compile(r"[A-Za-z0-9_.()+=\-]+(?:/[A-Za-z0-9_.()+=\-]+)+")
    wordtok = re.compile(r"[A-Za-z0-9]+")
    for kind, base in CORPORA:
        top = os.path.join(repo, base)
        for dirpath, dirnames, filenames in os.walk(top):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
            for fn in filenames:
                full = os.path.join(dirpath, fn)
                if full in seen or os.path.splitext(fn)[1].lower() not in TEXT_EXT:
                    continue
                seen.add(full)
                try:
                    if os.path.getsize(full) > 5 * 1024 * 1024:
                        continue
                    with open(full, encoding="utf-8", errors="ignore") as fh:
                        text = fh.read()
                except OSError:
                    continue
                rel = os.path.relpath(full, repo)
                for m in pathtok.finditer(text):
                    segs = m.group(0).split("/")
                    for pr in zip(segs, segs[1:]):
                        if pr in pairs_wanted and len(hits_pair[pr]) < 3 and (kind, rel) not in hits_pair[pr]:
                            hits_pair[pr].append((kind, rel))
                if tags_wanted:
                    for w in set(wordtok.findall(text)) & tags_wanted:
                        if len(hits_tag[w]) < 3:
                            hits_tag[w].append((kind, rel))
    return hits_pair, hits_tag


# ── scan ──────────────────────────────────────────────────────────────────────
def cmd_scan(a):
    rules = load_rules(a.rules)
    units, files = load_bundle(a.bundle)
    groups = group_files(files)
    keys = {p: candidate_keys(p) for p, g in groups.items() if g["kind"] == "run"}
    pairs_wanted = {k[0] for k in keys.values() if k[0]}
    tags_wanted = {k[1] for k in keys.values() if k[1]}
    hits_pair, hits_tag = scan_corpus(a.repo, pairs_wanted, tags_wanted) if os.path.isdir(a.repo) else ({}, {})
    rows = []
    for path, g in groups.items():
        rel = under_logs(path)
        pack, dropped, key = split_files(g, rules)
        fs = [f for f in g["files"] if f["type"] == "f"]
        names = {f["path"].rsplit("/", 1)[-1] for f in fs}
        flags, ev = [], []
        snap = snapshot_hit(rules, rel)
        aband = first_match(rules, "abandoned", rel)
        grp = first_match(rules, "group", rel) or ("unmapped", "")
        pair, tag = keys.get(path, (None, None))
        th = [h for h in hits_pair.get(pair, []) if h[0] == "thesis"] if pair else []
        dv = [h for h in hits_pair.get(pair, []) if h[0] == "devlog"] if pair else []
        tg = hits_tag.get(tag, []) if tag else []
        tth = [h for h in tg if h[0] == "thesis"]           # a wave tag cited by the thesis data store counts as thesis
        if snap:
            label = "snapshot"; ev.append("%s [%s]" % snap)
        elif aband:
            label = "abandoned"; ev.append("%s [%s]" % aband)
        elif g["kind"] == "loose":
            label = "loose"
        elif th or tth:
            label = "thesis"
        elif dv or tg:
            label = "referenced"
        else:
            label = "unreferenced"
        if th or tth:
            flags.append("thesis-cited")
        if th:
            ev.append("cited: " + ", ".join(h[1] for h in th))
        if dv:
            ev.append("dev log: " + ", ".join(h[1] for h in dv))
        if tg:
            flags.append("tag:" + tag); ev.append("tag %s: %s" % (tag, ", ".join(h[1] for h in tg)))
        if names & {"state_best.pt", "losses.pkl", "losses.json"}:
            flags.append("training")
        if names & {"results.json"} or any("/results/" in f["path"] for f in fs):
            flags.append("eval")
        if any(r == "render" for _, r in dropped):
            flags.append("renders-dropped")
        if any(r == "periodic checkpoint" for _, r in dropped):
            flags.append("periodic-ckpt-dropped")
        include = "no" if label in ("snapshot", "abandoned") and not (th or tth) else "yes"
        prefix = path + "/"
        seeds = sorted({f["path"][len(prefix):].split("/", 1)[0] for f in g["files"]
                        if f["path"].startswith(prefix) and f["path"][len(prefix):].split("/", 1)[0].isdigit()
                        and "/" in f["path"][len(prefix):]}, key=int)
        rows.append({"run_id": run_id(path), "include": include, "label": label, "flags": ",".join(flags),
                     "group": grp[0], "kind": g["kind"], "path": path, "files": str(len(fs)),
                     "raw_bytes": str(sum(f["size"] for f in fs)),
                     "curated_bytes": str(sum(f["size"] for f in pack if f["type"] == "f")),
                     "dropped_bytes": str(sum(f["size"] for f, _ in dropped)), "key_files": str(len(key)),
                     "seeds": " ".join(seeds), "newest": max((f["mtime"] for f in fs), default="-")[:16],
                     "evidence": " | ".join(ev).replace("\t", " ")})
    out = os.path.join(a.bundle, "triage")
    os.makedirs(out, exist_ok=True)
    write_tsv(os.path.join(out, "TRIAGE.tsv"), rows)
    write_triage_md(os.path.join(out, "TRIAGE.md"), rows, a.bundle)
    print("[triage] %d groups (%d runs) → %s/TRIAGE.tsv + TRIAGE.md" % (
        len(rows), sum(r["kind"] == "run" for r in rows), out))
    return 0


def write_tsv(path, rows):
    with open(path + ".tmp", "w", encoding="utf-8") as fh:
        fh.write("\t".join(COLS) + "\n")
        for r in rows:
            fh.write("\t".join(str(r.get(c, "")) for c in COLS) + "\n")
    os.replace(path + ".tmp", path)


def read_tsv(path):
    with open(path, encoding="utf-8") as fh:
        head = fh.readline().rstrip("\n").split("\t")
        if head != COLS:
            sys.exit("%s: unexpected header - re-run scan" % path)
        return [dict(zip(COLS, line.rstrip("\n").split("\t"))) for line in fh if line.strip()]


def write_triage_md(path, rows, bundle):
    tot = lambda rs, k: sum(int(r[k]) for r in rs)
    inc = [r for r in rows if r["include"] == "yes"]
    exc = [r for r in rows if r["include"] != "yes"]
    md = ["# TRIAGE - `%s`" % os.path.basename(os.path.abspath(bundle)), "",
          "Generated %s by `logarch_triage.py scan` from the raw-layer manifests. One row per run folder (topmost folder "
          "holding run files; numbered seed folders belong to their parent) or per group of loose files. **Nothing is "
          "deleted by this list**: `include = no` only keeps a row out of `curated/`; every file stays in `raw/`. Renders "
          "(gif/mp4) and superseded `state_<N>.pt` are left out of `curated/` archives but also stay in `raw/`." %
          datetime.datetime.now().isoformat(timespec="seconds"), "",
          "**Totals:** %d rows · include %d (%s raw → %s in curated) · exclude %d (%s)" % (
              len(rows), len(inc), human(tot(inc, "raw_bytes")), human(tot(inc, "curated_bytes")), len(exc),
              human(tot(exc, "raw_bytes"))), "",
          "Change a decision: `logarch_local.sh set <STAMP> --match '<glob under logs/>' --include yes|no` "
          "(or edit `include` in TRIAGE.tsv), then `logarch_local.sh plan-curate <STAMP>`.", "",
          "## By label", "", "| label | rows | include | raw | curated | meaning |", "|---|---:|---:|---:|---:|---|"]
    meaning = {"thesis": "cited in DA_in_Paper / Writing", "referenced": "named in a dev log, runbook or driver",
               "unreferenced": "run files, nothing cites it", "loose": "files outside any run folder",
               "snapshot": "backup / before-fix / smoke copy", "abandoned": "line given up (MASTER_TEST_HISTORY)"}
    for lab in ("thesis", "referenced", "unreferenced", "loose", "snapshot", "abandoned"):
        rs = [r for r in rows if r["label"] == lab]
        if rs:
            md.append("| %s | %d | %d | %s | %s | %s |" % (lab, len(rs), sum(r["include"] == "yes" for r in rs),
                      human(tot(rs, "raw_bytes")), human(tot([r for r in rs if r["include"] == "yes"], "curated_bytes")),
                      meaning[lab]))
    md += ["", "## By group (curated/<group>/…)", "", "| group | rows | include | raw | curated |", "|---|---:|---:|---:|---:|"]
    for grp in sorted({r["group"] for r in rows}):
        rs = [r for r in rows if r["group"] == grp]
        md.append("| %s | %d | %d | %s | %s |" % (grp, len(rs), sum(r["include"] == "yes" for r in rs),
                  human(tot(rs, "raw_bytes")), human(tot([r for r in rs if r["include"] == "yes"], "curated_bytes"))))
    md += ["", "## Excluded from curated (largest first)", "", "| path | label | raw | evidence |", "|---|---|---:|---|"]
    for r in sorted(exc, key=lambda r: -int(r["raw_bytes"]))[:200]:
        md.append("| `%s` | %s | %s | %s |" % (r["path"], r["label"], human(r["raw_bytes"]), r["evidence"] or "-"))
    md += ["", "## Included (largest first, first 300)", "",
           "| path | label | group | files | curated | flags |", "|---|---|---|---:|---:|---|"]
    for r in sorted(inc, key=lambda r: -int(r["curated_bytes"]))[:300]:
        md.append("| `%s` | %s | %s | %s | %s | %s |" % (r["path"], r["label"], r["group"], r["files"],
                  human(r["curated_bytes"]), r["flags"] or "-"))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(md) + "\n")


# ── set ───────────────────────────────────────────────────────────────────────
def cmd_set(a):
    if a.include is None and a.group is None:
        sys.exit("set: give --include yes|no and/or --group NAME")
    tsv = os.path.join(a.bundle, "triage", "TRIAGE.tsv")
    rows = read_tsv(tsv)
    n = 0
    for r in rows:
        rel = under_logs(r["path"])
        if any(fnmatch.fnmatchcase(rel, m) or fnmatch.fnmatchcase(r["path"], m) for m in a.match):
            if a.include is not None:
                r["include"] = a.include
            if a.group is not None:
                r["group"] = a.group
            n += 1
    write_tsv(tsv, rows)
    with open(os.path.join(a.bundle, "triage", "EDITS.log"), "a", encoding="utf-8") as fh:
        fh.write("%s\tmatch=%s\tinclude=%s\tgroup=%s\trows=%d\tnote=%s\n" % (
            datetime.datetime.now().isoformat(timespec="seconds"), " ".join(a.match), a.include, a.group, n, a.note or ""))
    write_triage_md(os.path.join(a.bundle, "triage", "TRIAGE.md"), rows, a.bundle)
    print("[set] %d row(s) changed" % n)
    return 0 if n else 1


# ── plan ──────────────────────────────────────────────────────────────────────
def cmd_plan(a):
    rules = load_rules(a.rules)
    rows = {r["run_id"]: r for r in read_tsv(os.path.join(a.bundle, "triage", "TRIAGE.tsv"))}
    units, files = load_bundle(a.bundle)
    groups = group_files(files)
    stem_of = {}
    lines, index, n_pack, n_key, bytes_pack = [], [], 0, 0, 0
    cards = os.path.join(a.bundle, "cards")
    for path, g in groups.items():
        rid = run_id(path)
        r = rows.get(rid)
        if r is None:
            sys.exit("TRIAGE.tsv does not know %s - the manifests changed; re-run scan" % path)
        if r["include"] != "yes":
            continue
        rel = under_logs(path) or "_toplevel_files"
        dest = "%s/%s" % (r["group"], rel)
        pack, dropped, key = split_files(g, rules)
        lines.append((rid, 0, "%s\troot\t-\t-\t%s\t%s" % (rid, path, dest)))
        for f in pack:
            lines.append((rid, 1, "%s\tpack\t%s\t%d\t%s\t-" % (rid, f["type"], f["size"], f["path"])))
        for f in key:
            lines.append((rid, 2, "%s\tkey\tf\t%d\t%s\t-" % (rid, f["size"], f["path"])))
        n_pack += len(pack); n_key += len(key); bytes_pack += sum(f["size"] for f in pack if f["type"] == "f")
        stems = sorted({"%s.%s.tar.zst" % (f["stem"], f["tier"]) for f in g["files"]})
        write_card(os.path.join(cards, dest, "README.md"), r, g, pack, dropped, key, dest, stems)
        index.append((r["group"], rel, r, dest))
    out = os.path.join(a.bundle, "triage")
    plan = os.path.join(out, "CURATE_PLAN.tsv.gz")
    with gzip.open(plan + ".tmp", "wt", encoding="utf-8") as fh:
        fh.write("#run_id\tkind\ttype\tsize\tpath\tdest\n")
        for _, _, line in sorted(lines, key=lambda x: (x[0], x[1])):
            fh.write(line + "\n")
    os.replace(plan + ".tmp", plan)
    digest = hashlib.sha256(open(plan, "rb").read()).hexdigest()
    with open(os.path.join(out, "CURATE_PLAN.sha256"), "w") as fh:
        fh.write("%s  CURATE_PLAN.tsv.gz\n" % digest)
    write_index(os.path.join(a.bundle, "catalog", "INDEX_auto.md"), index, a.bundle)
    print("[plan] %d curated folders · %d files into run archives (%s raw) · %d key files as plain files → %s" % (
        len(index), n_pack, human(bytes_pack), n_key, plan))
    return 0


def write_card(path, r, g, pack, dropped, key, dest, stems):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fs = [f for f in g["files"] if f["type"] == "f"]
    drop_n = collections.Counter(why for _, why in dropped)
    drop_b = collections.Counter()
    for f, why in dropped:
        drop_b[why] += f["size"]
    md = ["# `%s`" % r["path"], "",
          "| | |", "|---|---|",
          "| group | %s |" % r["group"], "| label | %s%s |" % (r["label"], (" · " + r["flags"]) if r["flags"] else ""),
          "| evidence | %s |" % (r["evidence"] or "-"),
          "| kind | %s%s |" % (r["kind"], (" · seeds " + r["seeds"]) if r["seeds"] else ""),
          "| files | %d (%s), newest %s |" % (len(fs), human(sum(f["size"] for f in fs)), r["newest"]),
          "| `run_archive.tar.zst` | %d entries, %s before compression |" % (
              len(pack), human(sum(f["size"] for f in pack if f["type"] == "f"))),
          "| left out of curated | %s |" % (" · ".join("%s ×%d (%s)" % (w, drop_n[w], human(drop_b[w])) for w in drop_n)
                                            or "nothing"),
          "| full original | `raw/archives/%s` |" % ("`, `raw/archives/".join(stems)), "",
          "Restore this folder in place (repo root):", "",
          "```", "zstd -dc run_archive.tar.zst | tar -xf - -C /path/to/FM-PCC", "```", ""]
    if key:
        md += ["Key files here (plain copies, also inside the archive):", ""]
        md += ["- `%s`" % f["path"][len(r["path"]) + 1:] for f in key]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(md) + "\n")


def write_index(path, index, bundle):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    md = ["# curated/ index - `%s` (auto)" % os.path.basename(os.path.abspath(bundle)), "",
          "Generated by `logarch_triage.py plan`. Every row is a folder under `curated/`; its `README.md` card says what "
          "is inside and where the full original lives in `raw/`.", ""]
    for grp in sorted({i[0] for i in index}):
        rs = [i for i in index if i[0] == grp]
        md += ["## %s" % grp, "", "| folder | label | files | curated | newest |", "|---|---|---:|---:|---|"]
        for _, rel, r, dest in sorted(rs, key=lambda x: x[1]):
            md.append("| `%s` | %s | %s | %s | %s |" % (dest, r["label"], r["files"], human(r["curated_bytes"]), r["newest"]))
        md.append("")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(md) + "\n")


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    for name in ("scan", "set", "plan"):
        p = sub.add_parser(name)
        p.add_argument("bundle")
        p.add_argument("--rules", default=DEFAULT_RULES)
        p.add_argument("--repo", default=DEFAULT_REPO)
        if name == "set":
            p.add_argument("--match", action="append", required=True)
            p.add_argument("--include", choices=("yes", "no"))
            p.add_argument("--group")
            p.add_argument("--note")
    a = ap.parse_args(argv[1:])
    if a.cmd is None:
        ap.print_help()
        return 2
    return {"scan": cmd_scan, "set": cmd_set, "plan": cmd_plan}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
