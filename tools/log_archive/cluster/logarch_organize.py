#!/usr/bin/env python3
"""logarch_organize.py - organize v2: curated = the thesis runs under clear names, raw = everything else (no duplicates).

usage
  logarch_organize.py plan  <bundle> --map naming_map.tsv   → triage/CURATE_PLAN.tsv.gz (+ .sha256) with renames, complete
                                                               folders (nothing dropped), key files; cards/<new>/README.md notes
  logarch_organize.py docs  <bundle> --map naming_map.tsv   → README.md (master), NAMING.md, RESTORE.md in <bundle>/
  logarch_organize.py check <bundle>                         → after logarch_raw_rebuild.sh: every archived file is now in
                                                               exactly one place (curated plan or raw); prints the swap list
<bundle> = local folder of one STAMP with raw/meta (fetch-meta), for check also raw_rebuilt/meta (logarch_local.sh finalize).
naming_map.tsv columns: new_path old_path section meaning internal_tags raw_bytes files (header line first).
Reads text, writes text. Stdlib only, Python >= 3.6.
"""
import argparse
import collections
import csv
import datetime
import gzip
import hashlib
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import logarch_triage as T   # noqa: E402  (bundle loading, run grouping, key-file choice)

CAVEAT_SNAPSHOT = ("`config_snapshot_*` folders: their **time stamps reliably record when the run last ran**; the yaml/py copies "
                   "inside may not match what actually ran — use them with caution.")


def read_map(path):
    with open(path, encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh, delimiter="\t"))
    new = [r["new_path"] for r in rows]
    if len(set(new)) != len(new):
        sys.exit("naming map: duplicate new_path")
    return rows


def human(n):
    return T.human(n)


def cmd_plan(a):
    rows = read_map(a.map)
    units, files = T.load_bundle(a.bundle)
    groups = T.group_files(files)
    rules = T.load_rules(T.DEFAULT_RULES)
    out = os.path.join(a.bundle, "triage")
    cards = os.path.join(a.bundle, "cards")
    os.makedirs(out, exist_ok=True)
    lines, n_pack, n_key, byts, missing = [], 0, 0, 0, []
    for r in rows:
        g = groups.get(r["old_path"])
        if g is None:
            missing.append(r["old_path"])
            continue
        rid = T.run_id(r["old_path"])
        _, _, key = T.split_files(g, rules)
        allf = g["files"]
        lines.append((rid, 0, "%s\troot\t-\t-\t%s\t%s\trename" % (rid, r["old_path"], r["new_path"])))
        for f in allf:
            lines.append((rid, 1, "%s\tpack\t%s\t%d\t%s\t-" % (rid, f["type"], f["size"], f["path"])))
        for f in key:
            lines.append((rid, 2, "%s\tkey\tf\t%d\t%s\t-" % (rid, f["size"], f["path"])))
        n_pack += len(allf); n_key += len(key); byts += sum(f["size"] for f in allf if f["type"] == "f")
        write_note(os.path.join(cards, r["new_path"], "README.md"), r, g, key)
    if missing:
        sys.exit("naming map rows without a run folder in the manifests:\n  " + "\n  ".join(missing[:20]))
    plan = os.path.join(out, "CURATE_PLAN.tsv.gz")
    with gzip.open(plan + ".tmp", "wt", encoding="utf-8") as fh:
        fh.write("#run_id\tkind\ttype\tsize\tpath\tdest\trename\n")
        for _, _, line in sorted(lines, key=lambda x: (x[0], x[1])):
            fh.write(line + "\n")
    os.replace(plan + ".tmp", plan)
    with open(os.path.join(out, "CURATE_PLAN.sha256"), "w") as fh:
        fh.write("%s  CURATE_PLAN.tsv.gz\n" % hashlib.sha256(open(plan, "rb").read()).hexdigest())
    print("[plan] %d curated folders · %d entries (%s) moved complete · %d key files as plain copies → %s" % (
        len(rows), n_pack, human(byts), n_key, plan))
    return 0


def write_note(path, r, g, key):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fs = [f for f in g["files"] if f["type"] == "f"]
    name = r["new_path"].rsplit("/", 1)[-1]
    kinds = collections.Counter()
    for f in fs:
        b = f["path"].rsplit("/", 1)[-1]
        ext = b.rsplit(".", 1)[-1].lower() if "." in b else "(none)"
        kinds[ext] += 1
    has_snap = any("/config_snapshot" in f["path"] for f in g["files"])
    md = ["# %s" % name, "",
          "%s" % r["meaning"][0].upper() + r["meaning"][1:] + ".", "",
          "| | |", "|---|---|",
          "| used in the thesis | %s |" % r["section"],
          "| files | %d (%s), newest %s |" % (len(fs), human(sum(f["size"] for f in fs)), max((f["mtime"][:16] for f in fs), default="-")),
          "| file types | %s |" % ", ".join("%s ×%d" % (e, n) for e, n in kinds.most_common(8)),
          "| original folder | `%s` |" % r["old_path"],
          "| internal tags (not needed to read the data) | %s |" % (r["internal_tags"] or "–"), "",
          "Everything of the run is in `%s.tar.zst` (unpacks into `%s/`, inner structure as originally written: seed folders, "
          "`results/`, `plots/`, …). Unpack: `zstd -dc %s.tar.zst | tar -xf -`." % (name, name, name), ""]
    if key:
        md += ["Plain copies of the small summary files (also inside the archive):", ""]
        md += ["- `%s`" % f["path"][len(r["old_path"]) + 1:] for f in key] + [""]
    if has_snap:
        md += ["Note: " + CAVEAT_SNAPSHOT, ""]
    md.append("What each file type holds, and what to ignore: see `README.md` at the top of this archive.")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(md) + "\n")


TOK = [("`D3IL-avoiding` · `D3IL-aligning` · `UAV-corridor` · `UAV-s-curve` · `UAV-pillars`", "the task, named as in the thesis"),
       ("`models/` · `evaluations/`", "training runs (weights, training curves, configs) · evaluation runs (results, plots, logs)"),
       ("`FM` · `MeanFM` · `CI-MeanFM` · `Diffusion`", "the generative model: flow matching · MeanFlow · consistency-interpolated MeanFlow · the diffusion baseline of DPCC"),
       ("`U-Net` · `SiT` · `DiT`", "network backbone"),
       ("`aend0.2`", "CI-MeanFM's interpolation end value $\\alpha_{\\mathrm{end}}$"),
       ("`trainedK20`", "a diffusion model trained for that step budget (DPCC trains one per budget)"),
       ("`K2`", "step budget: number of network evaluations per plan"),
       ("`thr0.5`", "activation threshold of the per-step projection"),
       ("`2ep` · `20ep`", "two / twenty evaluation episodes per training seed"),
       ("`per-step-vs-endpoint`", "the folder holds both projection arms: per-step (DPCC) and endpoint projection; its note gives both thresholds"),
       ("`geometric-ctrl` · `MJPC`", "quadrotor controller: cascaded geometric controller · MJPC"),
       ("`tilt` · `hump`", "UAV-corridor scene: the tilted corridor · the hump ablation"),
       ("`projection-rules`", "run under every candidate-selection rule"),
       ("`flown-avoiding-planner`", "the D3IL-avoiding planners flown by the quadrotor on UAV-pillars"),
       ("`latest-ckpt`", "evaluated with the latest checkpoint instead of the best one"),
       ("`launch-args`", "only the launch arguments of an evaluation; its results are in the neighbouring folder of the same K"),
       ("`replicate` · `endpoint-projection`", "a repeated run of the same configuration · the run behind the endpoint-projection row"),
       ("`seed6` · `seeds6-10`", "training seeds inside the folder (one sub-folder per seed)")]
DATA = [("`results/halfspace_<geometry>/<variant>.npz`", "D3IL-avoiding evaluation, one file per projection variant and obstacle geometry: per-episode arrays `n_success`, `n_success_and_constraints`, `n_violations`, `n_steps`, `avg_time` (seconds per step) and more. Variants: `diffuser` = no projection; `dpcc-r/-c/-t-tightened` = per-step projection with the random / cumulative-cost / temporal-consistency selection rule on the tightened constraints; `hardflow_sls-*` = endpoint projection"),
        ("`*.npz` (other tasks)", "NumPy archives with per-rollout metrics and trajectories — `numpy.load(path, allow_pickle=True)`, list `.files`"),
        ("`results.json`", "UAV evaluation summary per variant (flights, goal passed, collisions, steps, timing)"),
        ("`diagnostics/rollout_<i>_stats.json`", "per-flight timing and outcome (UAV); the timing axis of the UAV tables comes from these"),
        ("`plots/`, `all_seeds/`, `*.png`, `*.svg`, `*.csv`", "figures and seed-pooled summaries written by the evaluation"),
        ("`*.log`, `realtime_*.log`", "console output and per-step timing of the run"),
        ("`losses.json` / `losses.pkl`", "training curve"),
        ("`state_best.pt`, `state_<N>.pt`", "PyTorch weights: best checkpoint / periodic checkpoints"),
        ("`*_config.json` / `*_config.pkl`, `seeds_config.json`, `args.json`", "configuration of the training run / the evaluation launch"),
        ("`config_snapshot_*/`", "copy of the configuration at launch — " + CAVEAT_SNAPSHOT)]
IGNORE = [("`*.gif`, `*.mp4`", "visual renders of rollouts; no number in the thesis is computed from them"),
          ("`_clean_weights_runlogs/`, `_clean_gifs_runlogs/`", "audit logs of disk clean-ups"),
          ("`raw/meta/`, `curated/_meta/`, `triage/`", "bookkeeping of this archive (file lists, checksums, the plan) — needed only to verify or restore"),
          ("folders marked TEST below", "tests, before-fix copies and smoke runs"),
          ("folders marked ABANDONED / SUPERSEDED below", "lines of work the thesis dropped, and older runs replaced by the ones in `curated/`")]


def cmd_docs(a):
    rows = read_map(a.map)
    B = a.bundle; stamp = os.path.basename(os.path.abspath(B))
    tri = list(csv.DictReader(open(os.path.join(B, "triage", "TRIAGE.tsv"), encoding="utf-8"), delimiter="\t"))
    cur_old = {r["old_path"] for r in rows}
    test = [r for r in tri if r["label"] == "snapshot"]
    aband = [r for r in tri if r["label"] == "abandoned" and r["path"] not in cur_old]
    sup = [r for r in tri if r["kind"] == "run" and r["path"] not in cur_old and any(t in r["path"].rsplit("/", 1)[-1] for t in ("u17cv2", "u7hg", "u18sc"))]
    tasks = collections.OrderedDict()
    for r in rows:
        t, kind = r["new_path"].split("/")[:2]
        d = tasks.setdefault(t, collections.Counter()); d[kind] += 1; d["bytes"] += int(r["raw_bytes"])
    now = datetime.date.today().isoformat()
    md = ["# FM-PCC experiment logs — archive `%s`" % stamp, "",
          "The complete experiment log folder of the master's thesis *Flow Matching Predictive Control with Constraints* "
          "(release v5.31), archived %s from the training cluster. Every file is packed in `.tar.zst` archives "
          "(unpack: `zstd -dc X.tar.zst | tar -xf -`), checksummed, and exists exactly once in this archive." % now, "",
          "## Where to look", "",
          "- **`curated/`** — the data the thesis results come from: one folder per training run or evaluation, named in the thesis' "
          "words (`D3IL-avoiding/evaluations/MeanFM_K2_thr0.5_20ep_seeds6-10`). Each folder has a `README.md` note, plain copies of its "
          "small summary files, and one archive with everything else of the run. **Start here.**",
          "- **`raw/`** — everything else, packed per original folder and file type (`core` = results/logs/configs, `media` = images, "
          "`weights`): development runs, tests, abandoned and superseded work. Use it only if you need something the thesis did not use.",
          "- `NAMING.md` — every curated name, what it means and the original folder name · `RESTORE.md` — how to get data back.", "",
          "| task | training runs | evaluations | size before compression |", "|---|---:|---:|---:|"]
    md += ["| %s | %d | %d | %s |" % (t, d["models"], d["evaluations"], human(d["bytes"])) for t, d in tasks.items()]
    md += ["", "## Folder names", "", "| part of the name | meaning |", "|---|---|"] + ["| %s | %s |" % x for x in TOK]
    md += ["", "Example: `UAV-corridor/evaluations/FM_K3_thr0.5_geometric-ctrl_tilt_seed6` = flow matching, budget 3, activation "
           "threshold 0.5, flown with the cascaded geometric controller in the tilted corridor, training seed 6.", "",
           "## What the files hold", "", "| file | content |", "|---|---|"] + ["| %s | %s |" % x for x in DATA]
    md += ["", "## What to ignore", "", "| | why |", "|---|---|"] + ["| %s | %s |" % x for x in IGNORE]
    md += ["", "### TEST — not thesis data (kept in `raw/`)", "",
           "Test runs, before-fix copies and smoke runs; the name part in brackets says what it was (e.g. `Bf_U3` = before fix U3).", "",
           "| original folder | what it was |", "|---|---|"]
    md += ["| `%s` | %s |" % (r["path"][5:], r["evidence"].split(" [")[0] or "test copy") for r in sorted(test, key=lambda r: r["path"])]
    md += ["", "### ABANDONED — lines of work the thesis dropped (kept in `raw/`)", "", "| original folder | why |", "|---|---|"]
    md += ["| `%s` | %s |" % (r["path"][5:], r["evidence"].split(" [")[0]) for r in sorted(aband, key=lambda r: r["path"])]
    md += ["", "### SUPERSEDED — older runs replaced by the ones in `curated/` (kept in `raw/`)", "", "| original folder | replaced by |", "|---|---|"]
    rep = {"u17cv2": "UAV-corridor v3 (`tilt`, `hump`)", "u7hg": "UAV-pillars flown-avoiding-planner / UAV-s-curve runs", "u18sc": "UAV-s-curve runs"}
    md += ["| `%s` | %s |" % (r["path"][5:], next(v for k, v in rep.items() if k in r["path"].rsplit("/", 1)[-1])) for r in sorted(sup, key=lambda r: r["path"])]
    md += ["", "## How this archive was checked", "",
           "Each archive was written, hashed and decoded again in the same pass; file count and bytes had to equal a listing taken "
           "seconds before, and Google Drive's MD5 had to equal the uploaded stream. After the thesis folders moved to `curated/`, "
           "a check confirmed that every file of the original upload is in exactly one place. `raw/meta/CHANGES.md` compares the "
           "archive with the cluster folder at upload time."]
    open(os.path.join(B, "README.md"), "w", encoding="utf-8").write("\n".join(md) + "\n")
    nm = ["# NAMING — curated folder names (`%s`)" % stamp, "",
          "Legend: see `README.md` → *Folder names*. Old name = the folder under the original `logs/` on the cluster; "
          "internal tags are run labels used during the project and are not needed to read the data. Machine-readable: `naming_map.tsv`.", ""]
    for t in tasks:
        nm += ["## %s" % t, "", "| name | meaning | original folder | internal tags |", "|---|---|---|---|"]
        for r in sorted([r for r in rows if r["new_path"].startswith(t + "/")], key=lambda r: r["new_path"]):
            nm.append("| `%s` | %s | `%s` | %s |" % (r["new_path"][len(t) + 1:], r["meaning"], r["old_path"][5:], r["internal_tags"] or "–"))
        nm.append("")
    open(os.path.join(B, "NAMING.md"), "w", encoding="utf-8").write("\n".join(nm) + "\n")
    rs = ["# RESTORE — getting data back (`%s`)" % stamp, "", "Tools: `rclone` (configured for this Drive), `zstd`, `tar`.", "",
          "**One curated folder**", "", "```bash",
          "rclone copy gdrive:FMPCC_logs_backup/%s/curated/D3IL-avoiding/evaluations/MeanFM_K2_thr0.5_20ep_seeds6-10 ." % stamp,
          "zstd -dc MeanFM_K2_thr0.5_20ep_seeds6-10.tar.zst | tar -xf -        # → MeanFM_K2_thr0.5_20ep_seeds6-10/<seed>/…", "```", "",
          "**Something from `raw/`** — find it in the file lists first, then unpack only that part:", "", "```bash",
          "rclone copy gdrive:FMPCC_logs_backup/%s/raw/meta/manifests manifests/" % stamp,
          "zcat manifests/*.tsv.gz | grep 'plans(Bf_U3)' | head              # which archive holds it: <unit>.<tier>.tsv.gz",
          "rclone copy gdrive:FMPCC_logs_backup/%s/raw/archives/<unit>.<tier>.tar.zst ." % stamp,
          "zstd -dc <unit>.<tier>.tar.zst | tar -xf - --wildcards 'logs/<path>/*'   # raw archives keep the original logs/… paths", "```", "",
          "**Verify** a downloaded archive: `sha256sum -c` against `raw/meta/SHA256SUMS` (raw) or the `md5` in `curated/_meta/receipts` (curated).", "",
          "**Original layout for the analysis scripts** (they expect `logs/<original path>`): unpack the curated folders into one directory, then",
          "", "```bash", "tail -n +2 naming_map.tsv | while IFS=$'\\t' read -r new old _; do",
          "  n=${new##*/}; [ -d \"$n\" ] && mkdir -p \"$(dirname \"$old\")\" && mv \"$n\" \"$old\"", "done", "```"]
    open(os.path.join(B, "RESTORE.md"), "w", encoding="utf-8").write("\n".join(rs) + "\n")
    # ── short guides at every level a reader may land on (uploaded by publish-organized) ──
    G = os.path.join(B, "guides"); gs = os.path.join(G, "stamp")
    def put(rel, lines):
        p = os.path.join(gs if rel != "ROOT" else G, rel if rel != "ROOT" else "README.md")
        os.makedirs(os.path.dirname(p), exist_ok=True); open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    put("ROOT", ["# FMPCC_logs_backup", "", "Experiment logs of the master's thesis *Flow Matching Predictive Control with Constraints*.", "",
                 "- **`%s/`** — the complete archive of the cluster log folder (thesis release v5.31). **Open `%s/README.md` first.**" % (stamp, stamp),
                 "- any `smoke_*` or `_selftest*` folder — a small test copy made while setting up the archive; not data, safe to delete."])
    put("curated/README.md", ["# curated/ — the thesis data", "", "One folder per task; inside, `models/` (training runs) and `evaluations/`. Every run "
        "folder has a `README.md` note (what it is, where the thesis uses it, original name), plain copies of its small summary files, and "
        "`<name>.tar.zst` with everything of the run. Name legend and file types: `../README.md`; every name with its original folder: `../NAMING.md`.", "",
        "`_meta/` = checksums and receipts of the upload (only needed to verify).", "", "| task | training runs | evaluations |", "|---|---:|---:|"] +
        ["| [%s](%s/README.md) | %d | %d |" % (t, t, d["models"], d["evaluations"]) for t, d in tasks.items()])
    for t in tasks:
        tr = sorted([r for r in rows if r["new_path"].startswith(t + "/")], key=lambda r: r["new_path"])
        put("curated/%s/README.md" % t, ["# %s" % t, "", "Every folder of this task that the thesis uses. Each has its own `README.md`.", "",
            "| folder | what it is |", "|---|---|"] + ["| `%s` | %s |" % (r["new_path"][len(t) + 1:], r["meaning"]) for r in tr])
    put("raw/README.md", ["# raw/ — everything the thesis did not use", "",
        "The rest of the cluster log folder: development runs, tests, abandoned and superseded work (see the TEST / ABANDONED / SUPERSEDED "
        "lists in `../README.md`). The thesis data is in `../curated/`.", "",
        "- `archives/<folder>.<tier>.tar.zst` — one archive per original folder and file type: `core` (results, logs, configs, npz), "
        "`media` (images, renders), `weights` (model checkpoints). Inside, paths are the original `logs/…` paths.",
        "- `meta/manifests/<folder>.<tier>.tsv.gz` — every file of that archive (type, size, time, path): search here first, then unpack only what you need (`../RESTORE.md`).",
        "- `meta/SHA256SUMS` — checksums of the archives · `meta/SUMMARY.md` — sizes and dates per folder · `meta/CHANGES.md` — the archive compared with the cluster at upload time · `meta/receipts/`, `TREE_*` — bookkeeping."])
    put("triage/README.md", ["# triage/ — how the thesis data was selected", "",
        "Bookkeeping, not data. `TRIAGE.md` / `TRIAGE.tsv` = every run folder of the archive with a label (thesis, referenced, test, "
        "abandoned, …) and the evidence for it; `CURATE_PLAN.tsv.gz` (+ `.sha256`) = the exact list of files that moved to `../curated/`."])
    print("[docs] README.md (master: %d test, %d abandoned, %d superseded folders marked), NAMING.md (%d names), RESTORE.md → %s" % (
        len(test), len(aband), len(sup), len(rows), B))
    return 0


def load_manifest_dir(mdir):
    """→ {archive_id: set((type, path, size))}"""
    out = {}
    for name in os.listdir(mdir):
        if name.endswith(".tsv.gz"):
            s = set()
            with gzip.open(os.path.join(mdir, name), "rt", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    p = line.rstrip("\n").split("\t")
                    if len(p) == 4:
                        s.add((p[0], p[3], int(p[1])))
            out[name[:-7]] = s
    return out


def cmd_check(a):
    old = load_manifest_dir(os.path.join(a.bundle, "raw", "meta", "manifests"))
    new = load_manifest_dir(os.path.join(a.bundle, "raw_rebuilt", "meta", "manifests"))
    rdir = os.path.join(a.bundle, "raw_rebuilt", "meta", "receipts")
    rebuilt_ids = {n.rsplit(".", 1)[0] for n in os.listdir(rdir) if n.endswith((".packed", ".empty"))}
    curated = set()
    with gzip.open(os.path.join(a.bundle, "triage", "CURATE_PLAN.tsv.gz"), "rt", encoding="utf-8") as fh:
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) >= 6 and p[1] == "pack":
                curated.add((p[2], p[4], int(p[3])))
    bad, swaps, deletes = [], [], []
    for aid, files in sorted(old.items()):
        if aid not in rebuilt_ids:
            if files & curated:
                bad.append("%s holds curated files but was not rebuilt" % aid)
            continue
        rest = new.get(aid, set())
        lost = files - curated - rest
        dup = rest & curated
        extra = rest - files
        if lost:
            bad.append("%s: %d file(s) neither curated nor in the rebuilt archive, e.g. %s" % (aid, len(lost), sorted(lost)[0][1]))
        if dup:
            bad.append("%s: %d curated file(s) still in the rebuilt archive" % (aid, len(dup)))
        if extra:
            print("[note] %s: %d file(s) newer than the first upload are in the rebuilt archive (logs/ changed since)" % (aid, len(extra)))
        (swaps if aid in new else deletes).append(aid)
    missing_cur = {x for x in curated if not any(x in f for f in old.values())}
    if missing_cur:
        bad.append("%d curated file(s) were never in raw (plan built from other manifests?)" % len(missing_cur))
    with open(os.path.join(a.bundle, "raw_rebuilt", "SWAP.tsv"), "w") as fh:
        for aid in swaps:
            fh.write("replace\t%s\n" % aid)
        for aid in deletes:
            fh.write("delete\t%s\n" % aid)
    if bad:
        print("[check] FAIL"); [print("  " + b) for b in bad]
        return 1
    print("[check] PASS — %d raw archives rebuilt without the curated folders (%d replaced, %d become empty), %d untouched; "
          "every archived file is in exactly one place" % (len(swaps) + len(deletes), len(swaps), len(deletes), len(old) - len(swaps) - len(deletes)))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("plan"); p.add_argument("bundle"); p.add_argument("--map", required=True)
    p = sub.add_parser("check"); p.add_argument("bundle")
    p = sub.add_parser("docs"); p.add_argument("bundle"); p.add_argument("--map", required=True)
    a = ap.parse_args(argv[1:])
    if a.cmd is None:
        ap.print_help(); return 2
    return {"plan": cmd_plan, "check": cmd_check, "docs": cmd_docs}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
