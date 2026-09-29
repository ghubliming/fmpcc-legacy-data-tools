# Plan — organize the archived logs (v2, agreed 2026-09-28)

**Status:** ✅ DONE 2026-09-28 22:00 UTC (see `PROGRESS_organize_v2.md`) · AGREED with the author 2026-09-28 · raw layer already on Drive (`gdrive:FMPCC_logs_backup/full_20260927/raw`,
98 archives, 75.3 GiB, job 26289). This replaces the "triage → curated copy" part of `PLAN_log_archive_export.md` §4.2–4.4.
**Deadline:** the Google login (test mode) expires ≈ 2026-10-04 — curate + raw rebuild jobs run before, or reconnect first.

## Decisions (author, 2026-09-28)

| # | topic | decision |
|---|---|---|
| 1 | names | curated folders get **new names in the thesis vocabulary**, concise and clear (e.g. task / engine / K / projection / threshold / seed). Old name + meaning recorded per folder (note) and in `NAMING.md` + `naming_map.tsv` |
| 2 | what is curated | **only the data the thesis uses**. Identified by tracing the claims of release `Writing/Working_Space/RELEASE/output/20260927_211754_thesis_release_ORCH_v5.31_MANUAL_REVIEW_27SEP` (+ the whole `Writing/` folder, `DA_in_Paper`) back to runs. Newest runs are the reliable ones. Everything else stays in raw |
| 3 | move, not copy (A1) | build `curated/` from the thesis runs → verify → rebuild the affected raw bundles **without** those runs → delete the old raw bundles. Nothing exists twice on Drive. Cluster `logs/` is never touched |
| 4 | internal flags | wave tags, GenX, internal codes are **not** in the new names — only in `NAMING.md` / the TSV |
| 5 | engine truth | a name like "Diffusion…" on an FM model is wrong → engine taken from the model class inside the run (FlowMatchingODE→FM, MeanFlowODE→MF, AlphaFlowODE→AF, GaussianDiffusion→diffusion) |
| 6 | Bf / smoke / test folders | stay in raw with their names; `NAMING.md` + master MD mark each as **TEST — not thesis data** with what it was |
| 7 | weights | keep all weights of curated runs (no best-only filtering); curated runs move **complete** (no GIF / checkpoint dropping — under A1 anything dropped would be lost) |
| 8 | config snapshots | `config_snapshot_*` kept; notes say: timestamps reliably record the last run, the yaml/py copies may not match what ran — use with caution |
| 9 | master MD | English, for thesis readers: which files are data (npz, results.json, plots, logs, losses, weights), which are garbage to ignore (renders, runlogs, lock/receipt files, test folders), how to restore |
| — | not wanted | no table/figure → data map (thesis wording like "K2 MF thr0.5" is enough to find a folder) |

## Steps

1. **Prep (2026-09-28):** install `rclone` + `zstd` in the container; author adds the `[gdrive]` config; fetch `raw/meta` of `full_20260927`.
2. **Identify thesis data:** claims of release v5.31 + Writing + DA_in_Paper → run folders, each with the thesis wording it matches.
3. **Naming draft** (`NAMING.md` + TSV) → **author reviews before anything is built.**
4. **Code changes** (after review): curated build with renames and no drops, raw rebuild without the moved runs, master MD, notes per folder → dry run → smoke test.
5. **Cluster jobs:** curate → verify (`check-drive`) → raw rebuild → verify → delete old raw bundles.
6. **Publish** master MD, `NAMING.md`, notes; `logarch_changes.sh` before anything on the cluster is ever cleaned.
