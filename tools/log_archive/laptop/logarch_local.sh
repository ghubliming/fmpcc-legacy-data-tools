#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# logarch_local.sh — the LAPTOP / CONTAINER side of the log archive. Never runs on the cluster.
# Plan: logs_in_develop/Log_Archive_Export/PLAN_log_archive_export.md
# Drive:  <GDRIVE_ROOT>/<STAMP>/ raw/{archives,meta} · triage/ · curated/ · README.md RESTORE.md TRIAGE.md INDEX_auto.md
# Local:  $LOCAL_ROOT/<STAMP>/   raw/{archives,meta} · triage/ · cards/ · catalog/ · check/   (mirror of Drive)
#
# over ssh to the cluster (WSL2 shell where `ssh <cluster>` works):
#   selftest                     DOWNLOAD TEST: pull the newest selftest kit, sha256, restore vs manifests, speeds
#   pull-rolling <STAMP>         route A: loop { submit a pack round → wait → rsync → sha256 → prune on the cluster }
#   pull-meta <STAMP>            raw/meta over ssh
# over Google Drive only (works in the dev container):
#   fetch-meta <STAMP>           raw/meta from Drive — the input of the triage
#   triage <STAMP>               runs → labels + evidence → triage/TRIAGE.tsv + TRIAGE.md (copy in logs_in_develop)
#   set <STAMP> --match GLOB [--match GLOB] [--include yes|no] [--group G] [--note T]   change decisions (logged)
#   plan-curate <STAMP>          TRIAGE.tsv → CURATE_PLAN + cards → Drive triage/; prints the cluster command
#   publish <STAMP>              cards → curated/, README/RESTORE/TRIAGE/INDEX → Drive; copies into logs_in_develop
#   check-drive <STAMP> [N]      restore test from Drive: N raw units + N curated folders (default 2, 0 = all)
#   fetch <STAMP> [tier]         raw archives Drive → local (core|media|weights, default all), then sha256
#   upload <STAMP>               route A: local raw/ → Drive raw/, then rclone check
#   verify <STAMP>               sha256 of the local raw archives against their receipts
#   status <STAMP>               counts
#   drive-test                   is Google Drive reachable from HERE? quota, 64 MiB up + down + compare, speeds
# organize v2 (thesis folders → curated/ under clear names, raw/ = everything else; plan PLAN_organize_v2.md):
#   organize-plan <STAMP>        naming map (logs_in_develop/Log_Archive_Export/catalog_<STAMP>/naming_map.tsv) → plan + notes → Drive triage/
#   finalize <STAMP>             after logarch_curate.sh + logarch_raw_rebuild.sh: prove every file is in exactly one place,
#                                then put the rebuilt archives into raw/ (old ones → Drive trash)
#   publish-organized <STAMP>    notes → curated/, README.md NAMING.md RESTORE.md naming_map.tsv → Drive; copies to the repo
#
# env: CLUSTER=llim@vmknoll81 (ssh target/alias)  RREPO=FMPCC/FM-PCC (repo on the cluster, relative to its $HOME)
#      LOCAL_ROOT (default /workspaces/FMPCC_log_archive, else ~/FMPCC_log_archive)  BUDGET_GB=20  POLL_S=60
#      PACK_ENV="TIERS=core …"  GDRIVE_REMOTE=gdrive  GDRIVE_ROOT=FMPCC_logs_backup
#      (CLUSTER=local + absolute RREPO = offline dry run: the "cluster" is this machine, jobs run inline)
# ─────────────────────────────────────────────────────────────────────────────
set -o pipefail
CLUSTER="${CLUSTER:-llim@vmknoll81}"
RREPO="${RREPO:-FMPCC/FM-PCC}"
if [ -z "${LOCAL_ROOT:-}" ]; then
    if [ -d /workspaces ] && [ -w /workspaces ]; then LOCAL_ROOT=/workspaces/FMPCC_log_archive; else LOCAL_ROOT="$HOME/FMPCC_log_archive"; fi
fi
BUDGET_GB="${BUDGET_GB:-20}"
POLL_S="${POLL_S:-60}"
PACK_ENV="${PACK_ENV:-}"
GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
GDRIVE_ROOT="${GDRIVE_ROOT:-FMPCC_logs_backup}"
RX="$RREPO/export_tmp/log_archive"                                        # bundle root on the cluster
REPO_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"          # this checkout (tools, rules, catalog)
TOOLS="$REPO_LOCAL/Slurm_Codes/sbatch/log_archive"
PY="$(command -v python3 || command -v python || true)"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { log "FATAL: $*"; exit 1; }
hb()   { numfmt --to=iec-i --suffix=B --format='%.1f' "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }
rget() { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null; }
need() { local t; for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "missing '$t' (Debian/Ubuntu/WSL2: sudo apt-get install -y $t)"; done; }
eta()  { awk -v b="$1" -v r="$2" 'BEGIN { if (r <= 0) { print "n/a"; exit } printf "%.1f h", b / 1e6 / r / 3600 }'; }
rx()   { if [ "$CLUSTER" = local ]; then bash -c "$1"; else ssh -o BatchMode=yes -o ServerAliveInterval=30 "$CLUSTER" "$1"; fi; }
rsrc() { if [ "$CLUSTER" = local ]; then printf '%s' "$1"; else printf '%s:%s' "$CLUSTER" "$1"; fi; }
rstamp() { printf '%s:%s/%s' "$GDRIVE_REMOTE" "$GDRIVE_ROOT" "$1"; }
stamp_ok() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "STAMP must match [A-Za-z0-9._-]+ (got '$1')"; }
catalog_dir() { printf '%s/logs_in_develop/Log_Archive_Export/catalog_%s' "$REPO_LOCAL" "$1"; }
copy_catalog() {    # copy review/catalog MDs into this repo (committed by you, never automatically)
    local stamp="$1" dst f; shift
    dst="$(catalog_dir "$stamp")"; mkdir -p "$dst"
    for f in "$@"; do [ -f "$f" ] && cp "$f" "$dst/"; done
    log "[catalog] $(ls "$dst" | tr '\n' ' ')→ ${dst#"$REPO_LOCAL"/}"
}

pull_meta()     { mkdir -p "$2/meta"; rsync -a --exclude '.lock/' "$(rsrc "$1/meta/")" "$2/meta/"; }
pull_archives() { mkdir -p "$2/archives"; rsync -a --partial-dir=.rsync-partial --exclude '*.part' --info=progress2 "$(rsrc "$1/archives/")" "$2/archives/"; }

verify_local() {    # $1 = a raw dir (archives/ + meta/): sha256 vs receipt; mismatches deleted locally → MISMATCHED=(ids)
    local B="$1" f name id want got bad=0
    MISMATCHED=()
    mkdir -p "$B/.verified"
    for f in "$B"/archives/*.tar.zst; do
        [ -e "$f" ] || continue
        name="${f##*/}"; id="${name%.tar.zst}"
        want="$(rget "$B/meta/receipts/$id.packed" sha256)"
        [ -n "$want" ] || { log "[wait] $name has no receipt yet"; continue; }
        [ "$(cat "$B/.verified/$id" 2>/dev/null)" = "$want" ] && continue
        got="$(sha256sum "$f" | cut -d' ' -f1)"
        if [ "$got" = "$want" ]; then
            echo "$got" > "$B/.verified/$id"; log "[ok] $name sha256 ${got:0:12}"
        else
            log "[MISMATCH] $name receipt ${want:0:12} ≠ local ${got:0:12} — local copy removed"; rm -f "${f:?}"; bad=1
            MISMATCHED+=("$id")
        fi
    done
    return "$bad"
}

prune_remote() {    # delete staged archives on the cluster that are verified here AND unchanged there (receipt sha256)
    local R="$1" B="$2" m id sha n=0 script
    script="cd '$R' || exit 1"
    for m in "$B"/.verified/*; do
        [ -e "$m" ] || continue
        id="${m##*/}"; sha="$(cat "$m")"
        [[ "$id" =~ ^[A-Za-z0-9._+-]+$ ]] || die "odd archive id '$id'"
        [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || continue
        script+="; if [ -f 'archives/$id.tar.zst' ] && grep -qx 'sha256=$sha' 'meta/receipts/$id.packed'; then"
        script+=" rm -f 'archives/$id.tar.zst' && touch 'meta/receipts/$id.pulled' && echo '[pruned] $id.tar.zst'; fi"
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || return 0
    rx "$script"
}

reset_remote() {    # a staged archive that does not match its own receipt is dropped on the cluster and packed again
    local R="$1" id script; shift
    script="cd '$R' || exit 1"
    for id in "$@"; do
        [[ "$id" =~ ^[A-Za-z0-9._+-]+$ ]] || die "odd archive id '$id'"
        script+="; rm -f 'archives/$id.tar.zst' 'meta/receipts/$id.packed' && echo '[reset] $id will be packed again'"
    done
    rx "$script"
}

submit_round() {    # prints the Slurm job id ("local" in the dry-run mode)
    local out
    if [ "$CLUSTER" = local ]; then
        (cd "$RREPO" && env $PACK_ENV REPO="$RREPO" bash Slurm_Codes/sbatch/log_archive/logarch_pack_stage.sh "$1" "$BUDGET_GB") >&2
        echo local; return 0
    fi
    out="$(rx "cd '$RREPO' && env $PACK_ENV ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_pack_stage.sh '$1' '$BUDGET_GB'")" || return 1
    printf '%s\n' "$out" >&2
    printf '%s\n' "$out" | sed -n 's/.*Job ID:[^0-9]*\([0-9][0-9]*\).*/\1/p' | tail -n 1
}

wait_job() {        # poll sacct until the job leaves PENDING/RUNNING; success = COMPLETED
    local jid="$1" st last="" empty=0
    [ "$jid" = local ] && return 0
    while :; do
        st="$(rx "sacct -n -X -j '$jid' -o State%20" 2>/dev/null | awk 'NR == 1 { print $1 }')"
        case "$st" in
            PENDING|RUNNING|REQUEUED|SUSPENDED|CONFIGURING|COMPLETING) ;;
            "") empty=$((empty + 1)); [ "$empty" -gt 10 ] && { log "no accounting record for job $jid"; return 1; } ;;
            *)  log "job $jid: $st"; [ "$st" = COMPLETED ]; return ;;
        esac
        [ -n "$st" ] && [ "$st" != "$last" ] && log "job $jid: $st"
        last="$st"; sleep "$POLL_S"
    done
}

check_restore() {   # $1 restore root, $2.. manifests (.tsv or .tsv.gz): every file (and size), link and empty dir must exist
    local root="$1" m typ size mt path bad=0; shift
    for m in "$@"; do
        while IFS=$'\t' read -r typ size mt path; do
            case "$typ" in
                f) { [ -f "$root/$path" ] && [ "$(stat -c %s "$root/$path")" = "$size" ]; } || { log "  missing/size: $path"; bad=$((bad + 1)); } ;;
                l) [ -L "$root/$path" ] || { log "  missing link: $path"; bad=$((bad + 1)); } ;;
                d) [ -d "$root/$path" ] || { log "  missing dir: $path"; bad=$((bad + 1)); } ;;
            esac
        done < <(gzip -dcf "$m")
    done
    [ "$bad" -eq 0 ]
}

# ── over ssh ──────────────────────────────────────────────────────────────────
cmd_selftest() {
    local ts R B t0 t1 down up="" ok=1 f est RT
    need rsync sha256sum tar zstd gzip; [ "$CLUSTER" = local ] || need ssh
    log "[L1] tools: $(rsync --version | awk 'NR == 1') · $(zstd --version | awk 'NR == 1') · rclone: $(rclone version 2>/dev/null | awk 'NR == 1' || echo 'not installed (only for Drive)')"
    ts="$(rx "ls -1 '$RX/_selftest' 2>/dev/null | tail -n 1")" || die "[L2] ssh $CLUSTER failed — fix ssh first (key, VPN, alias)"
    [ -n "$ts" ] || die "[L2] no selftest kit on the cluster — submit Slurm_Codes/sbatch/log_archive/logarch_selftest.sh first"
    R="$RX/_selftest/$ts"; B="$LOCAL_ROOT/_selftest/$ts"; mkdir -p "$B"
    log "[L2] ssh OK — newest kit $ts"
    log "[L3] local free: $(df -h --output=avail "$LOCAL_ROOT" | awk 'NR == 2 { print $1 }') under $LOCAL_ROOT (WSL2: also check the Windows drive that holds the distro)"
    t0=$(date +%s.%N); rsync -a --partial "$(rsrc "$R/")" "$B/" || die "[L4] rsync failed"; t1=$(date +%s.%N)
    down="$(awk -v b="$(du -sb "$B" | cut -f1)" -v a="$t0" -v c="$t1" 'BEGIN { printf "%.1f", b / 1e6 / (c - a) }')"
    log "[L4] kit pulled ($(du -sh "$B" | cut -f1)) at ~${down} MB/s"
    (cd "$B/archives" && sha256sum -c --quiet ../meta/SHA256SUMS) || { ok=0; log "[L5] sha256 FAIL"; }
    rm -rf "${B:?}/restore"; mkdir -p "$B/restore"
    for f in "$B"/archives/*.tar.zst; do zstd -dc "$f" | tar -xf - -C "$B/restore" || ok=0; done
    check_restore "$B/restore" "$B"/meta/manifests/*.tsv.gz || ok=0
    if [ "$ok" = 1 ]; then log "[L5] PASS — sha256 + restore match the manifests (files, sizes, links, empty dirs)"; else log "[L5] FAIL"; fi
    if command -v rclone >/dev/null 2>&1 && case "$(rclone listremotes 2>/dev/null)" in *"$GDRIVE_REMOTE:"*) true ;; *) false ;; esac; then
        RT="$(rstamp "_selftest_local_$(date +%Y%m%d_%H%M%S)")"
        t0=$(date +%s.%N); rclone copyto "$B/speed.bin" "$RT/speed.bin" || ok=0; t1=$(date +%s.%N)
        up="$(awk -v b="$(stat -c %s "$B/speed.bin")" -v a="$t0" -v c="$t1" 'BEGIN { printf "%.1f", b / 1e6 / (c - a) }')"
        { rclone copyto "$RT/speed.bin" "$B/speed.back" && cmp -s "$B/speed.bin" "$B/speed.back"; } || ok=0
        rclone purge "$RT" >/dev/null 2>&1; rm -f "${B:?}/speed.back"
        log "[L6] Google Drive from here: upload ~${up} MB/s, download + byte compare done"
    else
        log "[L6] SKIP — no rclone remote '$GDRIVE_REMOTE:' here"
    fi
    est="$(rget "$B/SELFTEST.env" EST_TOTAL_ARC_BYTES)"
    [ -n "$est" ] && log "[L7] bundle ≈ $(hb "$est"): pull ≈ $(eta "$est" "$down") at ${down} MB/s · upload from here ≈ $(eta "$est" "${up:-0}") (route A only)"
    rx "rm -f '$R/speed.bin'" >/dev/null 2>&1 || true
    [ "$ok" = 1 ] && log "LOCAL SELFTEST PASS" || die "LOCAL SELFTEST FAIL — see above"
}

cmd_pull_rolling() {
    local stamp="$1" R B jid res left
    stamp_ok "$stamp"; need rsync sha256sum; [ "$CLUSTER" = local ] || need ssh
    R="$RX/$stamp"; B="$LOCAL_ROOT/$stamp/raw"; mkdir -p "$B"
    while :; do
        if rx "test -d '$R/meta'"; then
            pull_meta "$R" "$B" || die "rsync meta failed"
            pull_archives "$R" "$B" || die "rsync archives failed — re-run to resume"
            if ! verify_local "$B"; then reset_remote "$R" "${MISMATCHED[@]}" || die "reset on the cluster failed"; fi
            prune_remote "$R" "$B" || die "prune on the cluster failed"
            res="$(rx "cat '$R/meta/ROUND_RESULT' 2>/dev/null")"
            left="$(rx "find '$R/archives' -name '*.tar.zst' | wc -l")"
            if { [ "$res" = all ] || [ "$res" = subset_done ]; } && [ "${left:-1}" -eq 0 ]; then
                pull_meta "$R" "$B"; log "[done] all packed, pulled, verified, pruned ($res)"; break
            fi
        fi
        jid="$(submit_round "$stamp")" || die "submitting the pack round failed"
        [ -n "$jid" ] || die "could not read the job id from submit.sh"
        wait_job "$jid" || die "pack job $jid did not complete — cluster log: $RREPO/Slurm_Codes/logs/<date>/*_logarch_pack_stage_${jid}.log (exit 3 = free-space guard); re-run to resume"
    done
    cmd_verify "$stamp"
}

cmd_pull_meta() {
    local stamp="$1"; stamp_ok "$stamp"; need rsync
    pull_meta "$RX/$stamp" "$LOCAL_ROOT/$stamp/raw" || die "rsync failed"
    log "[meta] $LOCAL_ROOT/$stamp/raw/meta — next: logarch_local.sh triage $stamp"
}

# ── over Google Drive ─────────────────────────────────────────────────────────
cmd_fetch_meta() {
    local stamp="$1" B; stamp_ok "$stamp"; need rclone
    B="$LOCAL_ROOT/$stamp"
    rclone copy "$(rstamp "$stamp")/raw/meta" "$B/raw/meta" --exclude ".lock/**" || die "download of raw/meta failed"
    log "[meta] $B/raw/meta — $(find "$B/raw/meta/receipts" -name '*.packed' | wc -l) archives described · next: logarch_local.sh triage $stamp"
}

cmd_triage() {
    local stamp="$1" B; stamp_ok "$stamp"; [ -n "$PY" ] || die "python3 missing"
    B="$LOCAL_ROOT/$stamp"
    [ -d "$B/raw/meta/manifests" ] || die "no $B/raw/meta — run fetch-meta (Drive) or pull-meta (ssh) first"
    "$PY" "$TOOLS/logarch_triage.py" scan "$B" --repo "$REPO_LOCAL" || die "triage scan failed"
    copy_catalog "$stamp" "$B/triage/TRIAGE.md"
    log "[triage] review $B/triage/TRIAGE.md · change with: logarch_local.sh set $stamp --match '<glob>' --include yes|no · then plan-curate"
}

cmd_set() {
    local stamp="$1" B; shift; stamp_ok "$stamp"
    B="$LOCAL_ROOT/$stamp"
    "$PY" "$TOOLS/logarch_triage.py" set "$B" "$@" || die "nothing matched"
    copy_catalog "$stamp" "$B/triage/TRIAGE.md"
}

cmd_plan_curate() {
    local stamp="$1" B RS; stamp_ok "$stamp"; need rclone
    B="$LOCAL_ROOT/$stamp"; RS="$(rstamp "$stamp")"
    [ -f "$B/triage/TRIAGE.tsv" ] || die "no TRIAGE.tsv — run triage first"
    "$PY" "$TOOLS/logarch_triage.py" plan "$B" --repo "$REPO_LOCAL" || die "plan failed"
    rclone copy "$B/triage" "$RS/triage" || die "upload of triage/ failed"
    rclone check "$B/triage" "$RS/triage" --one-way || die "check of triage/ failed"
    copy_catalog "$stamp" "$B/triage/TRIAGE.md" "$B/catalog/INDEX_auto.md"
    log "[plan] approved plan is on Drive ($RS/triage). Cluster: ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_curate.sh $stamp"
}

cmd_publish() {
    local stamp="$1" B RS f; stamp_ok "$stamp"; need rclone
    B="$LOCAL_ROOT/$stamp"; RS="$(rstamp "$stamp")"
    [ -d "$B/cards" ] || die "no cards — run plan-curate first"
    rclone copy "$B/cards" "$RS/curated" || die "upload of the cards failed"
    rclone check "$B/cards" "$RS/curated" --one-way || die "check of the cards failed"
    for f in "$B/README.md" "$B/RESTORE.md" "$B/triage/TRIAGE.md" "$B/catalog/INDEX_auto.md"; do
        [ -f "$f" ] && { rclone copyto "$f" "$RS/${f##*/}" || die "upload of ${f##*/} failed"; }
    done
    copy_catalog "$stamp" "$B/README.md" "$B/RESTORE.md" "$B/triage/TRIAGE.md" "$B/catalog/INDEX_auto.md"
    log "[publish] $RS: curated/ cards + $(for f in README.md RESTORE.md; do [ -f "$B/$f" ] && printf '%s ' "$f"; done)TRIAGE.md INDEX_auto.md"
}

cmd_check_drive() {     # restore test: download → extract → compare with the manifests / the plan
    local stamp="$1" n="${2:-2}" B RS C s t ok=1 stems rid root dest pick
    stamp_ok "$stamp"; need rclone zstd tar sha256sum
    B="$LOCAL_ROOT/$stamp"; RS="$(rstamp "$stamp")"; C="$B/check"
    [ -d "$B/raw/meta/receipts" ] || die "no raw/meta — fetch-meta first"
    rm -rf "${C:?}"; mkdir -p "$C/raw" "$C/restore_raw" "$C/cur"
    # raw layer: n units, every tier
    stems="$(find "$B/raw/meta/receipts" -name '*.packed' -printf '%f\n' | sed 's/\.[a-z]*\.packed$//' | sort -u)"
    [ "$n" -gt 0 ] && stems="$(printf '%s\n' "$stems" | awk -v n="$n" 'NR <= n')"
    for s in $stems; do
        rclone copy "$RS/raw/archives" "$C/raw" --include "/$s.*.tar.zst" || { ok=0; continue; }
        for t in "$C"/raw/"$s".*.tar.zst; do
            [ -e "$t" ] || continue
            [ "$(sha256sum < "$t" | cut -d' ' -f1)" = "$(rget "$B/raw/meta/receipts/$(basename "$t" .tar.zst).packed" sha256)" ] \
                || { ok=0; log "  sha256 mismatch: ${t##*/}"; }
            zstd -dc "$t" | tar -xf - -C "$C/restore_raw" || ok=0
        done
        check_restore "$C/restore_raw" "$B"/raw/meta/manifests/"$s".*.tsv.gz && log "[raw ok] $s" || { ok=0; log "[raw FAIL] $s"; }
    done
    # curated layer: n folders from the plan
    if [ -f "$B/triage/CURATE_PLAN.tsv.gz" ]; then
        pick="$(gzip -dc "$B/triage/CURATE_PLAN.tsv.gz" | awk -F'\t' '$2 == "root" { print $1 }')"
        [ "$n" -gt 0 ] && pick="$(printf '%s\n' "$pick" | awk -v n="$n" 'NR <= n')"
        for rid in $pick; do
            IFS=$'\t' read -r root dest ren < <(gzip -dc "$B/triage/CURATE_PLAN.tsv.gz" | awk -F'\t' -v r="$rid" '$1 == r && $2 == "root" { print $5 "\t" $6 "\t" $7 }')
            mkdir -p "$C/cur/$rid/restore"
            arcn=run_archive.tar.zst; newroot="$root"
            if [ "$ren" = rename ]; then arcn="${dest##*/}.tar.zst"; newroot="${dest##*/}"; fi
            gzip -dc "$B/triage/CURATE_PLAN.tsv.gz" | awk -F'\t' -v r="$rid" -v o="$root" -v n="$newroot" \
                '$1 == r && $2 == "pack" { p = $5; if (index(p, o "/") == 1) p = n substr(p, length(o) + 1); print $3 "\t" $4 "\t-\t" p }' > "$C/cur/$rid/pack.tsv"
            gzip -dc "$B/triage/CURATE_PLAN.tsv.gz" | awk -F'\t' -v r="$rid" -v root="$root" \
                '$1 == r && $2 == "key" { p = $5; if (index(p, root "/") == 1) p = substr(p, length(root) + 2); print p }' > "$C/cur/$rid/key.lst"
            if [ -s "$C/cur/$rid/pack.tsv" ]; then
                rclone copyto "$RS/curated/$dest/$arcn" "$C/cur/$rid/$arcn" \
                    && zstd -dc "$C/cur/$rid/$arcn" | tar -xf - -C "$C/cur/$rid/restore" \
                    && check_restore "$C/cur/$rid/restore" "$C/cur/$rid/pack.tsv" || { ok=0; log "[curated FAIL] $dest (archive)"; continue; }
            fi
            if [ -s "$C/cur/$rid/key.lst" ]; then
                rclone copy "$RS/curated/$dest" "$C/cur/$rid/key" --files-from-raw "$C/cur/$rid/key.lst" || ok=0
                while IFS= read -r k; do
                    cmp -s "$C/cur/$rid/key/$k" "$C/cur/$rid/restore/$newroot/$k" || { ok=0; log "  key file differs: $dest/$k"; }
                done < "$C/cur/$rid/key.lst"
            fi
            rclone copyto "$RS/curated/$dest/README.md" "$C/cur/$rid/README.md" >/dev/null 2>&1 || { ok=0; log "  card missing: $dest/README.md"; }
            log "[curated ok] $dest"
        done
    else
        log "[curated] no local CURATE_PLAN — skipped"
    fi
    [ "$ok" = 1 ] && log "CHECK-DRIVE PASS ($C)" || die "CHECK-DRIVE FAIL — see above ($C)"
}

cmd_fetch() {
    local stamp="$1" tier="${2:-}" B RS; stamp_ok "$stamp"; need rclone sha256sum
    B="$LOCAL_ROOT/$stamp/raw"; RS="$(rstamp "$stamp")"; mkdir -p "$B"
    rclone copy "$RS/raw/meta" "$B/meta" --exclude ".lock/**" -P || die "meta download failed"
    if [ -n "$tier" ]; then rclone copy "$RS/raw/archives" "$B/archives" --include "*.$tier.tar.zst" -P || die "download failed"
    else rclone copy "$RS/raw/archives" "$B/archives" -P || die "download failed"; fi
    verify_local "$B" && log "[fetch] $B verified"
}

cmd_upload() {
    local stamp="$1" B RS; stamp_ok "$stamp"; need rclone
    B="$LOCAL_ROOT/$stamp/raw"; RS="$(rstamp "$stamp")"
    [ -d "$B/archives" ] || die "no $B/archives — this is for route A bundles"
    verify_local "$B" || die "local verification failed — fix before uploading"
    rclone copy "$B" "$RS/raw" --exclude "/.verified/**" --exclude "/.rsync-partial/**" --exclude "*.part" \
        --transfers 2 --drive-chunk-size 64M --drive-stop-on-upload-limit -P || die "upload failed — re-run, finished files are skipped"
    rclone check "$B" "$RS/raw" --one-way --exclude "/.verified/**" --exclude "/.rsync-partial/**" --exclude "*.part" || die "check failed"
    log "[upload] $RS/raw checked"
}

cmd_verify() {
    local stamp="$1" B rc id missing=0
    B="$LOCAL_ROOT/$stamp/raw"
    [ -d "$B/meta/receipts" ] || die "no $B/meta — pull-meta, fetch-meta or fetch first"
    verify_local "$B"; rc=$?
    for id in "$B"/meta/receipts/*.packed; do
        [ -e "$id" ] || continue; id="${id##*/}"; id="${id%.packed}"
        [ -f "$B/.verified/$id" ] || missing=$((missing + 1))
    done
    log "[verify] $(find "$B/.verified" -type f 2>/dev/null | wc -l) archive(s) verified here · $missing packed archive(s) not local"
    return "$rc"
}

cmd_drive_test() {
    local RT t0 t1 up down free tmp
    need rclone cmp
    case "$(rclone listremotes 2>/dev/null)" in *"$GDRIVE_REMOTE:"*) ;; *) die "no rclone remote '$GDRIVE_REMOTE:' here (plan §7, step 2)";; esac
    free="$(rclone about "$GDRIVE_REMOTE:" --json --contimeout 15s --timeout 30s --retries 1 2>/dev/null | sed -n 's/.*"free": *\([0-9][0-9]*\).*/\1/p')"
    [ -n "$free" ] || rclone lsf "$GDRIVE_REMOTE:" --max-depth 1 --contimeout 15s --timeout 30s --retries 1 >/dev/null 2>&1 \
        || die "Google Drive not reachable from $(hostname) (firewall / no internet / token)"
    tmp="$(mktemp -d)"; head -c 64M /dev/urandom > "$tmp/probe.bin"
    RT="$(rstamp "_drivetest_$(date +%Y%m%d_%H%M%S)")"
    t0=$(date +%s.%N); rclone copyto "$tmp/probe.bin" "$RT/probe.bin" || die "upload failed"; t1=$(date +%s.%N)
    up="$(awk -v a="$t0" -v c="$t1" 'BEGIN { printf "%.1f", 67.108864 / (c - a) }')"
    t0=$(date +%s.%N); rclone copyto "$RT/probe.bin" "$tmp/back.bin" || die "download failed"; t1=$(date +%s.%N)
    down="$(awk -v a="$t0" -v c="$t1" 'BEGIN { printf "%.1f", 67.108864 / (c - a) }')"
    cmp -s "$tmp/probe.bin" "$tmp/back.bin" || die "downloaded bytes differ"
    rclone purge "$RT" >/dev/null 2>&1; rm -rf "${tmp:?}"
    log "DRIVE-TEST PASS from $(hostname): free $(hb "${free:-0}") · up ${up} MB/s · down ${down} MB/s · bytes identical"
}

map_of() { printf '%s' "${MAP:-$(catalog_dir "$1")/naming_map.tsv}"; }

cmd_organize_plan() {
    local stamp="$1" B RS M; stamp_ok "$stamp"; need rclone
    B="$LOCAL_ROOT/$stamp"; RS="$(rstamp "$stamp")"; M="$(map_of "$stamp")"
    [ -f "$M" ] || die "no naming map $M"
    [ -d "$B/raw/meta/manifests" ] || die "fetch-meta first"
    rm -rf "${B:?}/cards"
    PYTHONDONTWRITEBYTECODE=1 "$PY" "$TOOLS/logarch_organize.py" plan "$B" --map "$M" || die "plan failed"
    rclone copy "$B/triage" "$RS/triage" && rclone check "$B/triage" "$RS/triage" --one-way || die "upload of triage/ failed"
    log "[organize] plan on Drive. Cluster: ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_organize_pipeline.sh $stamp"
}

cmd_finalize() {     # the A1 swap — only after the coverage check passes
    local stamp="$1" B RS op aid k
    stamp_ok "$stamp"; need rclone
    B="$LOCAL_ROOT/$stamp"; RS="$(rstamp "$stamp")"
    rclone copy "$RS/raw_rebuilt/meta" "$B/raw_rebuilt/meta" --exclude ".lock/**" || die "no raw_rebuilt/meta on Drive — did logarch_raw_rebuild.sh finish?"
    rclone copyto "$RS/triage/CURATE_PLAN.sha256" "$B/raw_rebuilt/plan.sha256" && (cd "$B/triage" && sha256sum -c --quiet ../raw_rebuilt/plan.sha256) \
        || die "the local plan is not the plan on Drive"
    n_cur="$(rclone lsf "$RS/curated/_meta/receipts" 2>/dev/null | grep -c '\.done$')"
    n_plan="$(gzip -dc "$B/triage/CURATE_PLAN.tsv.gz" | awk -F'\t' '$2 == "root"' | wc -l)"
    [ "$n_cur" = "$n_plan" ] || die "curated/: $n_cur of $n_plan folders done — run logarch_curate.sh to the end first"
    PYTHONDONTWRITEBYTECODE=1 "$PY" "$TOOLS/logarch_organize.py" check "$B" || die "coverage check failed — nothing was changed on Drive"
    mkdir -p "$B/raw_final"; rm -rf "${B:?}/raw_final/meta"; cp -r "$B/raw/meta" "$B/raw_final/meta"
    while IFS=$'\t' read -r op aid; do
        [[ "$aid" =~ ^[A-Za-z0-9._+-]+$ ]] || die "odd id $aid"
        if rclone lsf "$RS/raw/archives/$aid.tar.zst" >/dev/null 2>&1 && [ -n "$(rclone lsf "$RS/raw/archives/$aid.tar.zst" 2>/dev/null)" ] \
           && [ -z "$(rclone lsf "$RS/raw_replaced/archives/$aid.tar.zst" 2>/dev/null)" ]; then
            rclone moveto "$RS/raw/archives/$aid.tar.zst" "$RS/raw_replaced/archives/$aid.tar.zst" || die "move of old $aid failed"
        fi
        rm -f "${B:?}/raw_final/meta/manifests/$aid.tsv.gz"; for k in packed pulled gdrive empty; do rm -f "${B:?}/raw_final/meta/receipts/$aid.$k"; done
        if [ "$op" = replace ]; then
            if [ -n "$(rclone lsf "$RS/raw_rebuilt/archives/$aid.tar.zst" 2>/dev/null)" ]; then
                rclone moveto "$RS/raw_rebuilt/archives/$aid.tar.zst" "$RS/raw/archives/$aid.tar.zst" || die "move of rebuilt $aid failed"
            fi
            remote_md5="$(rclone md5sum "$RS/raw/archives/$aid.tar.zst" | awk '{print $1}')"
            [ "$remote_md5" = "$(rget "$B/raw_rebuilt/meta/receipts/$aid.packed" md5)" ] || die "md5 of the new raw/$aid differs from its receipt"
            cp "$B/raw_rebuilt/meta/manifests/$aid.tsv.gz" "$B/raw_final/meta/manifests/"
            for k in packed gdrive; do [ -f "$B/raw_rebuilt/meta/receipts/$aid.$k" ] && cp "$B/raw_rebuilt/meta/receipts/$aid.$k" "$B/raw_final/meta/receipts/"; done
            log "[swap] raw/$aid.tar.zst ← rebuilt without the thesis folders"
        else
            cp "$B/raw_rebuilt/meta/receipts/$aid.empty" "$B/raw_final/meta/receipts/"
            log "[swap] raw/$aid.tar.zst removed — all of it is in curated/ now"
        fi
    done < "$B/raw_rebuilt/SWAP.tsv"
    PYTHONDONTWRITEBYTECODE=1 "$PY" "$TOOLS/logarch_summarize.py" "$B/raw_final/meta" --stamp "$stamp" || die "summary failed"
    echo "organized $(date -Iseconds): thesis folders moved to curated/ (see NAMING.md); raw/ holds everything else" > "$B/raw_final/meta/ORGANIZED"
    rclone sync "$B/raw_final/meta" "$RS/raw/meta" || die "meta upload failed"
    rclone check "$B/raw_final/meta" "$RS/raw/meta" || die "meta check failed"
    ( cd "$B/raw_final/meta" && awk '{print $2}' SHA256SUMS ) | sort > "$B/raw_final/expected.lst"
    rclone lsf "$RS/raw/archives" | sort > "$B/raw_final/present.lst"
    cmp -s "$B/raw_final/expected.lst" "$B/raw_final/present.lst" || die "raw/archives does not match SHA256SUMS — old archives are NOT deleted"
    rclone purge "$RS/raw_replaced" >/dev/null 2>&1; rclone purge "$RS/raw_rebuilt" >/dev/null 2>&1
    rm -rf "${B:?}/raw/meta"; mv "$B/raw_final/meta" "$B/raw/meta"
    log "[finalize] done: raw/ = everything not in curated/ ($(wc -l < "$B/raw_final/present.lst") archives); old versions are in the Drive trash (30 days)"
}

cmd_publish_organized() {
    local stamp="$1" B RS M f; stamp_ok "$stamp"; need rclone
    B="$LOCAL_ROOT/$stamp"; RS="$(rstamp "$stamp")"; M="$(map_of "$stamp")"
    PYTHONDONTWRITEBYTECODE=1 "$PY" "$TOOLS/logarch_organize.py" docs "$B" --map "$M" || die "docs failed"
    cp "$M" "$B/naming_map.tsv"
    rclone copy "$B/cards" "$RS/curated" && rclone check "$B/cards" "$RS/curated" --one-way || die "upload of the folder notes failed"
    for f in README.md NAMING.md RESTORE.md naming_map.tsv; do rclone copyto "$B/$f" "$RS/$f" || die "upload of $f failed"; done
    rclone copy "$B/guides/stamp" "$RS" && rclone check "$B/guides/stamp" "$RS" --one-way || die "upload of the folder guides failed"
    rclone copyto "$B/guides/README.md" "$GDRIVE_REMOTE:$GDRIVE_ROOT/README.md" || die "upload of the top README failed"
    copy_catalog "$stamp" "$B/README.md" "$B/NAMING.md" "$B/RESTORE.md"
    log "[publish] $RS: README.md NAMING.md RESTORE.md naming_map.tsv + one note per curated folder"
}

cmd_status() {
    local B="$LOCAL_ROOT/$1" k
    [ -d "$B/raw/meta/receipts" ] || die "no $B/raw/meta — fetch-meta first"
    for k in packed empty pulled gdrive; do printf '%-10s %s\n' "$k" "$(find "$B/raw/meta/receipts" -name "*.$k" | wc -l)"; done
    printf '%-10s %s\n' verified "$(find "$B/raw/.verified" -type f 2>/dev/null | wc -l)"
    [ -f "$B/raw/meta/ROUND_RESULT" ] && printf '%-10s %s\n' round "$(cat "$B/raw/meta/ROUND_RESULT")"
    [ -f "$B/triage/TRIAGE.tsv" ] && printf '%-10s %s\n' triage \
        "$(awk -F'\t' 'NR > 1 { n[$2]++ } END { printf "include %d · exclude %d", n["yes"], n["no"] }' "$B/triage/TRIAGE.tsv")"
    true
}

case "${1:-}" in
    selftest)     cmd_selftest ;;
    pull-rolling) cmd_pull_rolling "${2:?STAMP}" ;;
    pull-meta)    cmd_pull_meta "${2:?STAMP}" ;;
    fetch-meta)   cmd_fetch_meta "${2:?STAMP}" ;;
    triage)       cmd_triage "${2:?STAMP}" ;;
    set)          shift; cmd_set "${1:?STAMP}" "${@:2}" ;;
    plan-curate)  cmd_plan_curate "${2:?STAMP}" ;;
    publish)      cmd_publish "${2:?STAMP}" ;;
    check-drive)  cmd_check_drive "${2:?STAMP}" "${3:-2}" ;;
    fetch)        cmd_fetch "${2:?STAMP}" "${3:-}" ;;
    upload)       cmd_upload "${2:?STAMP}" ;;
    verify)       cmd_verify "${2:?STAMP}" ;;
    status)       cmd_status "${2:?STAMP}" ;;
    organize-plan) cmd_organize_plan "${2:?STAMP}" ;;
    finalize)     cmd_finalize "${2:?STAMP}" ;;
    publish-organized) cmd_publish_organized "${2:?STAMP}" ;;
    drive-test)   cmd_drive_test ;;
    *)            sed -n '2,38p' "$0"; exit 1 ;;
esac
