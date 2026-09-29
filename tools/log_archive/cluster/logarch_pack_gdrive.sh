#!/bin/bash
#SBATCH --job-name=logarch_pack_gdrive
#SBATCH --partition=gpu-1-student
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=08:00:00
#SBATCH --signal=B:USR1@1800
# ─────────────────────────────────────────────────────────────────────────────
# ROUTE B worker (Google Drive direct) — writes the RAW layer <GDRIVE_ROOT>/<STAMP>/raw/{archives,meta}.
# For every pending unit × tier:
#   pack → (node-local /tmp file → rclone copyto) or (stream → rclone rcat) → Drive md5 must match → receipt
# One archive at a time, nothing is staged on the shared /u/home. At the end meta/ (receipts, manifests,
# SUMMARY.*, SHA256SUMS) is uploaded next to the archives and checked. Idempotent: re-submit the same STAMP
# after a time-out or failure and it continues where it stopped (meta/receipts/*.gdrive = done).
# 30 min before the time limit it finishes the current archive and hands over to a new job by itself (≤ 5 times).
# logs/ may change while this runs: the tree is captured at the start (meta/TREE_START.tsv.gz) and at the end
# meta/CHANGES.md lists every file that differs from what the archives hold, with the FORCE_UNITS line to fix it.
# Needs: the rclone remote '$GDRIVE_REMOTE:' (plan §4.2) and a PASS of T7 in logarch_selftest.sh.
# CPU-only — no --gres, no MuJoCo/EGL.
#
#   ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_pack_gdrive.sh <STAMP>
#   env (optional): STAGE_MODE=auto|tmp|stream  ONLY_UNITS="…"  SKIP_UNITS="…"  TIERS="core"  FORCE_UNITS="…"  RETRY_WAIT=300
# A unit that fails (e.g. files still being written) is skipped, retried once after RETRY_WAIT s, then listed; the job
# goes on with everything else and exits 1 (ROUND_RESULT=partial). 3 failures in a row stop it (network/login/quota).
# ─────────────────────────────────────────────────────────────────────────────
REPO="${REPO:-$HOME/FMPCC/FM-PCC}"
source "$REPO/Slurm_Codes/sbatch/log_archive/logarch_common.sh" || exit 1
STAMP_ARG="${1:?usage: logarch_pack_gdrive.sh <STAMP>}"
job_header "logarch_pack_gdrive STAMP=$STAMP_ARG → $(remote_stamp "$STAMP_ARG")/raw"
activate_tools
have_remote || die "no rclone remote '$GDRIVE_REMOTE:' — plan §4.2, then re-run logarch_selftest.sh (T7 must PASS)"
init_stamp "$STAMP_ARG"
take_lock
apply_force
save_selection
rm -f "$META/ROUND_RESULT"
REMOTE_DIR="$(remote_stamp "$STAMP")/raw"
enable_autocontinue
[ -f "$META/TREE_START.tsv.gz" ] || { capture_tree "$META/TREE_START.tsv.gz" && log "[tree] logs/ captured at start: $(gzip -dc "$META/TREE_START.tsv.gz" | wc -l) entries"; }

pick_stage() {   # node-local disk (not tmpfs = RAM) if it has room, else stream straight into rclone rcat
    local c
    STAGE_MODE="${STAGE_MODE:-auto}"
    if [ "$STAGE_MODE" != stream ]; then
        for c in "${SLURM_TMPDIR:-}" "${TMPDIR:-}" /tmp; do
            [ -n "$c" ] && [ -d "$c" ] && [ -w "$c" ] || continue
            [ "$(stat -f -c %T "$c")" = tmpfs ] && continue
            if [ "$(free_bytes "$c")" -gt $((TMP_MIN_GB * GiB)) ]; then TMPSTAGE="$(mktemp -d "$c/logarch_stage.XXXXXX")"; break; fi
        done
        if [ -n "${TMPSTAGE:-}" ]; then STAGE_MODE=tmp; else STAGE_MODE=stream; fi
    fi
    log "[stage] $STAGE_MODE${TMPSTAGE:+ in $TMPSTAGE ($(hb "$(free_bytes "$TMPSTAGE")") free)}"
}
pick_stage
free="$(drive_free)"
log "[drive] $REMOTE_DIR | Drive free: $(hb "${free:-0}")"

up=0; FAIL_SEQ=0; SYSTEMIC=0
do_unit() {   # $1 unit $2 mode → pack + upload its pending tiers · 0 ok · 1 a tier failed · 2 time-limit stop
    local unit="$1" mode="$2" stem w t nf raw arc via bad=0
    stem="$(unit_stem "$unit")"
    unit_done "$stem" gdrive && return 0
    w="$(mktemp -d "$WORK/list.XXXXXX")"
    if ! list_unit_files "$unit" "$mode" | classify_into "$w"; then
        log "[FAIL] cannot list $unit — odd file names: $(head -c 300 "$w/bad.tsv")"; rm -rf "${w:?}"; return 1
    fi
    for t in $TIERS; do
        { [ -f "$RECEIPTS/$stem.$t.gdrive" ] || [ -f "$RECEIPTS/$stem.$t.empty" ]; } && continue
        if [ ! -s "$w/$t.tsv" ]; then mark_empty "$unit" "$mode" "$t"; continue; fi
        stop_requested "$up" && { rm -rf "${w:?}"; return 2; }
        read -r nf raw < <(tsv_stats "$w/$t.tsv")
        arc="$stem.$t.tar.zst"; via=""
        if [ "$STAGE_MODE" = tmp ] && [ "$(free_bytes "$TMPSTAGE")" -gt $((raw + 2 * GiB)) ]; then
            if pack_one "$unit" "$mode" "$t" "$w/$t.tsv" file "$TMPSTAGE" "$RECEIPTS/$stem.$t.packed"; then
                if rclone copyto "$TMPSTAGE/$arc" "$REMOTE_DIR/archives/$arc" "${RCLONE_FLAGS[@]}" \
                        && remote_md5_ok "$REMOTE_DIR/archives/$arc" "$PACK_MD5"; then
                    via=copyto
                else
                    log "[FAIL] upload or Drive md5 check of $arc"; rclone deletefile "$REMOTE_DIR/archives/$arc" >/dev/null 2>&1
                fi
            fi
            rm -f "${TMPSTAGE:?}/${arc:?}"
        else
            pack_one "$unit" "$mode" "$t" "$w/$t.tsv" rcat "$REMOTE_DIR/archives" "$RECEIPTS/$stem.$t.packed" && via=rcat
        fi
        if [ -z "$via" ]; then       # this tier failed: note it, go on with the rest (nothing half-done is kept)
            bad=1; FAIL_SEQ=$((FAIL_SEQ + 1))
            if [ "$FAIL_SEQ" -ge 3 ]; then SYSTEMIC=1; log "[stop] 3 failures in a row — network / login / quota problem?"; break; fi
            continue
        fi
        FAIL_SEQ=0
        printf 'remote=%s\nvia=%s\nmd5=%s\nuploaded_at=%s\njob=%s\n' "$REMOTE_DIR/archives/$arc" "$via" "$PACK_MD5" \
            "$(date -Iseconds)" "${SLURM_JOB_ID:-none}" > "$RECEIPTS/$stem.$t.gdrive"
        up=$((up + 1))
        log "[up] $unit [$t] $PACK_LAST | via $via"
    done
    rm -rf "${w:?}"
    return "$bad"
}

failed=()
while IFS=$'\t' read -r unit mode; do
    in_only "$unit" || continue
    do_unit "$unit" "$mode"; rc=$?
    [ "$rc" -eq 2 ] && break
    [ "$rc" -eq 1 ] && failed+=("$unit"$'\t'"$mode")
    [ "$SYSTEMIC" = 1 ] && break
done < <(list_units)
# one retry for units that failed — typically files still being written by a running job
if [ "${#failed[@]}" -gt 0 ] && [ "$STOP_REQ" != 1 ] && [ "$SYSTEMIC" != 1 ]; then
    log "[retry] ${#failed[@]} unit(s) failed — one more attempt in ${RETRY_WAIT:-300}s (files still being written?)"
    sleep "${RETRY_WAIT:-300}"
    again=(); FAIL_SEQ=0
    for e in "${failed[@]}"; do
        IFS=$'\t' read -r unit mode <<< "$e"
        do_unit "$unit" "$mode"; rc=$?
        [ "$rc" -ne 0 ] && again+=("$e")
        [ "$rc" -eq 2 ] || [ "$SYSTEMIC" = 1 ] && break
    done
    failed=("${again[@]}")
fi

if [ "$STOP_REQ" = 1 ]; then
    result=continued
else
    if [ "${#failed[@]}" -gt 0 ] || [ "$SYSTEMIC" = 1 ]; then result=partial
    elif [ -n "${ONLY_UNITS:-}${SKIP_UNITS:-}" ]; then result=subset_done; else result=all; fi
    change_report "$META"; [ $? -eq 3 ] && log "[changes] logs/ changed after packing — see meta/CHANGES.md (uploaded with meta/)"
fi
echo "$result" > "$META/ROUND_RESULT"
summarize
ledger pack_gdrive "uploaded=$up result=$result"
rclone copy "$META" "$REMOTE_DIR/meta" --exclude ".lock/**" "${RCLONE_FLAGS[@]}" || die "meta upload failed"
rclone check "$META" "$REMOTE_DIR/meta" --one-way --exclude ".lock/**" || die "meta check failed"
if [ "$result" = continued ]; then
    resubmit_self Slurm_Codes/sbatch/log_archive/logarch_pack_gdrive.sh "$STAMP" \
        || log "[continue] re-submit by hand: ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_pack_gdrive.sh $STAMP"
    log "[paused] $up archive(s) uploaded in this job; the rest continues in the next one"
    exit 0
fi
if [ "$result" = partial ]; then
    log "[partial] $up archive(s) uploaded; NOT done: $(printf '%s\n' "${failed[@]}" | cut -f1 | tr '\n' ' ')$([ "$SYSTEMIC" = 1 ] && echo '(stopped: 3 failures in a row)')"
    log "          re-submit the same command to retry only those (finished archives are skipped)"
    exit 1
fi
log "[done] $up archive(s) uploaded this run; raw layer $REMOTE_DIR complete ($result). Next (container): logarch_local.sh fetch-meta $STAMP"
