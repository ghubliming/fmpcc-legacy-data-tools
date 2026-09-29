#!/bin/bash
#SBATCH --job-name=logarch_organize_pipeline
#SBATCH --partition=gpu-1-student
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --time=00:10:00
# ─────────────────────────────────────────────────────────────────────────────
# ORGANIZE v2 on the cluster, one command: submits
#   1. logarch_curate.sh       <STAMP>  thesis folders → Drive curated/<task>/…/<clear name>/ (complete, renamed)
#   2. logarch_raw_rebuild.sh  <STAMP>  (after 1 succeeded) raw archives rebuilt without those folders → raw_rebuilt/
# Both read logs/ only and follow the approved plan on Drive (triage/CURATE_PLAN, sha256-checked). Each job keeps its own
# time budget and hands over to a new job near its limit. Afterwards (container): logarch_local.sh finalize + publish-organized.
#   ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_organize_pipeline.sh <STAMP>
# ─────────────────────────────────────────────────────────────────────────────
set -e
STAMP="${1:?usage: logarch_organize_pipeline.sh <STAMP>}"
REPO="${REPO:-$HOME/FMPCC/FM-PCC}"; cd "$REPO"
DATE=${SUBMIT_DATE:-$(date +%Y-%m-%d)}; TIME=${SUBMIT_TIME:-$(date +%H_%M_%S)}
LOG_DIR="Slurm_Codes/logs/$DATE"; mkdir -p "$LOG_DIR"
LOG_OPTS=(--output="$LOG_DIR/${TIME}_%x_%j.log" --error="$LOG_DIR/${TIME}_%x_%j.log")
J1=$(sbatch --parsable "${LOG_OPTS[@]}" --job-name=logarch_curate Slurm_Codes/sbatch/log_archive/logarch_curate.sh "$STAMP")
echo "1 curate      job $J1"
J2=$(sbatch --parsable "${LOG_OPTS[@]}" --job-name=logarch_raw_rebuild --dependency=afterok:"$J1" Slurm_Codes/sbatch/log_archive/logarch_raw_rebuild.sh "$STAMP")
echo "2 raw rebuild job $J2 (starts after $J1 succeeded)"
echo "logs: $LOG_DIR/${TIME}_logarch_*.log · then in the container: logarch_local.sh finalize $STAMP && logarch_local.sh publish-organized $STAMP"
