# Plan — Archive the cluster `logs/` (Slurm jobs → Google Drive raw + curated → AI catalog)

**Status:** APPROVED 2026-09-27 · IMPLEMENTED (dry run 44/44) · smoke test PASS · **RAW LAYER DONE** —
`gdrive:FMPCC_logs_backup/full_20260927/raw` (job 26289, 2026-09-27 21:40–22:32, 98 archives, 101.1 GiB → 75.3 GiB,
no failures, change check: none). Next: the organize step (triage → approval → curated layer → catalog).
Changelog: `CHANGELOG_log_archive_v1.md` (this folder).

**Goal:** get the 100 GiB `/u/home/llim/FMPCC/FM-PCC/logs` off the cluster as compressed, verified archives in Google
Drive, keep a faithful copy of everything, and build an organised, browsable copy with an MD catalog — without ever
moving or deleting anything on the cluster.

**Runs on:** Slurm compute jobs for all packing/uploading (never the login node) · this dev container for triage,
catalog and Drive checks (Drive only, no ssh needed) · laptop WSL2 shell only for the ssh-based fallback (route A).

---

## 1. Decision — Google Drive, uploaded by the Slurm job

**Route B (default): the Slurm job uploads straight to Drive.** The container reads only the metadata (MBs) to triage and
catalog. **Route A (fallback)** — rolling download to the laptop, then upload from there — is used only if the init job
shows that compute nodes cannot reach Google (T7).
Storage: your Google Pro plan has room; the raw layer is ≈ 80 GiB, the curated copy ≈ 40–50 GiB.

Why not "download everything first": `/u/home` is a *shared* disk (2.9 GiB free on 2026-09-19, 43 GiB after the cleanup).
~80 GiB of archives cannot be staged there, so download-first means babysat rounds plus a second ~80 GB push over home
internet. The organising step never needed the heavy bytes locally — manifests are enough.

```
cluster, Slurm (read-only on logs/)                         Google Drive  gdrive:FMPCC_logs_backup/<STAMP>/
logs/<unit> → manifest → tar|zstd → hash + decode-check ──→ raw/archives/<unit>.<tier>.tar.zst   (everything, never edited)
                                                             raw/meta/  manifests · receipts · SUMMARY · CHANGES · TREE_*
container: fetch-meta → triage (labels + evidence) → you review/approve → plan-curate ──→ triage/  TRIAGE · CURATE_PLAN(+sha256)
cluster, Slurm: logarch_curate.sh executes exactly the approved plan ──────────────→ curated/<generation>/<path>/  card · key files · run_archive
container: Claude writes README/RESTORE → publish → check-drive (restore test) ─────→ README.md · RESTORE.md · TRIAGE.md · INDEX_auto.md
```

---

## 2. What is being moved (tree snapshot 2026-09-27 15:01)

- `logs/`: **300,037 files, 100.3 GiB**, newest 2026-09-24.
- Largest folders:
  - `aligning-d3il-visual` 33.6 GiB (`plans/` 23.2)
  - `avoiding-d3il` 18.9 GiB (`plans/` 10.8 GiB in 132k files)
  - `UAV_MIX` 15.4 GiB and `UAV_FM` 15.3 GiB
  - the other 17 top folders are ≤ 4.1 GiB each
- By type (whole repo): gif 35.4 GiB · pt 20.6 · png 13.4 · npz 11.9 · svg 8.7 · log 6.8 · csv 6.7 · pth 4.4.
  About two thirds of the bytes are images or weights, which zstd barely shrinks → expect **≈ 75–85 GiB** of raw archives.
  The init job measures the real number.

---

## 3. Constraints

- **Login node:** no heavy work there — it only runs `submit.sh`.
- **Jobs:** CPU-only on `gpu-1-student` (no `--gres`, no MuJoCo → no EGL block), 4 CPUs, 8 GB. Submitted with `submit.sh`;
  no progress bars in logs.
- **Shared-disk guard:** 25 GiB must stay free. Route B stages nothing on `/u/home`: it uses node-local disk (never tmpfs),
  or streams straight into rclone.
- **Separate environment:** a new conda env `logarch` (`zstd`, `rclone`, `python` from conda-forge). The FMPCC env is never
  activated or changed, and all Python is stdlib-only (no pip).
- **Google Drive facts:**
  - 750 GiB/day upload cap;
  - rclone's shared client ID is retired during 2026, so you need your own OAuth client;
  - "Testing"-status logins expire after 7 days;
  - scope `drive.file` = rclone sees only what it created;
  - MD5/SHA-256 are available for verification;
  - Drive ingests only ~2 files/s, so raw goes up as archives, and loose files are used only for the small key-file set.
- **Old tool retired:** `download_remote_logs/export_to_laptop.sh` is kept but marked superseded. It fills the shared disk,
  pushes *to* the laptop, uses `rsync -z` on compressed data, and asks for `--partition=cpu`.
- **This container:** it cannot ssh to the cluster, but it can use Drive once rclone is configured here.

---

## 4. How it works

### 4.1 Raw layer — everything, as it was
- **Units:** each folder under `logs/`. The 4 big trees are split one level deeper, and loose files form their own unit.
- **Tiers:** `core` (json, csv, log, npz, pkl, …) · `media` (gif, png, jpg, svg, mp4, pdf) · `weights` (pt, pth, ckpt).
- **One archive per unit × tier:** `<unit>.<tier>.tar.zst` (tar + zstd -3). Member paths start with `logs/`, so extracting
  in the repo root restores the original layout.
- **One-pass integrity:** the stream is written, hashed (sha256 + md5) and decoded + listed at the same time. File count and
  bytes must equal the listing taken just before packing. The Drive MD5 must equal the stream's.
- **Receipts make everything resumable:** re-submitting the same `STAMP` continues where it stopped, and a lock stops two
  writers on one stamp.

### 4.2 Triage — what is needed, with evidence (container, reads only lists)
- **Runs are found from the files:** a run is the topmost folder that holds run files (`seeds_config.json`, `losses.*`,
  `state_best.pt`, `results.json`, `config_snapshot_*/`, `results/`). A numbered seed folder belongs to its parent, so an
  eval variant with seeds 6–10 + `all_seeds/` + `plots/` is one run. Everything else forms loose-file groups.
- **Labels:**

  | label | meaning | curated by default |
  |---|---|---|
  | `thesis` | its path or wave tag is cited in `DA_in_Paper` / `Writing` | yes |
  | `referenced` | named in dev logs or drivers | yes |
  | `unreferenced` | nothing cites it | yes |
  | `loose` | files outside any run folder | yes |
  | `snapshot` | `(Bf_…)`, `(legacy_…)`, `_before_u12`, `(smoke_run)`, `(Archive_…)`, `(incorrect)`, `(unfull)` | **no** |
  | `abandoned` | a line given up per MASTER_TEST_HISTORY (visual avoiding Gen4/9/16, iMF Gen3v4) | **no** |

  Snapshots and abandoned runs are still curated if the thesis cites them. Each label cites its source file, and the rules
  live in the editable `logarch_triage_rules.tsv`.
  Measured on this repo: the citation scan takes 5.6 s and finds e.g. the tags `u17cv2`, `p23scgrid` and `msgdpccproto`
  in `DA_in_Paper`.
- **You decide:** `TRIAGE.md` is the review page, and `set --match <glob> --include yes|no` changes rows (logged).
  Claude only *proposes* changes (`ORGANIZE_PROMPT.md`, task A). "No" never deletes anything — it only keeps the row out
  of `curated/`.

### 4.3 Curated layer — the organised copy (cluster job, executes only the approved plan)
- **Where:** `curated/<generation group>/<original path>/`.
- **What each folder holds:**
  - a `README.md` card: label, evidence, seeds, sizes, what was left out, where the full original is in `raw/`;
  - key files as plain, previewable files (configs, `results.json`, summaries, small plots; ≤ 40 per run);
  - `run_archive.tar.zst` with the run minus GIF/MP4 renders (except expert references / expert data) and minus
    superseded `state_<N>.pt` next to a `state_best.pt`. Everything left out is still in `raw/`.
- **Safety:** the plan's sha256 must match what was approved, and a tampered plan is refused. The job reads only the files
  the plan names; a failing folder is reported and the others continue.

### 4.4 Catalog — Claude's part (container)
`ORGANIZE_PROMPT.md`, task B:
- `README.md` — the entry point: layers, per-generation tables, what was left out and why, verification status.
- `RESTORE.md` — restore recipes using the real archive names.

`publish` uploads the cards and catalog, and copies the MDs into `logs_in_develop/Log_Archive_Export/catalog_<STAMP>/`
for git. `check-drive` downloads, restores and compares against the manifests and the plan.

### 4.5 Your caveats — how they are handled

| caveat | handling |
|---|---|
| **24 h job limit** | Each archive is small, so the raw layer should fit in one 8 h job (T7 prints the estimate). If not: `#SBATCH --signal=B:USR1@1800`. 30 min before the limit the job finishes the archive in progress, starts no new one, and re-submits itself with `--dependency=afterany` (≤ 5 hand-overs). Done work is skipped via the receipts. Same for `logarch_curate.sh`. |
| **`logs/` changing while packing/uploading** | Each archive is checked against a listing taken seconds before. A file changing mid-pack fails *that unit only*: it is skipped, retried once after 5 min, else listed, and the job continues and ends `partial` (exit 1); re-submitting packs only what is missing. The whole tree is captured at the start (`TREE_START`). At the end, `CHANGES.md` compares `logs/` with exactly what the archives hold (added / removed / modified per unit, second precision) and prints the `FORCE_UNITS="…"` line that re-packs only those units. `logarch_changes.sh` re-checks any time, e.g. before trusting the archive. The init job flags units written in the last 24 h (T4_live) → pause those writers or use `SKIP_UNITS`. |
| **Firewall may block the upload** | T7 in the init job tries Drive from a compute node with short timeouts (quota, upload both ways, download back, restore, speed). If blocked → route A (download over ssh), which needs no internet on compute nodes. `logarch_local.sh drive-test` does the same check from this container. |
| **No changes to the FMPCC env** | Separate `logarch` conda env with 3 conda-forge packages; stdlib-only Python; nothing installed into FMPCC. |

---

## 5. Tests

| test | where | proves |
|---|---|---|
| `tests/run_dryrun.sh` | anywhere, offline, ~1 min, temp dir only | the whole pipeline on a fake `logs/` (42 checks, listed in `tests/README.md`), incl. staged = streamed (byte-identical), resume, 24 h hand-over, triage labels, tampered plan refused, full restore from "Drive", change detection + healing |
| `logarch_selftest.sh` (init job) | cluster | T1 tools · T2 disk · T3 synthetic round-trip (diff -r) · T4 plan + live units · T5 real unit byte-identical · T6 ratio/speed probe · T7 Drive round-trip + firewall · T8 download kit → `SELFTEST_REPORT.md` verdict |
| `logarch_local.sh selftest` / `drive-test` | laptop (ssh) / container | the download leg; Drive reachability + speed from here |
| smoke test (§7, steps 4–10) | cluster + container | every stage on one small real folder, ending with `check-drive … 0` (full restore) |
| acceptance of the real run | cluster + container | every unit × tier has a receipt · all Drive MD5s matched · `CHANGES.md` = no changes · `check-drive` on a sample passes · every included run has a curated folder and card |

---

## 6. Files

| path | kind | purpose |
|---|---|---|
| `Slurm_Codes/sbatch/log_archive/logarch_common.sh` | sourced | settings, units, tier split, one-pass packer, receipts, lock, disk guard, tree capture, auto-continue |
| `…/logarch_selftest.sh` | sbatch 0:30 | init job |
| `…/logarch_pack_gdrive.sh` | sbatch 8:00 | route B raw layer |
| `…/logarch_pack_stage.sh` | sbatch 2:00/round | route A raw layer |
| `…/logarch_curate.sh` | sbatch 8:00 | curated layer from the approved plan |
| `…/logarch_changes.sh` | sbatch 0:30 | change report any time |
| `…/logarch_summarize.py`, `logarch_triage.py`, `logarch_changes.py` | stdlib Python | summary; runs + labels + plan + cards; change comparison |
| `…/logarch_triage_rules.tsv` | config | snapshot tokens, abandoned lines, kept renders, generation groups |
| `…/README.md`, `…/tests/` | docs, tests | usage; dry run, fixture, rclone/zstd stand-ins |
| `Slurm_Codes/download_remote_logs/logarch_local.sh` | laptop/container | selftest · pull-rolling · pull-meta · fetch-meta · triage · set · plan-curate · publish · check-drive · fetch · upload · verify · status · drive-test |
| `…/ORGANIZE_PROMPT.md` | prompt | Claude: triage review (proposals only) + catalog |
| `…/README.md` | doc | new tool first; `export_to_laptop.sh` marked superseded (kept) |

---

## 7. Runbook

**One-time setup**
1. **Cluster login node** (light): `conda create -y -n logarch -c conda-forge zstd rclone python`
2. **Google:**
   - follow rclone's "Making your own client_id": enable the Drive API; External consent screen with you as test user;
     Desktop-app OAuth client; publish it;
   - run `rclone config` somewhere with a browser: remote `gdrive`, your client ID/secret, scope `drive.file`;
   - copy the `[gdrive]` block into the rclone config on the cluster and in this container (`rclone config file` shows
     where it is), and `chmod 600` it.
3. **Container:** `sudo apt-get install -y rclone zstd`. Laptop WSL2 only for route A: also `rsync`.

**Test (small folder first)**
4. Cluster:
   - `./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_selftest.sh`
   - read `export_tmp/log_archive/_selftest/<ts>/SELFTEST_REPORT.md`; T7 decides B vs A.
5. Container: `bash Slurm_Codes/download_remote_logs/logarch_local.sh drive-test`
6. Cluster: `ONLY_UNITS="uav_naive solver_bench" ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_pack_gdrive.sh smoke_20260928`
7. Container: `logarch_local.sh fetch-meta smoke_20260928`, then `triage smoke_20260928` (read `TRIAGE.md`), then
   `plan-curate smoke_20260928`.
8. Cluster: `./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_curate.sh smoke_20260928`, then
   `./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_changes.sh smoke_20260928`.
9. Container: `logarch_local.sh publish smoke_20260928`, then `logarch_local.sh check-drive smoke_20260928 0` — must PASS.
10. Optional: add `avoiding-d3il-visual(1e4_EMA_changed)` (262 MB: training runs, all tiers, abandoned label). Then remove
    the smoke stamp with `rclone purge gdrive:FMPCC_logs_backup/smoke_20260928`.

**Real run**
11. If possible, pause jobs that write into `logs/` (or use `SKIP_UNITS` for the live units T4 lists).
    `./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_pack_gdrive.sh 20260928` — hands over by itself if long.
12. Container: `fetch-meta` → `triage` → Claude task A (proposals) → your approval → `set` → `plan-curate`.
13. Cluster: `logarch_curate.sh 20260928`.
14. Container: Claude task B (README, RESTORE) → `publish` → `check-drive 20260928` (sample; `0` = everything).
15. Before trusting the archive: `logarch_changes.sh 20260928` must say no changes (or re-pack with the printed `FORCE_UNITS`).
16. Afterwards: `rclone config delete gdrive` on the cluster. Deleting `logs/` is a separate decision, not part of this plan.

---

## 8. Risks

| risk | mitigation |
|---|---|
| compute nodes blocked by a firewall | T7 → route A (ssh download; laptop pulls in rounds) |
| Drive quota / 750 GiB/day | T7 prints free space; `--drive-stop-on-upload-limit` fails fast; the next day's re-submit continues |
| job hits 24 h | auto-continue (§4.5); receipts make re-runs free |
| `logs/` changes during the campaign | per-archive check, `CHANGES.md`, `logarch_changes.sh`, `FORCE_UNITS`, T4_live / `SKIP_UNITS` |
| wrong triage call | nothing is deleted; `raw/` keeps everything; labels cite evidence; you approve; the plan is sha256-pinned |
| Google token on a shared cluster | scope `drive.file`, mode 600, deleted after the run |
| NFS load for other users | `nice`, 4 threads, one archive at a time |
| first real run of scripts only dry-run so far | smoke test on a small folder before the full run (§7, steps 4–10) |

---

## 9. What is proven, and what is not yet

**Proven offline** (this container, stand-ins for zstd/rclone/Slurm):
- `run_dryrun.sh` passes 42/42.
- A deliberately broken copy (renders not dropped) is caught: 41/42, `curated_drops_render` FAIL.
- The triage citation scan runs on the real repo corpus in 5.6 s.

**Proven on the cluster (2026-09-27):**
- Init jobs 26279 / 26280: T1–T8 PASS. Drive from a compute node: 5.0 TiB free, 33 MB/s up; packing ≈ 170 MB/s.
- Smoke test `tests/smoke_cluster.sh`, stamp `smoke_20260927_2035`, 4 small folders, ~8.5 min: raw (8 archives,
  md5-checked) · triage (10 rows, 6 in / 4 out = the abandoned visual-avoiding folder) · curate (6 folders) ·
  changes (none) · publish · restore (all raw units and curated folders restored from Drive and matched) — all PASS.
- The lock also worked for real: a second smoke run started in the same minute (same stamp) had its upload job
  (26282) refuse to run while 26281 held the stamp.
- Real compression: core ×0.21–0.43 · media ×0.85–0.98 · weights ×0.92.

**Was open before the smoke test (now covered, except the time-limit hand-over):**
- real zstd / rclone / Google (OAuth, firewall, MD5 timing);
- Slurm `--signal` delivery and the self re-submit;
- `sacct` / `submit.sh` parsing in route A;
- GNU tool versions on the cluster (the dry run can also be run there first).

---

## 10. Next decisions for you

1. Do the one-time setup (§7, steps 1–3) and run the smoke test (steps 4–10). Send me the `SELFTEST_REPORT.md` and the
   `check-drive` output.
2. The real-run `STAMP` (proposal `20260928`) and whether to pause writers into `logs/` during it.
3. After the real triage: approve or adjust Claude's proposals.
4. Optional: I update the "Remote Log Sync Pipeline" row in `MASTER_TEST_HISTORY.md` to this tool — only with your OK.

*Sources consulted (names only, no links):*
- rclone documentation: Google Drive backend (scopes, own client ID and its 2026 retirement, 750 GiB/day, hashes, ~2 files/s
  limit, server-side copy), remote setup (`rclone authorize` / copying the config), `rcat`, `checksum`, global flags;
- the zstd manual;
- the conda-forge `rclone` package page;
- in the repo: tree snapshot 27-09, `SLURM_RUNBOOK_20260919_pillars_enlarged.md`, `tools/clean_gifs/sweep/README.md`,
  `tools/clean_weights/README.md`, `Data_Analysis/DA_in_Paper/`.
