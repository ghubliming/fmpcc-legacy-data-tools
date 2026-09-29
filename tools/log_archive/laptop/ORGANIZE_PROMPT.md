# ORGANIZE_PROMPT — Claude's part of the log archive (triage review + catalog)

Paste into Claude Code in this repo, with `<STAMP>` filled in. Bundle = `$LOCAL_ROOT/<STAMP>/`
(default `/workspaces/FMPCC_log_archive/<STAMP>/`). Plan: `logs_in_develop/Log_Archive_Export/PLAN_log_archive_export.md`.

---

**Task A — review the triage (after `logarch_local.sh triage <STAMP>`).**
Read `triage/TRIAGE.md` and `triage/TRIAGE.tsv` of the bundle, plus `raw/meta/SUMMARY.md`. Context, read-only:
`logs_in_develop/MASTER_TEST_HISTORY.md` (Master Trace Map), the generation folders in `logs_in_develop/`,
`Data_Analysis/DA_in_Paper/analysis/INDEX.md`, `Slurm_Codes/archived_temp_bash/README.md`, `.claude/memory/`.
1. Check every `include = no` row: is the snapshot/abandoned call right? Is anything cited by the thesis being dropped?
2. Check `unmapped` rows and `group` values; propose rules for `Slurm_Codes/sbatch/log_archive/logarch_triage_rules.tsv`.
3. Look for runs the rules cannot see: known-bad runs named in dev logs or memory (e.g. truncated or invalid waves),
   duplicates, smoke runs without a marker in their name.
4. Write the proposals into `triage/REVIEW.md` as a table: path glob · current → proposed include/group · reason · source
   file. **Do not apply them.** After the author approves, apply with
   `logarch_local.sh set <STAMP> --match '<glob>' --include yes|no [--group G] --note '<reason>'`, then `plan-curate`.

**Task B — write the catalog (after `logarch_curate.sh` finished).**
Write two files in the bundle root, then run `logarch_local.sh publish <STAMP>`:
- `README.md` — the entry point of `gdrive:FMPCC_logs_backup/<STAMP>/`:
  - what the stamp is: date, source `/u/home/llim/FMPCC/FM-PCC/logs`, totals from `raw/meta/SUMMARY.md`;
  - the three layers (`raw/` = everything, never edited · `triage/` = the decisions · `curated/` = the organised copy);
  - one table per generation group: folder → one-line purpose → label → size → dev-log source;
  - what was left out of `curated/`, and why (from TRIAGE), and that it is all still in `raw/`;
  - the verification status: receipts, `CHANGES.md`, `check-drive`.
- `RESTORE.md`, covering:
  - restoring a whole unit from `raw/` (all tiers into the repo root);
  - restoring one curated folder;
  - listing an archive without extracting it;
  - fetching a single file via the manifests;
  - verifying with `SHA256SUMS`.
  Use the real archive names of this stamp.

**Rules.**
- Every mapping or purpose statement cites the file it comes from. Write "unmapped" when unsure — never guess.
- Never edit archives, `raw/meta`, `MASTER_TEST_HISTORY.md` or `important_runs.md` — offer changes instead.
- No web links: Drive locations are written as rclone paths (`gdrive:FMPCC_logs_backup/<STAMP>/…`).
- Sizes come from `SUMMARY.md` / `TRIAGE.tsv`, not from estimates.
- Finish with a self-check:
  - every `include = yes` row of `TRIAGE.tsv` has a curated folder named in `README.md` or `INDEX_auto.md`;
  - every archive in `raw/meta/SHA256SUMS` is reachable from `RESTORE.md`.
