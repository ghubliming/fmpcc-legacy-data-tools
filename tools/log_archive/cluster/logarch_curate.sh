#!/bin/bash
#SBATCH --job-name=logarch_curate
#SBATCH --partition=gpu-1-student
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=08:00:00
#SBATCH --signal=B:USR1@1800
# ─────────────────────────────────────────────────────────────────────────────
# CURATED layer — executes the APPROVED plan <GDRIVE_ROOT>/<STAMP>/triage/CURATE_PLAN.tsv.gz, which
# `logarch_local.sh plan-curate` builds from TRIAGE.tsv after your review. For every curated folder:
#   run_archive.tar.zst  ← exactly the plan's "pack" files, streamed into Drive (rclone rcat), Drive md5 checked
#   key files            ← the plan's "key" files as plain copies (browsable in Drive), rclone check'ed
# READ-ONLY on logs/: nothing on the cluster is moved, renamed or deleted; only files the plan names are read.
# The plan must match CURATE_PLAN.sha256 (what you approved is what runs). Idempotent: receipts in
# export_tmp/log_archive/<STAMP>/curate/receipts — re-submit to continue. A failing folder is reported, the rest go on.
# 30 min before the time limit it finishes the current folder and hands over to a new job by itself (≤ 5 times).
# CPU-only — no --gres, no MuJoCo/EGL.
#
#   ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_curate.sh <STAMP>
#   env (optional): CURATE_PLAN=/path/CURATE_PLAN.tsv.gz (a local plan, CURATE_PLAN.sha256 next to it)
# ─────────────────────────────────────────────────────────────────────────────
REPO="${REPO:-$HOME/FMPCC/FM-PCC}"
source "$REPO/Slurm_Codes/sbatch/log_archive/logarch_common.sh" || exit 1
STAMP="${1:?usage: logarch_curate.sh <STAMP>}"
[[ "$STAMP" =~ ^[A-Za-z0-9._-]+$ ]] || die "STAMP must match [A-Za-z0-9._-]+ (got '$STAMP')"
job_header "logarch_curate STAMP=$STAMP → $(remote_stamp "$STAMP")/curated"
activate_tools
have_remote || die "no rclone remote '$GDRIVE_REMOTE:' (plan §7)"
CUR="$EXPORT_ROOT/$STAMP/curate"; META="$CUR"               # META = where take_lock / ledger write
mkdir -p "$CUR/receipts" || die "cannot create $CUR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/logarch_curate.XXXXXX")" || die "no work dir"
take_lock
enable_autocontinue
RS="$(remote_stamp "$STAMP")"

# ── 1. the approved plan (sha256 must match) ─────────────────────────────────
if [ -n "${CURATE_PLAN:-}" ]; then
    cp "$CURATE_PLAN" "$CUR/CURATE_PLAN.tsv.gz" && cp "$(dirname "$CURATE_PLAN")/CURATE_PLAN.sha256" "$CUR/CURATE_PLAN.sha256" \
        || die "cannot read $CURATE_PLAN (+ CURATE_PLAN.sha256 next to it)"
else
    rclone copyto "$RS/triage/CURATE_PLAN.tsv.gz" "$CUR/CURATE_PLAN.tsv.gz" "${RCLONE_FLAGS[@]}" \
        && rclone copyto "$RS/triage/CURATE_PLAN.sha256" "$CUR/CURATE_PLAN.sha256" "${RCLONE_FLAGS[@]}" \
        || die "no plan on Drive — run \`logarch_local.sh plan-curate $STAMP\` first"
fi
(cd "$CUR" && sha256sum -c --quiet CURATE_PLAN.sha256) || die "CURATE_PLAN.tsv.gz does not match CURATE_PLAN.sha256 — refusing"

# ── 2. one folder per run id: .root (root, dest) / .pack (manifest lines) / .key (paths relative to root) ─
mkdir -p "$WORK/runs"
gzip -dc "$CUR/CURATE_PLAN.tsv.gz" | awk -F'\t' -v d="$WORK/runs" '
    /^#/ { next }
    $1 != cur { if (cur != "") { close(d "/" cur ".root"); close(d "/" cur ".pack"); close(d "/" cur ".key") }; cur = $1 }
    $2 == "root" { root = $5; print $5 "\t" $6 "\t" $7 > (d "/" $1 ".root") }
    $2 == "pack" { print $3 "\t" $4 "\t-\t" $5 > (d "/" $1 ".pack") }
    $2 == "key"  { p = $5; if (index(p, root "/") == 1) p = substr(p, length(root) + 2); print p > (d "/" $1 ".key") }' \
    || die "cannot read the plan"
n_all="$(find "$WORK/runs" -name '*.root' | wc -l)"
log "[plan] $n_all curated folder(s) · plan sha256 $(cut -c1-12 "$CUR/CURATE_PLAN.sha256") · receipts so far $(find "$CUR/receipts" -name '*.done' | wc -l)"

# ── 3. execute ────────────────────────────────────────────────────────────────
done_n=0; skip_n=0; fail=()
for rootf in "$WORK"/runs/*.root; do
    [ -e "$rootf" ] || continue
    rid="$(basename "$rootf" .root)"
    [ -f "$CUR/receipts/$rid.done" ] && { skip_n=$((skip_n + 1)); continue; }
    stop_requested "$done_n" && break
    IFS=$'\t' read -r root dest rename < "$rootf"
    D="$RS/curated/$dest"; ok=1; nkey=0; PACK_LAST="no archive"
    arc=run_archive.tar.zst; PACK_TAR_EXTRA=()
    if [ "$rename" = rename ]; then       # organize v2: the archive unpacks into <new name>/ instead of the old logs/… path
        arc="$(basename "$dest").tar.zst"
        PACK_TAR_EXTRA=(--transform="s,^$(printf '%s' "$root" | sed 's/[].*^$[]/\\&/g'),$(basename "$dest"),")
    fi
    if [ -s "$WORK/runs/$rid.pack" ]; then
        PACK_EXTRA="$(printf 'run_id=%s\nroot=%s\ncurated_dest=%s' "$rid" "$root" "$dest")"
        pack_stream "$WORK/runs/$rid.pack" rcat "$D" "$arc" "$WORK/runs/$rid.receipt" - || ok=0
        PACK_EXTRA=""; PACK_TAR_EXTRA=()
    else
        printf 'run_id=%s\nroot=%s\ncurated_dest=%s\narchive=-\n' "$rid" "$root" "$dest" > "$WORK/runs/$rid.receipt"
    fi
    if [ "$ok" = 1 ] && [ -s "$WORK/runs/$rid.key" ]; then
        nkey="$(wc -l < "$WORK/runs/$rid.key")"
        { rclone copy "$REPO/$root" "$D" --files-from-raw "$WORK/runs/$rid.key" "${RCLONE_FLAGS[@]}" \
            && rclone check "$REPO/$root" "$D" --one-way --files-from-raw "$WORK/runs/$rid.key" > "$WORK/check.log" 2>&1; } \
            || { ok=0; log "[FAIL] key files of $dest: $(tail -c 300 "$WORK/check.log" 2>/dev/null | tr '\n' ' ')"; }
    fi
    if [ "$ok" = 1 ]; then
        { cat "$WORK/runs/$rid.receipt"
          printf 'key_files=%s\ncurated_at=%s\njob=%s\n' "$nkey" "$(date -Iseconds)" "${SLURM_JOB_ID:-none}"; } > "$CUR/receipts/$rid.done"
        done_n=$((done_n + 1))
        log "[curated] $dest | $PACK_LAST | key files $nkey"
    else
        fail+=("$dest")
    fi
done

# ── 4. summary + receipts next to the curated tree ───────────────────────────
awk -F= 'function emit() { print v["run_id"] "\t" v["curated_dest"] "\t" v["files"] "\t" v["raw_bytes"] "\t" \
                               v["arc_bytes"] "\t" v["md5"] "\t" v["key_files"]; split("", v) }
         FNR == 1 && NR > 1 { emit() }
         { v[$1] = substr($0, length($1) + 2) }
         END { if (NR > 0) emit() }' "$CUR"/receipts/*.done 2>/dev/null \
    | { printf 'run_id\tdest\tfiles\traw_bytes\tarc_bytes\tmd5\tkey_files\n'; cat; } > "$CUR/CURATE_SUMMARY.tsv"
rclone copy "$CUR" "$RS/curated/_meta" --include "/receipts/**" --include "/CURATE_SUMMARY.tsv" --include "/CURATE_PLAN.sha256" \
    "${RCLONE_FLAGS[@]}" || log "[warn] could not upload the curate receipts"
ledger curate "done=$done_n skipped=$skip_n failed=${#fail[@]}"
if [ "$STOP_REQ" = 1 ]; then
    resubmit_self Slurm_Codes/sbatch/log_archive/logarch_curate.sh "$STAMP" \
        || log "[continue] re-submit by hand: ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_curate.sh $STAMP"
    log "[paused] $done_n folder(s) curated in this job; the rest continues in the next one"
    exit 0
fi
if [ "${#fail[@]}" -gt 0 ]; then
    log "[FAIL] ${#fail[@]} folder(s) failed (first: ${fail[0]}); fix and re-submit — finished folders are skipped"
    exit 1
fi
log "[done] $done_n folder(s) curated now, $skip_n were already done → $RS/curated. Next (container): logarch_local.sh publish $STAMP"
