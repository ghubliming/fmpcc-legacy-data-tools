#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# smoke_cluster.sh — the whole log-archive pipeline on a few SMALL real folders, end to end, in one command.
# Run it on the cluster (login node). It only submits the Slurm jobs, waits for them and runs the light steps in
# between; the restore test runs on a compute node (srun). Read-only on logs/. Takes ~5–15 min incl. queue waits.
#
#   bash Slurm_Codes/sbatch/log_archive/tests/smoke_cluster.sh                          # STAMP smoke_<date>_<time>
#   nohup bash Slurm_Codes/sbatch/log_archive/tests/smoke_cluster.sh > smoke.log 2>&1 &   # keeps running if ssh drops
#   UNITS="uav_naive solver_bench" bash …/smoke_cluster.sh [STAMP]                      # other folders
#   CLEAN=1 bash …/smoke_cluster.sh                                                     # delete the smoke copy afterwards
#
# Needs the one-time setup (plan §7): conda env `logarch`, rclone remote `gdrive`.
# Stages: 1 raw → Drive (job) · 2 triage + curate plan · 3 curated layer (job) · 4 change check (job)
#         5 publish · 6 full restore test from Drive (srun)  → PASS/FAIL table at the end.
# ─────────────────────────────────────────────────────────────────────────────
set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
cd "$REPO" || exit 1
STAMP="${1:-smoke_$(date +%Y%m%d_%H%M)}"
UNITS="${UNITS:-uav_naive solver_bench aligning-d3il-visual/mix_visual_aligning_fm avoiding-d3il-visual(1e4_EMA_changed)}"
POLL="${POLL:-20}"
CONDA_DIR="${CONDA_DIR:-$HOME/miniconda3}"
export LOCAL_ROOT="${LOCAL_ROOT:-$HOME/FMPCC_log_archive}"
L="$REPO/Slurm_Codes/download_remote_logs/logarch_local.sh"
J="Slurm_Codes/sbatch/log_archive"
ROWS=(); FAILS=0

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
row() { ROWS+=("$(printf '%-5s %-9s %s' "$1" "$2" "$3")"); [ "$1" = FAIL ] && FAILS=$((FAILS + 1)); log "[$1] $2 — $3"; }
finish() {
    echo; echo "log-archive smoke test $STAMP — $(date '+%Y-%m-%d %H:%M')"
    printf '  %s\n' "${ROWS[@]}"
    echo "  Drive:   gdrive:FMPCC_logs_backup/$STAMP   (raw/ triage/ curated/ TRIAGE.md INDEX_auto.md)"
    echo "  local:   $LOCAL_ROOT/$STAMP   ·   cluster: export_tmp/log_archive/$STAMP"
    if [ "$FAILS" -eq 0 ]; then echo "  SMOKE TEST PASS"; else echo "  SMOKE TEST FAIL ($FAILS)"; fi
    [ "${CLEAN:-0}" = 1 ] || echo "  remove later: CLEAN=1 re-run, or  rclone purge gdrive:FMPCC_logs_backup/$STAMP && rm -r export_tmp/log_archive/$STAMP $LOCAL_ROOT/$STAMP logs_in_develop/Log_Archive_Export/catalog_$STAMP"
    exit "$1"
}
submit() {   # submit <script> [args…] → prints the job id (submit.sh names the log …/<time>_<job>_<id>.log)
    local out
    out="$(bash Slurm_Codes/submit.sh "$@" 2>&1)" || { printf '%s\n' "$out" >&2; return 1; }
    printf '%s\n' "$out" | sed -n 's/.*Job ID:[^0-9]*\([0-9][0-9]*\).*/\1/p' | tail -n 1
}
wait_job() { # wait_job <id> → JOB_STATE JOB_EXIT JOB_LOG; 0 when COMPLETED
    local jid="$1" st="" ex="" last="" gone=0
    while :; do
        st=""; ex=""
        read -r st ex < <(sacct -n -X -j "$jid" -o State%20,ExitCode%8 2>/dev/null | awk 'NR == 1 { print $1, $2 }')
        case "$st" in
            PENDING|RUNNING|REQUEUED|SUSPENDED|CONFIGURING|COMPLETING) gone=0 ;;
            "") if [ -n "$(squeue -h -j "$jid" 2>/dev/null)" ]; then gone=0; else gone=$((gone + 1)); fi
                [ "$gone" -gt 6 ] && { st=UNKNOWN; break; } ;;
            *) break ;;
        esac
        [ -n "$st" ] && [ "$st" != "$last" ] && log "  job $jid $st"
        last="$st"; sleep "$POLL"
    done
    JOB_STATE="$st"; JOB_EXIT="$ex"
    JOB_LOG="$(ls -1 Slurm_Codes/logs/*/*_"$jid".log 2>/dev/null | tail -n 1)"
    log "  job $jid $st (exit ${ex:-?}) · log ${JOB_LOG:-?}"
    [ "$st" = COMPLETED ]
}
show_tail() { [ -n "${JOB_LOG:-}" ] && { echo "  ── last lines of $JOB_LOG"; tail -n 25 "$JOB_LOG" | sed 's/^/  │ /'; }; }

# ── 0. preflight ──────────────────────────────────────────────────────────────
# shellcheck disable=SC1091
source "$CONDA_DIR/etc/profile.d/conda.sh" 2>/dev/null && conda activate logarch 2>/dev/null \
    || { echo "conda env 'logarch' not found (plan §7: conda create -y -n logarch -c conda-forge zstd rclone python)"; exit 1; }
for t in sbatch sacct squeue srun rclone zstd python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing '$t' on this machine"; exit 1; }
done
rclone about gdrive: --contimeout 15s --timeout 30s --retries 1 >/dev/null 2>&1 \
    || { echo "rclone remote 'gdrive:' not configured or not reachable (plan §7, step 2)"; exit 1; }
[[ "$STAMP" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "STAMP must match [A-Za-z0-9._-]+"; exit 1; }
log "smoke test $STAMP · repo $REPO (git $(git rev-parse --short HEAD 2>/dev/null)) · units: $UNITS"

# ── 1. raw layer → Drive ──────────────────────────────────────────────────────
export ONLY_UNITS="$UNITS"
jid="$(submit "$J/logarch_pack_gdrive.sh" "$STAMP")"; unset ONLY_UNITS
[ -n "$jid" ] || { row FAIL raw "submit failed"; finish 1; }
log "1/6 raw layer → Drive: job $jid"
if wait_job "$jid"; then
    row PASS raw "$(grep -c '\[up\]' "$JOB_LOG") archive(s) uploaded + md5-checked · $(grep -o 'Drive free: .*' "$JOB_LOG" | head -n 1)"
else
    row FAIL raw "job $JOB_STATE"; show_tail; finish 1
fi

# ── 2. triage + curate plan (login node, light) ──────────────────────────────
log "2/6 fetch-meta · triage · plan-curate"
if bash "$L" fetch-meta "$STAMP" && bash "$L" triage "$STAMP" && bash "$L" plan-curate "$STAMP"; then
    row PASS triage "$(awk -F'\t' 'NR > 1 { n[$2]++ } END { printf "%d rows: include %d · exclude %d", n["yes"] + n["no"], n["yes"], n["no"] }' \
        "$LOCAL_ROOT/$STAMP/triage/TRIAGE.tsv") → $LOCAL_ROOT/$STAMP/triage/TRIAGE.md"
else
    row FAIL triage "see the messages above"; finish 1
fi

# ── 3. curated layer ──────────────────────────────────────────────────────────
jid="$(submit "$J/logarch_curate.sh" "$STAMP")"
[ -n "$jid" ] || { row FAIL curate "submit failed"; finish 1; }
log "3/6 curated layer: job $jid"
if wait_job "$jid"; then
    row PASS curate "$(grep -c '\[curated\]' "$JOB_LOG") folder(s) → curated/ (archive + key files, md5/rclone-checked)"
else
    row FAIL curate "job $JOB_STATE"; show_tail; finish 1
fi

# ── 4. did logs/ change after packing? ───────────────────────────────────────
jid="$(submit "$J/logarch_changes.sh" "$STAMP")"
[ -n "$jid" ] || { row FAIL changes "submit failed"; finish 1; }
log "4/6 change check: job $jid"
if wait_job "$jid"; then
    row PASS changes "logs/ still equals the archives"
elif [ "${JOB_EXIT%%:*}" = 3 ]; then
    row WARN changes "logs/ changed after packing — export_tmp/log_archive/$STAMP/meta/CHANGES.md"
else
    row FAIL changes "job $JOB_STATE"; show_tail
fi

# ── 5. publish cards + catalog ────────────────────────────────────────────────
log "5/6 publish"
if bash "$L" publish "$STAMP"; then row PASS publish "cards → curated/, TRIAGE.md + INDEX_auto.md → Drive"
else row FAIL publish "see the messages above"; fi

# ── 6. full restore test from Drive (compute node) ───────────────────────────
log "6/6 check-drive on a compute node (downloads every smoke archive, restores, compares)"
if srun -p gpu-1-student -c 2 --mem=4G -t 00:30:00 --job-name=logarch_smoke_check \
        bash "$L" check-drive "$STAMP" 0 2>&1 | tee "$LOCAL_ROOT/$STAMP/check-drive.log"; then
    row PASS restore "every raw unit and curated folder restored and matched (check-drive.log)"
else
    row FAIL restore "see $LOCAL_ROOT/$STAMP/check-drive.log"
fi
rm -rf "${LOCAL_ROOT:?}/${STAMP:?}/check"

# ── optional clean-up ─────────────────────────────────────────────────────────
if [ "${CLEAN:-0}" = 1 ]; then
    rclone purge "gdrive:FMPCC_logs_backup/$STAMP" && rm -rf "${REPO:?}/export_tmp/log_archive/${STAMP:?}" "${LOCAL_ROOT:?}/${STAMP:?}" \
        "${REPO:?}/logs_in_develop/Log_Archive_Export/catalog_${STAMP:?}" && log "[clean] smoke copy $STAMP removed (Drive + cluster)"
fi
if [ "$FAILS" -eq 0 ]; then finish 0; else finish 1; fi
