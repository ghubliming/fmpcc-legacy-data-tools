#!/bin/bash
#SBATCH --job-name=logarch_raw_rebuild
#SBATCH --partition=gpu-1-student
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=08:00:00
#SBATCH --signal=B:USR1@1800
# ─────────────────────────────────────────────────────────────────────────────
# ORGANIZE v2 (A1, "move, don't copy"): rebuild the raw archives that hold thesis folders WITHOUT those folders.
# The approved CURATE_PLAN (<GDRIVE_ROOT>/<STAMP>/triage, sha256-checked) names every file that moves to curated/.
# Every raw unit containing any of them is re-listed from logs/ (read-only), those files are removed, and the rest is
# packed tier by tier (same one-pass checks, Drive md5) into <STAMP>/raw_rebuilt/. Units without thesis folders are not
# repacked. Nothing in raw/ is changed here: `logarch_local.sh finalize <STAMP>` first proves that every archived file is
# in exactly one place (curated or rebuilt raw), then swaps the archives and sends the old ones to the Drive trash.
# Idempotent + auto-continue near the time limit, like logarch_pack_gdrive.sh. CPU-only (no --gres, no MuJoCo/EGL).
#   ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_raw_rebuild.sh <STAMP>
# ─────────────────────────────────────────────────────────────────────────────
REPO="${REPO:-$HOME/FMPCC/FM-PCC}"
source "$REPO/Slurm_Codes/sbatch/log_archive/logarch_common.sh" || exit 1
STAMP="${1:?usage: logarch_raw_rebuild.sh <STAMP>}"
[[ "$STAMP" =~ ^[A-Za-z0-9._-]+$ ]] || die "bad STAMP"
job_header "logarch_raw_rebuild STAMP=$STAMP → $(remote_stamp "$STAMP")/raw_rebuilt"
activate_tools
have_remote || die "no rclone remote '$GDRIVE_REMOTE:'"
set_bundle "$EXPORT_ROOT/$STAMP/rebuild"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/logarch_rebuild.XXXXXX")" || die "no work dir"
take_lock
enable_autocontinue
RS="$(remote_stamp "$STAMP")"; REMOTE_DIR="$RS/raw_rebuilt"

# ── the approved plan → the set of files that moved to curated/ ─────────────
rclone copyto "$RS/triage/CURATE_PLAN.tsv.gz" "$STAMP_DIR/CURATE_PLAN.tsv.gz" "${RCLONE_FLAGS[@]}" \
    && rclone copyto "$RS/triage/CURATE_PLAN.sha256" "$STAMP_DIR/CURATE_PLAN.sha256" "${RCLONE_FLAGS[@]}" || die "no plan on Drive"
(cd "$STAMP_DIR" && sha256sum -c --quiet CURATE_PLAN.sha256) || die "CURATE_PLAN.tsv.gz does not match its sha256 — refusing"
gzip -dc "$STAMP_DIR/CURATE_PLAN.tsv.gz" | awk -F'\t' '$2 == "pack" { print $5 }' | LC_ALL=C sort -u > "$WORK/moved.txt"
log "[plan] $(wc -l < "$WORK/moved.txt") entries moved to curated/ (plan sha256 $(cut -c1-12 "$STAMP_DIR/CURATE_PLAN.sha256"))"
pick_stage() {
    local c; STAGE_MODE="${STAGE_MODE:-auto}"
    if [ "$STAGE_MODE" != stream ]; then
        for c in "${SLURM_TMPDIR:-}" "${TMPDIR:-}" /tmp; do
            [ -n "$c" ] && [ -d "$c" ] && [ -w "$c" ] || continue
            [ "$(stat -f -c %T "$c")" = tmpfs ] && continue
            if [ "$(free_bytes "$c")" -gt $((TMP_MIN_GB * GiB)) ]; then TMPSTAGE="$(mktemp -d "$c/logarch_stage.XXXXXX")"; break; fi
        done
        if [ -n "${TMPSTAGE:-}" ]; then STAGE_MODE=tmp; else STAGE_MODE=stream; fi
    fi
    log "[stage] $STAGE_MODE"
}
pick_stage

up=0; untouched=0; failed=()
while IFS=$'\t' read -r unit mode; do
    in_only "$unit" || continue
    stem="$(unit_stem "$unit")"
    unit_done "$stem" gdrive && continue
    w="$(mktemp -d "$WORK/list.XXXXXX")"
    list_unit_files "$unit" "$mode" > "$w/all.tsv"
    awk -F'\t' 'NR == FNR { m[$0] = 1; next } ($4 in m) { n++ } END { exit (n > 0 ? 0 : 1) }' "$WORK/moved.txt" "$w/all.tsv" \
        || { untouched=$((untouched + 1)); rm -rf "${w:?}"; continue; }             # no thesis folder in this unit
    awk -F'\t' 'NR == FNR { m[$0] = 1; next } !($4 in m)' "$WORK/moved.txt" "$w/all.tsv" | classify_into "$w" \
        || { log "[FAIL] cannot list $unit"; failed+=("$unit"); rm -rf "${w:?}"; continue; }
    for t in $TIERS; do
        { [ -f "$RECEIPTS/$stem.$t.gdrive" ] || [ -f "$RECEIPTS/$stem.$t.empty" ]; } && continue
        if [ ! -s "$w/$t.tsv" ]; then mark_empty "$unit" "$mode" "$t"; log "[empty] $unit [$t] — everything of this tier moved to curated/"; continue; fi
        stop_requested "$up" && break 2
        read -r nf raw < <(tsv_stats "$w/$t.tsv"); arc="$stem.$t.tar.zst"; via=""
        if [ "$STAGE_MODE" = tmp ] && [ "$(free_bytes "$TMPSTAGE")" -gt $((raw + 2 * GiB)) ]; then
            if pack_one "$unit" "$mode" "$t" "$w/$t.tsv" file "$TMPSTAGE" "$RECEIPTS/$stem.$t.packed"; then
                rclone copyto "$TMPSTAGE/$arc" "$REMOTE_DIR/archives/$arc" "${RCLONE_FLAGS[@]}" && remote_md5_ok "$REMOTE_DIR/archives/$arc" "$PACK_MD5" && via=copyto
            fi
            rm -f "${TMPSTAGE:?}/${arc:?}"
        else
            pack_one "$unit" "$mode" "$t" "$w/$t.tsv" rcat "$REMOTE_DIR/archives" "$RECEIPTS/$stem.$t.packed" && via=rcat
        fi
        if [ -z "$via" ]; then log "[FAIL] $unit [$t]"; failed+=("$unit [$t]"); continue; fi
        printf 'remote=%s\nvia=%s\nmd5=%s\nuploaded_at=%s\njob=%s\n' "$REMOTE_DIR/archives/$arc" "$via" "$PACK_MD5" "$(date -Iseconds)" \
            "${SLURM_JOB_ID:-none}" > "$RECEIPTS/$stem.$t.gdrive"
        up=$((up + 1)); log "[rebuilt] $unit [$t] $PACK_LAST (thesis folders removed) | via $via"
    done
    rm -rf "${w:?}"
done < <(list_units)

summarize
rclone copy "$META" "$REMOTE_DIR/meta" --exclude ".lock/**" "${RCLONE_FLAGS[@]}" || die "meta upload failed"
rclone check "$META" "$REMOTE_DIR/meta" --one-way --exclude ".lock/**" || die "meta check failed"
ledger raw_rebuild "rebuilt=$up untouched=$untouched failed=${#failed[@]} stop=$STOP_REQ"
if [ "$STOP_REQ" = 1 ]; then
    resubmit_self Slurm_Codes/sbatch/log_archive/logarch_raw_rebuild.sh "$STAMP" || log "[continue] re-submit by hand"
    log "[paused] $up archive(s) rebuilt in this job; the rest continues in the next one"; exit 0
fi
if [ "${#failed[@]}" -gt 0 ]; then log "[partial] NOT done: ${failed[*]} — re-submit the same command"; exit 1; fi
log "[done] $up archive(s) rebuilt without the thesis folders, $untouched unit(s) untouched → $REMOTE_DIR. Next (container): logarch_local.sh finalize $STAMP"
