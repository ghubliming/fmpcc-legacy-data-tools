# tools/log_archive — the cluster `logs/` → Google Drive backup

How ~100 GiB / 300k files of experiment logs were taken off the Slurm cluster into verified, compressed archives on
Google Drive, then organised into a browsable copy with a catalog — without ever moving or deleting anything on the
cluster. Copied as-is from the development repository (paths, user and host names are the original ones).

| folder | what |
|---|---|
| `notes/PLAN_log_archive_export.md` | **read first** — the design: why Drive via Slurm jobs, the three layers (`raw/` = everything as it was · `triage/` = reviewed decisions · `curated/` = the organised copy), the one-pass packer (tar → zstd → sha256/md5 → decode-and-list check → `rclone rcat`), receipts and idempotent re-runs, the 24 h auto-continue, tests, the runbook (one-time setup incl. the rclone remote with your own client ID), risks |
| `notes/PLAN_organize_v2.md` · `notes/PROGRESS_organize_v2.md` | the second pass: the runs that matter get clear names in `curated/`, the rest stays in `raw/`, "move, don't copy" so nothing exists twice; the timeline of the real run |
| `notes/CHANGELOG_log_archive_v1.md` | one entry per working pass, the dry-run / smoke-test / real-run results and the lessons (its last sections describe a later one-off relabel job that is **not** included here, on purpose) |
| `cluster/` | the Slurm jobs: `logarch_selftest.sh` (init: tools, disk, round-trip, Drive reachability) → `logarch_pack_gdrive.sh` (raw layer) → `logarch_curate.sh` (curated layer from an approved plan) → `logarch_raw_rebuild.sh` (raw archives without the curated runs); `logarch_changes.sh` (did `logs/` change since?); shared library `logarch_common.sh`; stdlib helpers (triage, organize, summarize); `tests/` = offline dry run on a fake `logs/` with stand-ins for rclone and zstd. Its own `README.md` has the Drive layout and the order of work |
| `laptop/` | the container / laptop side: `logarch_local.sh` (fetch the metadata, triage, build the curate plan, organize, finalize the swap, publish the catalog, restore test), `export_to_laptop.sh` (the older ssh route), `ORGANIZE_PROMPT.md` (the brief handed to an AI assistant for the triage review and the catalog text) |
| `cleanup/` | small helpers used around the archive: folder-tree snapshot, GIF / weight / log clean-ups, splitting files > 100 MB |

Needs on the cluster: a conda env with `zstd`, `rclone`, `python` (stdlib only), GNU tar; an rclone remote `gdrive`
(scope `drive.file`). Compute nodes must reach Google Drive (route B); if they do not, route A stages archives on the
cluster disk and the laptop pulls them over ssh.
