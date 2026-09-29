#!/bin/bash
#SBATCH --job-name=logarch_changes
#SBATCH --partition=gpu-1-student
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --time=00:30:00
# ─────────────────────────────────────────────────────────────────────────────
# Did logs/ change after <STAMP> was archived? Lists logs/ now (read-only) and compares it with the stamp's
# manifests → export_tmp/log_archive/<STAMP>/meta/CHANGES.md + CHANGES.tsv (uploaded to Drive raw/meta when the
# rclone remote exists). Run it before you trust the archive as "the" copy, and before cleaning anything on the
# cluster. The pack jobs run the same check at their end. CPU-only, ~minutes.
#   ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_changes.sh <STAMP>
# exit 0 = logs/ equals the archives · 3 = changes (CHANGES.md prints the FORCE_UNITS line that re-packs them)
# ─────────────────────────────────────────────────────────────────────────────
REPO="${REPO:-$HOME/FMPCC/FM-PCC}"
source "$REPO/Slurm_Codes/sbatch/log_archive/logarch_common.sh" || exit 1
job_header "logarch_changes STAMP=${1:-?}"
activate_tools
init_stamp "${1:?usage: logarch_changes.sh <STAMP>}"
[ -n "$(find "$MANIFESTS" -name '*.tsv.gz' -print -quit)" ] || die "no manifests for $STAMP here ($MANIFESTS)"
change_report "$META"; rc=$?
if have_remote; then
    for f in CHANGES.md CHANGES.tsv; do rclone copyto "$META/$f" "$(remote_stamp "$STAMP")/raw/meta/$f" "${RCLONE_FLAGS[@]}" || log "[warn] upload of $f failed"; done
fi
sed -n '1,40p' "$META/CHANGES.md"
exit "$rc"
