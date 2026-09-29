# log_archive — `logs/` → compressed, verified archives → Google Drive (raw + curated) → MD catalog

Plan and rationale: `logs_in_develop/Log_Archive_Export/PLAN_log_archive_export.md` · laptop/container side:
`Slurm_Codes/download_remote_logs/logarch_local.sh` · offline test of everything: `tests/run_dryrun.sh`.

**Safety model.** Jobs only READ `logs/` — nothing on the cluster is moved, renamed or deleted (the only deletions are
this tool's own temporary archives, after they were verified at their destination). Every archive is hashed and
decoded + listed while it is written; file count and bytes must equal the listing taken seconds before. Receipts make
every job idempotent: re-submit the same command to continue. CPU-only jobs (no `--gres`, no MuJoCo → no EGL block).
Tools come from a separate conda env `logarch` (zstd, rclone, python) — the FMPCC env is never touched; all Python here
is stdlib-only.

## Google Drive layout (`gdrive:FMPCC_logs_backup/<STAMP>/`)

| folder | written by | what |
|---|---|---|
| `raw/archives/` | `logarch_pack_gdrive.sh` | one `<unit>.<core\|media\|weights>.tar.zst` per unit × tier — **everything, as it was, never edited** |
| `raw/meta/` | same | manifests (every file: type, size, mtime, path), receipts (hashes), `SUMMARY.md`, `SHA256SUMS`, `TREE_START`/`TREE_END`, `CHANGES.md` |
| `triage/` | `logarch_local.sh plan-curate` | `TRIAGE.tsv/.md` (your reviewed decisions), `CURATE_PLAN.tsv.gz` + `.sha256` (exactly what curate runs) |
| `curated/<group>/<path>/` | `logarch_curate.sh` + `publish` | per run: `README.md` card, key files as plain files, `run_archive.tar.zst` (renders + superseded `state_<N>.pt` left out — still in `raw/`) |
| `README.md`, `RESTORE.md`, `TRIAGE.md`, `INDEX_auto.md` | `publish` | the catalog |

## Files

| file | kind | does |
|---|---|---|
| `logarch_common.sh` | sourced | settings, units (the 4 big trees split one level deeper), tier split, one-pass packer, receipts, lock, disk guard, tree capture, 24 h auto-continue |
| `logarch_selftest.sh` | sbatch 0:30 | **INIT job** T1–T8: tools, disk, synthetic + real round-trip, tree plan + live units, ratio/speed probe, Drive round-trip + firewall check, download kit → `SELFTEST_REPORT.md` with the route verdict |
| `logarch_pack_gdrive.sh` | sbatch 8:00 | route B: raw layer straight to Drive (node-local disk or streaming — nothing staged on `/u/home`); tree at start, `CHANGES.md` at the end; hands over to a new job 30 min before its limit |
| `logarch_pack_stage.sh` | sbatch 2:00 | route A (no internet on compute nodes): one budget-bounded round into `export_tmp/log_archive/<STAMP>/`, driven by `logarch_local.sh pull-rolling` |
| `logarch_curate.sh` | sbatch 8:00 | curated layer from the approved `CURATE_PLAN` (sha256-checked); per-folder receipts; auto-continue |
| `logarch_changes.sh` | sbatch 0:30 | did `logs/` change after archiving? → `CHANGES.md` + the `FORCE_UNITS=` line that re-packs exactly those units |
| `logarch_summarize.py` | stdlib | receipts + manifests → `SUMMARY.md/json`, `units.tsv`, `SHA256SUMS` |
| `logarch_triage.py` | stdlib | runs (topmost folder with run files; seed folders belong to their parent), labels + evidence, `set`, curated plan + cards |
| `logarch_changes.py` | stdlib | the comparison behind `CHANGES.md` |
| `logarch_triage_rules.tsv` | config | snapshot tokens, abandoned lines, kept renders, generation groups — edit, then re-run `triage` |
| `logarch_organize.py` | stdlib | organize v2: naming map → renamed complete curated plan + notes; `check` = every file in exactly one place; `docs` = master README, NAMING, RESTORE |
| `logarch_raw_rebuild.sh` | sbatch 8:00 | raw archives rebuilt without the thesis folders (→ `raw_rebuilt/`, swapped by `logarch_local.sh finalize`) |
| `logarch_organize_pipeline.sh` | sbatch 0:10 | submits curate, then raw rebuild |
| `tests/` | offline | `run_dryrun.sh` (whole pipeline on a fake `logs/`, 42 checks), fixture, rclone/zstd stand-ins |

## Order of work

```bash
# cluster (repo root) — once: conda create -y -n logarch -c conda-forge zstd rclone python ; rclone remote `gdrive` (plan §7)
./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_selftest.sh              # read SELFTEST_REPORT.md
./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_pack_gdrive.sh <STAMP>     # raw layer
# container (Drive only)
bash Slurm_Codes/download_remote_logs/logarch_local.sh fetch-meta <STAMP>
bash Slurm_Codes/download_remote_logs/logarch_local.sh triage <STAMP>                     # review TRIAGE.md, `set` to change
bash Slurm_Codes/download_remote_logs/logarch_local.sh plan-curate <STAMP>
# cluster
./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_curate.sh <STAMP>          # curated layer
# container: Claude writes README.md / RESTORE.md (ORGANIZE_PROMPT.md), then
bash Slurm_Codes/download_remote_logs/logarch_local.sh publish <STAMP>
bash Slurm_Codes/download_remote_logs/logarch_local.sh check-drive <STAMP>                # restore test
```

Options (env, set before `./Slurm_Codes/submit.sh …`; `submit.sh` exports them to the job): `ONLY_UNITS="a b"`,
`SKIP_UNITS="…"`, `FORCE_UNITS="…"` (re-pack), `TIERS="core"`, `STAGE_MODE=auto|tmp|stream`, `ZSTD_LEVEL=3`,
`MIN_FREE_GB=25` (shared-disk guard), `GDRIVE_ROOT=FMPCC_logs_backup`, `RETRY_WAIT=300` (a failing unit is
skipped, retried once after this many seconds, then listed; the job ends `partial` / exit 1). Unit names are the ones in `units_plan.tsv`
(e.g. `UAV_MIX/uav-corridor`, `solver_bench`).
