#!/bin/bash
#SBATCH --job-name=logarch_pack_stage
#SBATCH --partition=gpu-1-student
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=02:00:00
# ─────────────────────────────────────────────────────────────────────────────
# ROUTE A worker (download to the laptop). One ROUND: pack pending units into
#   export_tmp/log_archive/<STAMP>/archives/   until the staged, not-yet-pulled bytes reach BUDGET_GB,
# and never let the SHARED /u/home drop below MIN_FREE_GB free (2026-09-19: 2.9 GiB free crashed a wave).
# The laptop driver (Slurm_Codes/download_remote_logs/logarch_local.sh pull-rolling) pulls, verifies (sha256) and
# prunes between rounds, then submits the next one. Idempotent: meta/receipts decide what is done.
# CPU-only — no --gres, no MuJoCo/EGL (so no GPU isolation block is needed).
#
#   ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_pack_stage.sh <STAMP> [BUDGET_GB=20]
#   env (optional): ONLY_UNITS="UAV_MIX/uav-corridor …"  TIERS="core"  FORCE_UNITS="…"  MIN_FREE_GB=25  ZSTD_LEVEL=3
#                   STAGE_BUDGET_BYTES=… (overrides BUDGET_GB, bytes)
# meta/ROUND_RESULT: all | subset_done | budget | guard      exit 3 = not even one archive fits the free-space guard
# ─────────────────────────────────────────────────────────────────────────────
REPO="${REPO:-$HOME/FMPCC/FM-PCC}"
source "$REPO/Slurm_Codes/sbatch/log_archive/logarch_common.sh" || exit 1
STAMP_ARG="${1:?usage: logarch_pack_stage.sh <STAMP> [BUDGET_GB]}"
BUDGET_GB="${2:-${STAGE_BUDGET_GB:-20}}"
job_header "logarch_pack_stage STAMP=$STAMP_ARG budget=${BUDGET_GB}GiB"
activate_tools
init_stamp "$STAMP_ARG"
take_lock
apply_force
save_selection
rm -f "$META/ROUND_RESULT"
find "$ARCHIVES" -name '*.part' -delete                      # leftovers of a killed round (we hold the lock)
[ -f "$META/TREE_START.tsv.gz" ] || { capture_tree "$META/TREE_START.tsv.gz" && log "[tree] logs/ captured at start: $(gzip -dc "$META/TREE_START.tsv.gz" | wc -l) entries"; }

budget="${STAGE_BUDGET_BYTES:-$((BUDGET_GB * GiB))}"; guard=$((MIN_FREE_GB * GiB))
staged="$(dir_bytes "$ARCHIVES")"
log "[round] staged, not yet pulled: $(hb "$staged") | budget $(hb "$budget") | fs free $(hb "$(free_bytes "$ARCHIVES")") | guard $(hb "$guard")"

packed=0; stop=""; need=0
while IFS=$'\t' read -r unit mode; do
    in_only "$unit" || continue
    stem="$(unit_stem "$unit")"
    unit_done "$stem" packed && continue
    w="$(mktemp -d "$WORK/list.XXXXXX")"
    list_unit_files "$unit" "$mode" | classify_into "$w" || die "cannot list $unit — odd file names: $(head -c 300 "$w/bad.tsv")"
    for t in $TIERS; do
        { [ -f "$RECEIPTS/$stem.$t.packed" ] || [ -f "$RECEIPTS/$stem.$t.empty" ]; } && continue
        if [ ! -s "$w/$t.tsv" ]; then mark_empty "$unit" "$mode" "$t"; continue; fi
        read -r nf raw < <(tsv_stats "$w/$t.tsv")
        need=$((raw + raw / 50 + 64 * MiB))                  # worst case: incompressible + tar headers
        if [ "$staged" -gt 0 ] && [ $((staged + need)) -gt "$budget" ]; then stop=budget; break 2; fi
        if [ $(($(free_bytes "$ARCHIVES") - need)) -lt "$guard" ]; then stop=guard; break 2; fi
        pack_one "$unit" "$mode" "$t" "$w/$t.tsv" file "$ARCHIVES" "$RECEIPTS/$stem.$t.packed" \
            || die "pack failed: $unit [$t] — nothing half-written was kept; re-submit to retry"
        staged=$((staged + PACK_ARC_BYTES)); packed=$((packed + 1))
        log "[pack] $unit [$t] $PACK_LAST | staged $(hb "$staged")"
    done
    rm -rf "${w:?}"
done < <(list_units)

if [ -z "$stop" ]; then
    if [ -n "${ONLY_UNITS:-}${SKIP_UNITS:-}" ]; then stop=subset_done; else stop=all; fi
    log "[done] nothing left to pack ($stop)"
    change_report "$META"; [ $? -eq 3 ] && log "[changes] logs/ changed after packing — see meta/CHANGES.md"
fi
echo "$stop" > "$META/ROUND_RESULT"
summarize
ledger pack_stage "packed=$packed result=$stop staged=$staged"
if [ "$stop" = guard ] && [ "$packed" -eq 0 ] && [ "$staged" -eq 0 ]; then
    log "[stop] the next archive needs up to $(hb "$need") but only $(hb "$(free_bytes "$ARCHIVES")") is free (guard $(hb "$guard"))."
    log "       → use route B (logarch_pack_gdrive.sh), or free space first; lowering MIN_FREE_GB endangers other users' jobs"
    exit 3
fi
log "[round] $packed archive(s) this round, result=$stop, staged $(hb "$staged") → pull + verify + prune, then the next round"
