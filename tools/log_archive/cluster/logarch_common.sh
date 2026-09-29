#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# logarch_common.sh — config + functions shared by the log-archive jobs. SOURCED, never run.
#   logarch_selftest.sh     INIT job: compress → verify → restore tests, tree plan, speed probe, Drive round-trip
#   logarch_pack_stage.sh   route A worker: pack into export_tmp/log_archive/<STAMP>/archives, budget-bounded rounds
#   logarch_pack_gdrive.sh  route B worker: pack + upload to Google Drive one archive at a time (nothing on /u/home)
#   logarch_curate.sh       curated layer: packs the runs of an approved CURATE_PLAN into Drive curated/ (read-only on logs/)
# Plan: logs_in_develop/Log_Archive_Export/PLAN_log_archive_export.md · Drive: <GDRIVE_ROOT>/<STAMP>/{raw,triage,curated}
#
# unit    = one folder under logs/ (SPLIT_UNITS trees one level deeper; their loose files form "<tree>/_files")
# tier    = core (everything else) | media (gif png jpg svg mp4 pdf …) | weights (pt pth ckpt safetensors)
# archive = <stem>.<tier>.tar.zst; member paths start with "logs/", so extracting in the repo root restores the tree
# Every archive is written, hashed and verified in ONE pass:
#   tar -c | zstd | tee ─┬─ sha256sum, md5sum
#                        ├─ zstd -dc | tar -tv → file count + bytes must equal the manifest
#                        └─ sink: staged file | rclone rcat | wc -c (probe)
# ─────────────────────────────────────────────────────────────────────────────
set -o pipefail

REPO="${REPO:-$HOME/FMPCC/FM-PCC}"
LOGARCH_DIR="$REPO/Slurm_Codes/sbatch/log_archive"
LOGS_REL="${LOGS_REL:-logs}"
EXPORT_ROOT="${EXPORT_ROOT:-$REPO/export_tmp/log_archive}"          # gitignored (export_tmp)
SPLIT_UNITS="${SPLIT_UNITS:-aligning-d3il-visual avoiding-d3il UAV_MIX UAV_FM}"
MEDIA_EXT="${MEDIA_EXT:-gif png jpg jpeg svg mp4 webm avi mov mkv pdf eps}"
WEIGHTS_EXT="${WEIGHTS_EXT:-pt pth ckpt safetensors}"
TIERS="${TIERS:-core media weights}"
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"
THREADS="${THREADS:-${SLURM_CPUS_PER_TASK:-4}}"
MIN_FREE_GB="${MIN_FREE_GB:-25}"        # never let the SHARED /u/home drop below this because of us
TMP_MIN_GB="${TMP_MIN_GB:-30}"          # node-local staging (route B) only when this much is free
GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
GDRIVE_ROOT="${GDRIVE_ROOT:-FMPCC_logs_backup}"
CONDA_DIR="${CONDA_DIR:-$HOME/miniconda3}"
TOOLS_ENV="${TOOLS_ENV:-logarch}"       # conda env with zstd + rclone + python (one-time setup, plan §4)
RCLONE_FLAGS=(--drive-chunk-size "${DRIVE_CHUNK:-128M}" --drive-stop-on-upload-limit
              --retries 5 --low-level-retries 20 --stats 5m --stats-one-line --stats-log-level NOTICE)
GiB=$((1024 * 1024 * 1024))
PACK_TAR_EXTRA=()
MiB=$((1024 * 1024))
FMT='%y\t%s\t%TY-%Tm-%Td %TH:%TM:%TS\t%p\n'   # manifest line: type bytes mtime(sub-second) path

log()   { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()   { log "FATAL: $*"; exit 1; }
hb()    { numfmt --to=iec-i --suffix=B --format='%.1f' "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }
ratio() { awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) printf "%.2f", a / b; else printf "-" }'; }
rget()  { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null; }
free_bytes() { df -B1 --output=avail "$1" 2>/dev/null | awk 'NR == 2 { print $1 }'; }
dir_bytes()  { find "$1" -type f -printf '%s\n' 2>/dev/null | awk '{ s += $1 } END { printf "%.0f", s }'; }
tsv_stats()  { awk -F'\t' '$1 == "f" { n++; b += $2 } END { printf "%.0f %.0f\n", n, b }' "$1"; }

job_header() {
    log "================================================================================"
    log "$1 | job ${SLURM_JOB_ID:-none} on $(hostname) | cpus ${SLURM_CPUS_PER_TASK:-?} | zstd -$ZSTD_LEVEL -T$THREADS"
    log "repo $REPO (git $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?'))"
    log "================================================================================"
    if [ -n "${CUDA_VISIBLE_DEVICES:-}" ]; then log "[warn] a GPU is allocated — this job is CPU-only, submit it without --gres"; fi
    trap on_exit EXIT
    trap 'exit 143' TERM INT              # Slurm time limit / scancel → still run the EXIT cleanup
}
on_exit() {
    if [ -n "${WORK:-}" ]; then rm -rf "${WORK:?}"; fi
    if [ -n "${TMPSTAGE:-}" ]; then rm -rf "${TMPSTAGE:?}"; fi
    release_lock
}

activate_tools() {
    if [ -f "$CONDA_DIR/etc/profile.d/conda.sh" ]; then
        # shellcheck disable=SC1091
        source "$CONDA_DIR/etc/profile.d/conda.sh"
        conda activate "$TOOLS_ENV" 2>/dev/null || log "[warn] conda env '$TOOLS_ENV' not found — using tools from PATH"
    fi
    command -v zstd >/dev/null 2>&1 \
        || die "zstd not found. One-time setup on the login node: conda create -y -n $TOOLS_ENV -c conda-forge zstd rclone python"
    case "$(tar --version 2>/dev/null)" in *"GNU tar"*) ;; *) die "GNU tar required" ;; esac
    PY="$(command -v python3 || command -v python || true)"
}

# ── units ───────────────────────────────────────────────────────────────────────
is_split()  { local s; for s in $SPLIT_UNITS; do [ "$s" = "$1" ] && return 0; done; return 1; }
in_only()   {     # ONLY_UNITS / SKIP_UNITS (space-separated unit names, as in units_plan.tsv)
    local u
    for u in ${SKIP_UNITS:-}; do [ "$u" = "$1" ] && return 1; done
    [ -z "${ONLY_UNITS:-}" ] && return 0
    for u in $ONLY_UNITS; do [ "$u" = "$1" ] && return 0; done
    return 1
}
unit_stem() { printf '%s' "$1" | sed -e 's#/#__#g' -e 's#[^A-Za-z0-9._+-]#_#g'; }
has_loose() { [ -n "$(find "$1" -mindepth 1 -maxdepth 1 ! -type d -print -quit 2>/dev/null)" ]; }

list_units() {   # → "<unit>\t<mode>" lines; unit is relative to logs/, mode = tree | loose
    local top="$REPO/$LOGS_REL" name sub
    [ -d "$top" ] || die "no $top"
    has_loose "$top" && printf '_toplevel_files\tloose\n'
    while IFS= read -r name; do
        if is_split "$name"; then
            has_loose "$top/$name" && printf '%s/_files\tloose\n' "$name"
            while IFS= read -r sub; do printf '%s/%s\ttree\n' "$name" "$sub"; done \
                < <(find "$top/$name" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort)
        else
            printf '%s\ttree\n' "$name"
        fi
    done < <(find "$top" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort)
}

unit_root() {    # $1 unit  $2 mode → path relative to REPO that the unit covers
    if [ "$2" = loose ]; then
        if [ "$1" = _toplevel_files ]; then printf '%s' "$LOGS_REL"; else printf '%s/%s' "$LOGS_REL" "${1%/_files}"; fi
    else
        printf '%s/%s' "$LOGS_REL" "$1"
    fi
}

list_unit_files() {   # $1 unit  $2 mode → manifest lines (files, symlinks, empty dirs), paths relative to REPO
    local root; root="$(unit_root "$1" "$2")"
    if [ "$2" = loose ]; then
        (cd "$REPO" && find "$root" -mindepth 1 -maxdepth 1 ! -type d -printf "$FMT")
    else
        (cd "$REPO" && find "$root" \( -type d -empty -printf 'd\t0\t%TY-%Tm-%Td %TH:%TM:%TS\t%p\n' \) \
                                  -o \( ! -type d -printf "$FMT" \))
    fi
}

classify_into() {     # stdin manifest lines → $1/{core,media,weights}.tsv sorted by path; odd names → $1/bad.tsv
    local out="${1:?}" t
    : > "$out/core.raw"; : > "$out/media.raw"; : > "$out/weights.raw"; : > "$out/bad.tsv"
    awk -F'\t' -v out="$out" -v media="$MEDIA_EXT" -v weights="$WEIGHTS_EXT" '
        BEGIN { n = split(media, a, " ");   for (i = 1; i <= n; i++) M[a[i]] = 1
                n = split(weights, b, " "); for (i = 1; i <= n; i++) W[b[i]] = 1 }
        NF != 4 { print > (out "/bad.tsv"); next }          # TAB or newline inside a file name
        { tier = "core"
          if ($1 == "f") { base = $4; sub(/.*\//, "", base); ext = ""
                           if (match(base, /\.[^.]+$/)) ext = tolower(substr(base, RSTART + 1))
                           if (ext in M) tier = "media"; else if (ext in W) tier = "weights" }
          print > (out "/" tier ".raw") }' || return 1
    for t in core media weights; do
        LC_ALL=C sort -t "$(printf '\t')" -k4,4 "$out/$t.raw" > "$out/$t.tsv" && rm -f "${out:?}/${t:?}.raw"
    done
    [ ! -s "$out/bad.tsv" ]
}

# ── stamp dir, receipts, lock ─────────────────────────────────────────────────
set_bundle() {   # $1 bundle dir → META RECEIPTS MANIFESTS ARCHIVES
    STAMP_DIR="$1"; META="$1/meta"; RECEIPTS="$META/receipts"; MANIFESTS="$META/manifests"; ARCHIVES="$1/archives"
    mkdir -p "$RECEIPTS" "$MANIFESTS" "$ARCHIVES" || die "cannot create $1"
}
init_stamp() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "STAMP must match [A-Za-z0-9._-]+ (got '$1')"
    STAMP="$1"; set_bundle "$EXPORT_ROOT/$STAMP"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/logarch_work.XXXXXX")" || die "no work dir"
}
take_lock() {    # one writer per STAMP; a lock whose job is gone is stale
    local other alive=0
    if ! mkdir "$META/.lock" 2>/dev/null; then
        other="$(cat "$META/.lock/owner" 2>/dev/null)"
        case "$other" in
            slurm:*) command -v squeue >/dev/null && [ -n "$(squeue -h -j "${other#slurm:}" 2>/dev/null)" ] && alive=1 ;;
            pid:*)   kill -0 "${other#pid:}" 2>/dev/null && alive=1 ;;
        esac
        [ "$alive" = 1 ] && die "STAMP $STAMP is being packed by $other"
        log "[lock] removing stale lock of ${other:-?}"; rm -rf "${META:?}/.lock"; mkdir "$META/.lock" || die "lock"
    fi
    if [ -n "${SLURM_JOB_ID:-}" ]; then echo "slurm:$SLURM_JOB_ID" > "$META/.lock/owner"; else echo "pid:$$" > "$META/.lock/owner"; fi
    LOCKED=1
}
release_lock() { if [ "${LOCKED:-0}" = 1 ]; then rm -rf "${META:?}/.lock"; LOCKED=0; fi; }
unit_done() {    # $1 stem  $2 receipt kind (packed | gdrive): every tier has it, or is empty
    local t; for t in $TIERS; do [ -f "$RECEIPTS/$1.$t.$2" ] || [ -f "$RECEIPTS/$1.$t.empty" ] || return 1; done
}
mark_empty() { printf 'unit=%s\nmode=%s\ntier=%s\nroot=%s\n' "$1" "$2" "$3" "$(unit_root "$1" "$2")" \
                   > "$RECEIPTS/$(unit_stem "$1").$3.empty"; }
apply_force() {  # FORCE_UNITS="UAV_MIX/uav-corridor solver_bench" → forget their receipts, pack again
    local u s k; for u in ${FORCE_UNITS:-}; do
        s="$(unit_stem "$u")"; log "[force] $u will be packed again"
        for k in packed empty pulled gdrive; do rm -f "${RECEIPTS:?}/${s:?}".*."$k"; done
    done
}
save_selection() { printf 'ONLY_UNITS=%s\nSKIP_UNITS=%s\n' "${ONLY_UNITS:-}" "${SKIP_UNITS:-}" > "$META/SELECTION"; }
ledger() { printf '%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "${SLURM_JOB_ID:-none}" "$1" "$2" >> "$META/ledger.tsv"; }

summarize() {    # SUMMARY.md / SUMMARY.json / units.tsv / SHA256SUMS from receipts + manifests
    local r
    if [ -n "${PY:-}" ] && "$PY" "$LOGARCH_DIR/logarch_summarize.py" "$META" --stamp "${STAMP:-selftest}"; then return 0; fi
    log "[warn] python summary failed — writing SHA256SUMS only"
    for r in "$RECEIPTS"/*.packed; do
        [ -e "$r" ] && printf '%s  %s\n' "$(rget "$r" sha256)" "$(rget "$r" archive)"
    done | LC_ALL=C sort -k2 > "$META/SHA256SUMS"
}

# ── the one-pass packer ───────────────────────────────────────────────────────
# pack_stream <tsv> <sink> <dest> <archive_name> <receipt|-> <manifest_copy|->
#   tsv    manifest lines "type<TAB>bytes<TAB>mtime<TAB>path" (paths relative to REPO) — exactly what goes in
#   sink=file  dest=<dir>         → <dir>/<archive_name> (written as .part, renamed after the checks)
#   sink=rcat  dest=<remote dir>  → rclone rcat <dest>/<archive_name>, then the Drive md5 must match the stream
#   sink=null  dest=-             → bytes counted and dropped (ratio / speed probe)
#   PACK_EXTRA (optional)         → extra key=value lines appended to the receipt
#   PACK_TAR_EXTRA (optional array) → extra tar options, e.g. (--transform='s,^old/root,new_name,') for renamed folders
# sets PACK_ARC_BYTES PACK_SECONDS PACK_SHA PACK_MD5 PACK_LAST; returns 1 (and leaves nothing behind) on any failure
pack_stream() {
    local tsv="$1" sink="$2" dest="$3" arc="$4" receipt="$5" mancopy="${6:--}"
    local w exp_n exp_b got_n got_b t0 t1 vrc arc_bytes why="" f p_sha p_md5 p_ver
    local tar_rc zstd_rc tee_rc sink_rc
    local -a ps
    w="$(mktemp -d "$WORK/pack.XXXXXX")" || return 1
    read -r exp_n exp_b < <(tsv_stats "$tsv")
    cut -f4 "$tsv" | tr '\n' '\0' > "$w/list0"
    mkfifo "$w/f_sha" "$w/f_md5" "$w/f_ver" || return 1
    (sha256sum < "$w/f_sha" | cut -d' ' -f1 > "$w/sha256") &
    p_sha=$!
    (md5sum < "$w/f_md5" | cut -d' ' -f1 > "$w/md5") &
    p_md5=$!
    (set -o pipefail; zstd -dc < "$w/f_ver" | tar -tv --numeric-owner --quoting-style=literal -f - \
        | awk '$1 ~ /^-/ { n++; b += $3 } END { printf "%.0f %.0f\n", n, b }' > "$w/got") 2> "$w/verify.err" &
    p_ver=$!
    t0=$(date +%s)
    case "$sink" in
        file) (cd "$REPO" && nice -n 10 tar -c --null --no-recursion --hard-dereference "${PACK_TAR_EXTRA[@]}" -T "$w/list0" -f -) 2> "$w/tar.err" \
                  | nice -n 10 zstd -q -T"$THREADS" -"$ZSTD_LEVEL" -c \
                  | tee "$w/f_sha" "$w/f_md5" "$w/f_ver" > "$dest/$arc.part"
              ps=("${PIPESTATUS[@]}") ;;
        rcat) (cd "$REPO" && nice -n 10 tar -c --null --no-recursion --hard-dereference "${PACK_TAR_EXTRA[@]}" -T "$w/list0" -f -) 2> "$w/tar.err" \
                  | nice -n 10 zstd -q -T"$THREADS" -"$ZSTD_LEVEL" -c \
                  | tee "$w/f_sha" "$w/f_md5" "$w/f_ver" \
                  | rclone rcat "$dest/$arc" "${RCLONE_FLAGS[@]}" 2> "$w/rclone.err"
              ps=("${PIPESTATUS[@]}") ;;
        null) (cd "$REPO" && nice -n 10 tar -c --null --no-recursion --hard-dereference "${PACK_TAR_EXTRA[@]}" -T "$w/list0" -f -) 2> "$w/tar.err" \
                  | nice -n 10 zstd -q -T"$THREADS" -"$ZSTD_LEVEL" -c \
                  | tee "$w/f_sha" "$w/f_md5" "$w/f_ver" | wc -c > "$w/bytes"
              ps=("${PIPESTATUS[@]}") ;;
        *)    die "pack_one: unknown sink '$sink'" ;;
    esac
    for f in f_sha f_md5 f_ver; do exec 9<>"$w/$f"; exec 9>&-; done    # a reader tee never opened must not hang
    wait "$p_sha"; wait "$p_md5"; wait "$p_ver"; vrc=$?
    t1=$(date +%s)
    tar_rc=${ps[0]}; zstd_rc=${ps[1]}; tee_rc=${ps[2]}; sink_rc=${ps[3]:-0}
    read -r got_n got_b < "$w/got" 2>/dev/null || { got_n=-1; got_b=-1; }
    [ "$tar_rc" -le 1 ] || why+=" tar_rc=$tar_rc [$(tail -c 300 "$w/tar.err" | tr '\n' ' ')]"
    [ "$zstd_rc" -eq 0 ] || why+=" zstd_rc=$zstd_rc"
    [ "$tee_rc" -eq 0 ]  || why+=" tee_rc=$tee_rc"
    [ "$sink_rc" -eq 0 ] || why+=" sink_rc=$sink_rc [$(tail -c 300 "$w/rclone.err" 2>/dev/null | tr '\n' ' ')]"
    [ "$vrc" -eq 0 ]     || why+=" verify_rc=$vrc [$(tail -c 300 "$w/verify.err" | tr '\n' ' ')]"
    [ "$got_n $got_b" = "$exp_n $exp_b" ] || why+=" content: manifest ${exp_n} files/${exp_b} B, archive ${got_n}/${got_b}"
    case "$sink" in
        file) arc_bytes="$(stat -c %s "$dest/$arc.part" 2>/dev/null || echo 0)" ;;
        rcat) [ -z "$why" ] && { remote_md5_ok "$dest/$arc" "$(cat "$w/md5")" || why+=" remote md5 differs from the stream"; }
              arc_bytes="$(remote_size "$dest/$arc")" ;;
        null) arc_bytes="$(cat "$w/bytes")" ;;
    esac
    if [ -n "$why" ]; then
        log "[FAIL] $arc:$why"
        [ "$sink" = file ] && rm -f "${dest:?}/${arc:?}.part"
        [ "$sink" = rcat ] && rclone deletefile "$dest/$arc" >/dev/null 2>&1
        rm -rf "${w:?}"; return 1
    fi
    [ "$tar_rc" -eq 1 ] && log "[warn] $arc: tar saw files change while reading (kept, flagged tar_rc=1)"
    if [ "$receipt" != "-" ] && [ "$sink" != null ]; then
        {   [ -n "${PACK_EXTRA:-}" ] && printf '%s\n' "$PACK_EXTRA"
            printf 'archive=%s\n' "$arc"
            printf 'files=%s\nraw_bytes=%s\nentries=%s\narc_bytes=%s\n' "$exp_n" "$exp_b" "$(wc -l < "$tsv")" "$arc_bytes"
            printf 'sha256=%s\nmd5=%s\n' "$(cat "$w/sha256")" "$(cat "$w/md5")"
            printf 'tar_rc=%s\nzstd_level=%s\nseconds=%s\nsink=%s\ndest=%s\n' "$tar_rc" "$ZSTD_LEVEL" "$((t1 - t0))" "$sink" "$dest"
            printf 'job=%s\nhost=%s\npacked_at=%s\n' "${SLURM_JOB_ID:-none}" "$(hostname)" "$(date -Iseconds)"
        } > "$receipt.tmp" && mv "$receipt.tmp" "$receipt"
    fi
    [ "$mancopy" != "-" ] && gzip -c "$tsv" > "$mancopy"
    [ "$sink" = file ] && mv "$dest/$arc.part" "$dest/$arc"
    PACK_ARC_BYTES="$arc_bytes"; PACK_SECONDS=$((t1 - t0)); PACK_SHA="$(cat "$w/sha256")"; PACK_MD5="$(cat "$w/md5")"
    PACK_LAST="files=$exp_n raw=$(hb "$exp_b") → $(hb "$arc_bytes") (x$(ratio "$arc_bytes" "$exp_b")) in ${PACK_SECONDS}s"
    rm -rf "${w:?}"
    return 0
}

# pack_one <unit> <mode> <tier> <tsv> <sink> <dest> <receipt> — one raw archive <stem>.<tier>.tar.zst
pack_one() {
    local stem man="-"
    stem="$(unit_stem "$1")"
    [ "$5" != null ] && man="$MANIFESTS/$stem.$3.tsv.gz"
    PACK_EXTRA="$(printf 'unit=%s\nmode=%s\ntier=%s\nroot=%s' "$1" "$2" "$3" "$(unit_root "$1" "$2")")"
    pack_stream "$4" "$5" "$6" "$stem.$3.tar.zst" "$7" "$man"
    local rc=$?
    PACK_EXTRA=""
    return "$rc"
}

# ── file-tree capture + change report (logs/ may change while we work) ──────
capture_tree() {  # $1 out .tsv.gz — the whole logs/ tree (files, links, empty dirs) in manifest format
    (cd "$REPO" && find "$LOGS_REL" \( -type d -empty -printf 'd\t0\t%TY-%Tm-%Td %TH:%TM:%TS\t%p\n' \) \
                                 -o \( ! -type d -printf "$FMT" \)) | LC_ALL=C sort -t "$(printf '\t')" -k4,4 | gzip -c > "$1"
}
change_report() { # $1 meta dir → meta/CHANGES.md + CHANGES.tsv: logs/ now vs what the archives hold; 3 = changes found
    local now="$WORK/tree_now.tsv.gz" rc
    capture_tree "$now" || { log "[warn] could not list logs/ for the change report"; return 0; }
    [ -n "${PY:-}" ] || { log "[warn] no python — change report skipped"; return 0; }
    "$PY" "$LOGARCH_DIR/logarch_changes.py" "$1" "$now" --split "$SPLIT_UNITS" \
        --only "${ONLY_UNITS:-$(rget "$1/SELECTION" ONLY_UNITS)}" --skip "${SKIP_UNITS:-$(rget "$1/SELECTION" SKIP_UNITS)}"; rc=$?
    cp "$now" "$1/TREE_END.tsv.gz"
    return "$rc"
}

# ── 24 h limit: finish the current archive, then continue in a new job ──────
# The sbatch header asks for  #SBATCH --signal=B:USR1@1800  (30 min before the limit, to the batch shell only),
# so the running tar|zstd|rclone pipeline is not interrupted; the loop stops before the next archive.
STOP_REQ=0
enable_autocontinue() { trap 'STOP_REQ=1; log "[time] limit near — finishing the current archive, then handing over to a new job"' USR1; }
stop_requested() {    # true when the loop must stop now (signal, or the LOGARCH_STOP_AFTER test hook)
    [ "$STOP_REQ" = 1 ] && return 0
    [ -n "${LOGARCH_STOP_AFTER:-}" ] && [ "${1:-0}" -ge "$LOGARCH_STOP_AFTER" ] && { STOP_REQ=1; log "[time] LOGARCH_STOP_AFTER=$LOGARCH_STOP_AFTER reached"; return 0; }
    return 1
}
resubmit_self() {     # $1 script (repo-relative) $2.. args → same job again, after this one ends (lock-safe)
    local n="${LOGARCH_RESUBMITS:-0}" d t jid
    if [ "$n" -ge "${LOGARCH_MAX_RESUBMITS:-5}" ]; then log "[continue] $n automatic hand-overs already — submit the same command again by hand"; return 1; fi
    if [ -z "${SLURM_JOB_ID:-}" ] || ! command -v sbatch >/dev/null 2>&1; then log "[continue] not inside Slurm — run the same command again"; return 1; fi
    d="$(date +%Y-%m-%d)"; t="$(date +%H_%M_%S)"; mkdir -p "$REPO/Slurm_Codes/logs/$d"
    jid="$(cd "$REPO" && sbatch --parsable --dependency="afterany:$SLURM_JOB_ID" --job-name="$(basename "$1" .sh)" \
            --output="Slurm_Codes/logs/$d/${t}_%x_%j.log" --error="Slurm_Codes/logs/$d/${t}_%x_%j.log" \
            --export="ALL,LOGARCH_RESUBMITS=$((n + 1)),SUBMIT_DATE=$d,SUBMIT_TIME=$t" "$1" "${@:2}")" || { log "[continue] sbatch failed"; return 1; }
    log "[continue] hand-over #$((n + 1)) submitted: job $jid (starts when this one ends)"
    [ -n "${META:-}" ] && ledger resubmit "job=$jid n=$((n + 1))"
}

# ── Google Drive helpers (rclone) ─────────────────────────────────────────────
remote_stamp() { printf '%s:%s/%s' "$GDRIVE_REMOTE" "$GDRIVE_ROOT" "$1"; }   # raw/ triage/ curated/ live below
have_remote() { command -v rclone >/dev/null 2>&1 || return 1
                case "$(rclone listremotes 2>/dev/null)" in *"$GDRIVE_REMOTE:"*) return 0 ;; *) return 1 ;; esac; }
drive_free()  { rclone about "$GDRIVE_REMOTE:" --json "$@" 2>/dev/null | sed -n 's/.*"free": *\([0-9][0-9]*\).*/\1/p'; }
remote_size() { rclone lsl "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'; }
remote_md5_ok() {   # $1 remote file  $2 expected md5 — Drive can need a moment before it reports the hash
    local got="" i
    for i in 1 2 3 4 5 6; do
        got="$(rclone md5sum "$1" 2>/dev/null | awk 'NR == 1 { print $1 }')"
        [ -n "$got" ] && break
        sleep 10
    done
    [ "$got" = "$2" ]
}
