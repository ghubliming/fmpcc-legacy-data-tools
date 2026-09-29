# CHANGELOG — log archive v1 (2026-09-27)

Implements the approved `PLAN_log_archive_export.md`. It archives cluster `logs/` into Google Drive in three layers:
`raw/` (everything, verified), `triage/` (reviewed decisions) and `curated/` (organised copy). The pipeline is tested
offline with a 42-check dry run and has **not yet run on the cluster**.

## New — `Slurm_Codes/sbatch/log_archive/`
| file | what |
|---|---|
| `logarch_common.sh` | Shared library, sourced by the jobs. Holds settings, the unit list (4 big trees split one level deeper; loose files grouped) and the core/media/weights split. Its one-pass packer (`pack_stream`) does tar → zstd → sha256 + md5 + decode-and-list, checks file count and bytes against the manifest, and writes to a file, to `rclone rcat`, or to a probe. Also: receipts, a per-stamp lock, the free-space guard, `capture_tree` / `change_report`, the 24 h auto-continue (`enable_autocontinue`, `stop_requested`, `resubmit_self` with `afterany`), and `ONLY_UNITS` / `SKIP_UNITS` / `FORCE_UNITS`. |
| `logarch_selftest.sh` | Init job (0:30). T1 tools · T2 disk · T3 synthetic compress→restore `diff -r` · T4 unit plan + odd names + stem clashes + live units (<24 h) · T5 smallest real unit byte-identical · T6 ratio/speed probe → estimate · T7 Drive round-trip (firewall check, quota, copyto + rcat, download, sha256, restore, speed, raw-layer hours) · T8 download kit. Writes `SELFTEST_REPORT.md` with a route verdict and `SELFTEST.env`. |
| `logarch_pack_gdrive.sh` | Route B (8:00, `--signal=B:USR1@1800`). Writes the raw layer to `…/<STAMP>/raw/`, staging on node-local disk (never tmpfs) or streaming. Captures `TREE_START`, checks the Drive MD5 of every archive, writes `CHANGES.md` at the end, uploads and checks `meta/`, and hands over to a new job near the time limit. |
| `logarch_pack_stage.sh` | Route A (2:00 per round). Budget-bounded rounds into `export_tmp/log_archive/<STAMP>/` under the 25 GiB free-space guard (exit 3 = even one archive does not fit). Writes `ROUND_RESULT`, `TREE_START`, and `CHANGES.md` when done. |
| `logarch_curate.sh` | Curated layer (8:00, auto-continue). Fetches the approved `CURATE_PLAN.tsv.gz` and refuses to run on a sha256 mismatch. Per folder it rcats `run_archive.tar.zst` and copies + checks the key files; per-run receipts; a failing folder is skipped and reported. Uploads `curated/_meta`. |
| `logarch_changes.sh` | Change report any time (0:30): `CHANGES.md` / `.tsv`, uploaded to Drive. Exit 3 = changes found. |
| `logarch_summarize.py` | Stdlib. Receipts + manifests → `SUMMARY.md/json`, `units.tsv`, `SHA256SUMS`. |
| `logarch_triage.py` | Stdlib. `scan`: finds runs (topmost folder with run markers; numbered seed folders promote their parent), loose groups and labels (thesis / referenced / unreferenced / loose / snapshot / abandoned). Evidence comes from a citation scan of `DA_in_Paper`, `Writing`, `logs_in_develop` and `archived_temp_bash` (paths + wave tags). `set`: logged glob edits. `plan`: `CURATE_PLAN` + sha256, `README.md` cards, `INDEX_auto.md`; renders and superseded `state_<N>.pt` are dropped from curated only. |
| `logarch_changes.py` | Stdlib. `logs/` now vs the archived manifests, per unit; prints the `FORCE_UNITS` line. |
| `logarch_triage_rules.tsv` | Editable rules: snapshot tokens, abandoned lines, kept renders, generation groups (from MASTER_TEST_HISTORY). |
| `README.md` | Usage, Drive layout, options. |
| `tests/run_dryrun.sh`, `tests/make_fixture.sh`, `tests/stubs/{rclone,zstd}`, `tests/README.md` | Offline end-to-end test on a ~20 MB fake `logs/`, 42 checks, temp dir only; stand-ins for Drive and zstd; the small-folder smoke test for the cluster. |

## New — `Slurm_Codes/download_remote_logs/`
- `logarch_local.sh`: the laptop/container side.
  - Over ssh: `selftest`, `pull-rolling`, `pull-meta`.
  - Over Drive only: `fetch-meta`, `triage`, `set`, `plan-curate`, `publish`, `check-drive`, `fetch`, `upload`,
    `verify`, `status`, `drive-test`.
  - `CLUSTER=local` dry-run hook.
- `ORGANIZE_PROMPT.md`: Claude's part — task A reviews the triage (proposals only, applied after the author's OK);
  task B writes `README.md` + `RESTORE.md` for the stamp.

## Changed
- `Slurm_Codes/download_remote_logs/README.md`: the new tool comes first. `export_to_laptop.sh` is marked superseded with
  the reasons (fills the shared disk, pushes to the laptop, `rsync -z`, wrong partition); its original text is kept below.
  The script itself is unchanged.
- `logs_in_develop/Log_Archive_Export/PLAN_log_archive_export.md`: status → approved + implemented. Adds the three-layer
  model, the caveat table (24 h, changing `logs/`, firewall, separate env), the real file list, and the runbook with the
  smoke test.

## Verified here
- `tests/run_dryrun.sh`: 42/42 PASS.
- A deliberately broken copy (renders kept in curated) → 41/42, so the checks catch regressions.
- The citation scan over the real repo takes 5.6 s and finds real wave tags in `DA_in_Paper`.

## Not verified yet
Real zstd, rclone and Google Drive (OAuth, firewall, MD5), Slurm `--signal` + self re-submit, `sacct` / `submit.sh`
parsing (route A), and the cluster's GNU tool versions. All are covered by the smoke test in the plan, §7 steps 4–10.

## Fix 1 — after the first cluster runs (2026-09-27)
- Real init jobs 26279 / 26280 on `i6-gpu-1`: all tests PASS or INFO.
  - T7 (Drive from a compute node) PASS: 5.0 TiB free, 33 MB/s up, raw layer ≈ 0.8 h in one job.
  - T6: packing at ≈ 170 MB/s; bundle ≈ 85 GiB.
  - T4_live: `avoiding-d3il/plans` written in the last 24 h.
  - The kit copied back to the container verified here: sha256 OK, 308/308 files restored.
- New `Slurm_Codes/sbatch/log_archive/tests/smoke_cluster.sh`: the whole pipeline on a few small real folders in one
  command. It submits and waits for the jobs, runs triage/plan/publish on the login node and the restore test via srun,
  prints a PASS/FAIL table, and `CLEAN=1` deletes the smoke copy. Mock-tested here with fake sbatch/sacct/srun: all 6
  stages PASS, CLEAN works. `tests/README.md` §2 points to it.

## Smoke test on the cluster — PASS (2026-09-27 20:35–20:43)
`tests/smoke_cluster.sh`, stamp `smoke_20260927_2035`. Folders: `uav_naive`, `solver_bench`,
`aligning-d3il-visual/mix_visual_aligning_fm`, `avoiding-d3il-visual(1e4_EMA_changed)`. Jobs 26281 (raw),
26283 (curate), 26284 (changes), 26285 (srun restore).

| stage | result |
|---|---|
| raw | 8 archives, md5-checked |
| triage | 10 rows, 6 included / 4 excluded (abandoned) |
| curate | 6 folders |
| changes | none |
| publish | cards + catalog on Drive |
| restore | CHECK-DRIVE PASS |

A duplicate start in the same minute (same stamp) was refused by the per-stamp lock (job 26282 FAILED on purpose), and
both runs wrote into one `smoke.log`. No code change was needed. The `libtinfo.so.6: no version information` lines come
from `~/miniconda3/lib` being on the library path of the user's shell and are harmless.
Not exercised yet: the 30-min time-limit hand-over (`--signal` + self re-submit) — that only happens on a long run.

## Fix 2 — sanity check before the full run (2026-09-27)
- **Risk found:** `logarch_pack_gdrive.sh` stopped the whole job (`die`) when a single archive failed.
  `avoiding-d3il/plans` was still being written (newest files 18:24), so one live folder could have aborted the full
  run halfway.
- **Change:** the per-unit work moved into `do_unit`. A failing tier is logged with its reason and skipped (nothing
  half-done is kept: staged file removed, a remote copy with a wrong MD5 deleted), and the job continues. Failed units
  get one retry after `RETRY_WAIT` (default 300 s). Three failures in a row stop the job (network / login / quota). The
  end result is `partial` with the list of what's not done, and the job exits 1; re-submitting packs only those.
- **Tests:** `tests/run_dryrun.sh` gains `raw_failure_isolated` (one unreadable file → only its unit fails, 16/17
  archives up, exit 1) and `raw_failure_resubmit_heals` (re-submit → complete). Now 44/44 PASS.

## Full raw upload — DONE (2026-09-27)
- **Job:** 26289 on `i6-gpu-1`, stamp `full_20260927`, git `e5f37127`. It ran 52 min (21:40–22:32 job clock).
- **Upload:** 98 archives, all staged on node-local `/tmp`, every one md5-checked on Drive. No failures or retries.
- **Size:** 101.1 GiB raw → 75.3 GiB archived (×0.75). The largest archive, `aligning-d3il-visual/plans` media
  (19.8 → 16.1 GiB, 29,755 files), packed in 125 s.
- **Checks:** `[changes] none - logs/ equals the archives`; `raw/meta` on Drive: 336 files, 0 differences.
- **Location:** `gdrive:FMPCC_logs_backup/full_20260927/raw/`. This is the complete, never-edited copy of `logs/`.
- **Next:** the organize step (triage → your approval → `logarch_curate.sh` → catalog). The Google login is in test mode
  and expires 7 days after 2026-09-27; reconnect first if the curate job runs later than that.

## Organize v2 — code (2026-09-28, plan `PLAN_organize_v2.md`)
- **New `Slurm_Codes/sbatch/log_archive/logarch_organize.py`** (stdlib):
  - `plan`: naming map → CURATE_PLAN with renames, complete folders (nothing dropped), key files, one note per folder;
  - `check`: after the raw rebuild, proves every archived file is in exactly one place (curated plan or rebuilt raw) and
    writes the swap list;
  - `docs`: master `README.md` (where to look, name legend, file types, what to ignore, TEST / ABANDONED / SUPERSEDED
    lists), `NAMING.md`, `RESTORE.md` (incl. rebuilding the original `logs/` layout for the DA scripts).
- **New `logarch_raw_rebuild.sh`** (sbatch 8:00, auto-continue): re-packs only the raw units that contain thesis folders,
  without them, into `raw_rebuilt/`; empty tiers get an `.empty` receipt.
- **New `logarch_organize_pipeline.sh`** (sbatch 0:10): submits curate, then raw rebuild (`afterok`).
- **`logarch_common.sh`:** `PACK_TAR_EXTRA` (extra tar options).
- **`logarch_curate.sh`:** a plan root line marked `rename` → archive `<new name>.tar.zst` whose members unpack into
  `<new name>/` (tar `--transform`, root path escaped for BRE).
- **`logarch_local.sh`:**
  - `organize-plan`;
  - `finalize`: fetches the rebuilt meta, checks the plan sha, requires every curated folder done, runs the coverage check,
    then per archive moves the old one to `raw_replaced/` and the rebuilt one into `raw/` (md5 re-checked), merges and
    syncs `raw/meta`, and verifies `raw/archives` == `SHA256SUMS` before purging `raw_replaced` and `raw_rebuilt` into the
    Drive trash;
  - `publish-organized`;
  - `check-drive` understands renamed curated archives.
- **Tests:** `tests/stubs/rclone` gains `moveto`, `sync` and `lsf` of a file. `run_dryrun.sh` gains 11 `org_*` checks
  (rename, raw has no thesis files, old versions gone, docs, full restore). **55/55 PASS.** On the way, finalize stopped
  itself safely on the stand-in bugs.
- **Real data:** 128 thesis folders / 101,023 entries / 20.8 GiB planned; 2,909 key files. The plan (sha-pinned) is on
  Drive: `full_20260927/triage/`. The α_end of the aligning CI-MeanFM (`…afschsigmoid`) is confirmed 0.0 from its
  `diffusion_config.json`.

## Organize v2 — DONE on the real archive (2026-09-28)
- **Cluster jobs:** pipeline 26305 → curate 26306 (128 folders, renamed, complete) → raw rebuild 26307 (22 archives
  rebuilt without the thesis folders).
- **`finalize`:** coverage check PASS; 22 swapped, 5 removed; `raw/` = 93 archives; old versions in the Drive trash.
- **Published:** `README.md` (master), `NAMING.md`, `RESTORE.md`, `naming_map.tsv`, one note per curated folder, and
  guide READMEs in `raw/`, `curated/`, each task folder, `triage/`, and at the Drive root (added to
  `logarch_organize.py docs` + `publish-organized`).
- **Restore spot-check** PASS.
- **Lesson:** don't edit a bash script while it is running (bash reads it incrementally) — the finished finalize printed a
  harmless syntax error from the edited tail.

## Frozen batch CSVs on Drive (2026-09-29)
- `Data_Analysis/analysis_results_checkpoint/27-09-1500-Confirmed-Full` (38 files, 385 MB) → new folder
  `gdrive:FMPCC_logs_backup/analysis_csv_20260927/` with a `README.md` (which batch is which task / pipeline). Copy only, target
  checked absent first; `rclone check --one-way --download` 0 differences. The Drive root `README.md` does not mention it (author's edit).
- Done from the parking-repo workspace; row by row in `../Legacy_Data_Tools_Repo/DRIVE_UPLOAD_LOG.md` (#1–#2).

## Relabel MeanFM → Analytic-MeanFM — code + prep (2026-09-30)
The thesis renamed the label in v5.33 (`Diffusion / FM / Analytic-MeanFM / CI-MeanFM`); the author asked for the Drive names,
the catalog and the linked copies to follow. Rule: every `MeanFM` not preceded by `CI-` or `Analytic-` → `Analytic-MeanFM`.
- **Scope on Drive:** 36 curated folders (5.1 GB of archives; each unpacks into its own name, so the archives are re-packed),
  their 36 notes, 36 curate receipts, `CURATE_SUMMARY.tsv`, `triage/CURATE_PLAN.tsv.gz` (+ both sha256 files), the catalog
  (`README.md` example + label row, `NAMING.md`, `RESTORE.md` example, `naming_map.tsv`) and the 5 task notes. Not affected:
  `raw/` (original paths), `TRIAGE.*`, the Drive root README, `smoke_20260927_2035/`, `analysis_csv_20260927/`.
- **Map:** `catalog_full_20260927/RELABEL_20260930_analytic_meanfm.tsv` — 36 rows (run_id, old/new name, old md5 / bytes / sha256,
  files, raw bytes, entries), taken from the Drive receipts and cross-checked against `CURATE_SUMMARY.tsv`, the sizes on Drive
  and `naming_map.tsv`; no new name collides.
- **New `Slurm_Codes/sbatch/log_archive/logarch_relabel.sh`** (sbatch 2:00, CPU-only, curate lock) + **`logarch_relabel.py`**
  (stdlib). Per folder: download (md5 = map) → stream re-tar into `<new>/` → read back, every member equal (name mapped, size,
  mtime, mode, owner, sha256) and counts = receipt → upload next to the old archive, Drive md5 → old archive to the Drive trash →
  note relabelled → folder renamed server-side (listing identical before/after) → receipt updated (`relabel_prev_*` keep the old
  values). Progress record `curated/_meta/RELABEL_20260930_analytic_meanfm.tsv` after every folder. When all 36 are done: plan
  dest column (old plan kept on the cluster as `CURATE_PLAN.pre_<tag>.tsv.gz`) + sha256, summary, receipts → Drive, and the job
  log. Stops at the first failing folder; re-submitting continues (half-done folders resume).
- **Tested offline** (local stand-in for Drive, real archives + real receipts/plan): clean run, idempotent re-run (no file
  changed), resume after an interrupted upload (deleted + rebuilt, byte-identical), corrupt archive (stops, nothing touched),
  wrong map md5 (refused in pre-flight), both names present (stops), `ONLY_RIDS` pilot then completion. Found and fixed on the
  way: `rclone moveto` has no `--delete-empty-src-dirs` (→ `rclone move`), a marker file counted as a record row.
- **`logarch_organize.py`:** the label row, the README example and the RESTORE example carry the new label, plus one README line
  pointing to the relabel record — `docs` re-run on a copy reproduces the patched `README.md` / `RESTORE.md` exactly and
  `NAMING.md` + task notes up to row order (the generator sorts; the patched files use its order).
- **Patched here, not yet on Drive:** `catalog_full_20260927/{README,NAMING,RESTORE}.md`, `naming_map.tsv`; local mirror
  `/workspaces/FMPCC_log_archive/full_20260927` (catalog, `guides/stamp/curated/<task>/README.md`, `cards/` 36 folders renamed +
  notes). Pre-relabel copies: `/workspaces/FMPCC_log_archive/full_20260927/_pre_relabel_20260930/` (Drive + local).
- **Open:** (1) author: commit, pull on the cluster, `./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_relabel.sh
  full_20260927 logs_in_develop/Log_Archive_Export/catalog_full_20260927/RELABEL_20260930_analytic_meanfm.tsv`; (2) on the author's
  "ready": catalog + 5 task notes → Drive (container; parallel-safe, disjoint files); (3) after the job: verify the record, spot
  restore of relabelled folders, local mirror `triage/` from Drive, every Drive write in `DRIVE_UPLOAD_LOG.md`.
- **Status 2026-09-30 15:35 UTC:** job **26504** submitted by the author and running. The container part is DONE: catalog
  (`README.md`, `NAMING.md`, `RESTORE.md`, `naming_map.tsv`) + the 5 task notes uploaded 15:29–15:31, each only after the Drive md5
  matched the pre-relabel backup, md5 checked after (`../Legacy_Data_Tools_Repo/DRIVE_UPLOAD_LOG.md` #3–#11). First folder done
  by the job and checked from here: `D3IL-aligning/evaluations/Analytic-MeanFM_K100_thr0.1_seed6` — old name gone, new archive md5 =
  record, note = the locally patched card, old archive (26,301,422 B) in the Drive trash.
- **Status 17:29 UTC:** job 26504 hit its 2 h limit during folder 16 — **15 / 36 done** (all D3IL-aligning + 8 D3IL-avoiding, ≈ 4 of
  5.1 GB). Drive was far slower than on 09-28 (≈ 1–2.5 MB/s each way instead of 14–20 MB/s). Folder 16 was not changed (old
  archive still there). Re-submit the same command with more time; it resumes (21 folders, ≈ 1.1 GB left).
- **Lesson (author):** downloading was needed only because the old name is also inside each archive (it unpacks into `<name>/`).
  A rename-only relabel (rclone or Colab, server-side, instant) would have been enough if the inner folder name may stay old —
  offer that cheap option first next time, or pack archives without the thesis label inside so relabels stay metadata-only.
- **Re-submitted 17:32 UTC** as job **26506** (`SBATCH_TIMELIMIT=03:00:00`, same command; resumes at folder 16 of 36).

## Relabel MeanFM → Analytic-MeanFM — DONE on the real archive (2026-09-30)
- **Cluster:** job 26504 (15 folders, then its 2 h limit — too tight for today's ≈ 1–2.5 MB/s) + job 26506 (`SBATCH_TIMELIMIT=03:00:00`,
  the other 21 + the final step, ended `[done]` 18:27 UTC). Every archive compared file by file before upload, Drive md5 checked.
- **Drive now:** 36 `Analytic-MeanFM_*` folders, 0 with the old name, 128 curated folders per task as in the catalog; record
  `curated/_meta/RELABEL_20260930_analytic_meanfm.tsv` (36 rows, old/new names + md5s); plan dest relabelled (sha256 `de546cb53c9e…`),
  receipts + `CURATE_SUMMARY.tsv` updated; catalog + task notes (container, 15:29–15:31). Old archives in the Drive trash until ≈ 10-30.
- **Local:** mirror `triage/CURATE_PLAN.tsv.gz` = Drive (sha ok); catalog, cards and guides were patched before the job.
- **Checks kept naive** (author: the job log is enough): the job's `[done]` + folder counts. Drive writes: `../Legacy_Data_Tools_Repo/DRIVE_UPLOAD_LOG.md` #3–#14.
