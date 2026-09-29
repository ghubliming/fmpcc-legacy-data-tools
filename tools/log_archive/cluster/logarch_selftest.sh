#!/bin/bash
#SBATCH --job-name=logarch_selftest
#SBATCH --partition=gpu-1-student
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=00:30:00
# ─────────────────────────────────────────────────────────────────────────────
# INIT JOB of the log archive — run it first, and again after any change to the scripts or the rclone setup.
# CPU-only (no --gres, no MuJoCo/EGL). Read-only on logs/; writes only export_tmp/log_archive/_selftest/<ts>/.
#   T1 tools            GNU tar, zstd, rclone, python
#   T2 disk             free space on the shared repo filesystem + node-local /tmp (type!)
#   T3 synthetic        compress → verify → restore of a fake unit with every entry type, diff -r must be empty
#   T4 plan             every unit × tier of the real logs/: files + raw bytes (units_plan.tsv), odd names, stem clashes
#   T5 real round-trip  the smallest real unit: compress → restore → diff -r against logs/
#   T6 probe            one ~1.5 GiB real unit through zstd → ratio per tier + speed → bundle size / time estimate
#   T7 Google Drive     only if rclone remote exists: quota, copyto + rcat upload, download back, sha256, restore, speed
#   T8 download kit     mini bundle + speed.bin for `logarch_local.sh selftest` (tests the laptop leg)
#   ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_selftest.sh
# ─────────────────────────────────────────────────────────────────────────────
REPO="${REPO:-$HOME/FMPCC/FM-PCC}"
source "$REPO/Slurm_Codes/sbatch/log_archive/logarch_common.sh" || exit 1
job_header "logarch_selftest"
activate_tools
REPO_REAL="$REPO"
TS="$(date +%Y%m%d_%H%M%S)"
ST="$EXPORT_ROOT/_selftest/$TS"
set_bundle "$ST"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/logarch_selftest.XXXXXX")" || die "no work dir"
REPORT="$ST/SELFTEST_REPORT.md"; ENVF="$ST/SELFTEST.env"; : > "$ENVF"
{ echo "# Log-archive selftest $TS"; echo
  echo "job ${SLURM_JOB_ID:-none} on $(hostname) · repo git $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?')"; echo
  echo "| test | result | detail |"; echo "|---|---|---|"; } > "$REPORT"
FAILS=0
res() { log "[$1] $2 — $3"; printf '| %s | %s | %s |\n' "$1" "$2" "$3" >> "$REPORT"; [ "$2" = FAIL ] && FAILS=$((FAILS + 1)); return 0; }
kv()  { printf '%s=%s\n' "$1" "$2" >> "$ENVF"; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { d = b - a; if (d < 0.001) d = 0.001; printf "%.3f", d }'; }
mbps() { awk -v n="$1" -v s="$2" 'BEGIN { printf "%.1f", n / 1e6 / s }'; }

# ── T1 tools ──────────────────────────────────────────────────────────────────
res T1_tools PASS "$(tar --version | awk 'NR == 1') · $(zstd --version 2>&1 | awk 'NR == 1') · rclone: $(rclone version 2>/dev/null | awk 'NR == 1' || echo missing) · python: $(${PY:-false} --version 2>&1 || echo missing)"

# ── T2 disk ───────────────────────────────────────────────────────────────────
home_free="$(free_bytes "$REPO")"; tmpd="${TMPDIR:-/tmp}"
tmp_fs="$(stat -f -c %T "$tmpd")"; tmp_free="$(free_bytes "$tmpd")"
kv HOME_FREE_BYTES "$home_free"; kv TMP_FS "$tmp_fs"; kv TMP_FREE_BYTES "$tmp_free"
res T2_disk INFO "repo filesystem free $(hb "$home_free") (guard MIN_FREE_GB=$MIN_FREE_GB) · node $tmpd: $tmp_fs, $(hb "$tmp_free") free$([ "$tmp_fs" = tmpfs ] && echo ' (RAM — never staged on)')"

# ── T3 synthetic compress → verify → restore ─────────────────────────────────
make_synthetic() {   # $1 root → $1/logs/demo with every entry type the real tree has
    local d="$1/logs/demo" i
    mkdir -p "$d/run A (seed 6)/plans/diagnostics" "$d/run_B/empty_dir" "$d/plans(Bf_fix1)"
    for i in $(seq 0 299); do
        printf '{"rollout": %d, "success": %d, "time_ms": %d.5}\n' "$i" $((i % 2)) $((i * 7)) \
            > "$d/run A (seed 6)/plans/diagnostics/rollout_${i}_stats.json"
    done
    seq 1 300000 | sed 's/^/epoch 1 step /' > "$d/run_B/train.log"
    head -c 6M /dev/urandom > "$d/run_B/state_best.pt"
    head -c 3M /dev/urandom > "$d/run A (seed 6)/plans/diagnostics/rollout_0.gif"
    head -c 1M /dev/urandom > "$d/plans(Bf_fix1)/Figure.PNG"
    printf 'k,v\na,1\n' > "$d/run_B/results.csv"
    ln -s ../run_B/results.csv "$d/run A (seed 6)/latest.csv"
    ln "$d/run_B/results.csv" "$d/run_B/results_hardlink.csv"
}
SYN="$WORK/synth"; make_synthetic "$SYN"
REPO="$SYN"; W3="$WORK/t3"; mkdir -p "$W3"; ok=1; detail=""
list_unit_files demo tree | classify_into "$W3" || { ok=0; detail+=" classify"; }
for t in core media weights; do
    pack_one demo tree "$t" "$W3/$t.tsv" file "$ARCHIVES" "$RECEIPTS/demo.$t.packed" || { ok=0; detail+=" pack:$t"; }
done
REPO="$REPO_REAL"
[ "$(tsv_stats "$W3/media.tsv")" = "2 $((4 * MiB))" ] && [ "$(tsv_stats "$W3/weights.tsv")" = "1 $((6 * MiB))" ] \
    || { ok=0; detail+=" tier-split"; }
mkdir -p "$WORK/restore3"
for t in core media weights; do zstd -dc "$ARCHIVES/demo.$t.tar.zst" | tar -xf - -C "$WORK/restore3" || { ok=0; detail+=" extract:$t"; }; done
diff -r --no-dereference "$SYN/logs/demo" "$WORK/restore3/logs/demo" > "$WORK/t3.diff" 2>&1 || { ok=0; detail+=" diff:$(head -c 200 "$WORK/t3.diff")"; }
if [ "$ok" = 1 ]; then res T3_synthetic PASS "3 tiers packed, verified in-stream, restored; diff -r empty (spaces, parentheses, symlink, hard link, empty dir, upper-case ext)"
else res T3_synthetic FAIL "$detail"; fi

# ── T4 plan of the real tree ──────────────────────────────────────────────────
PLAN="$ST/units_plan.tsv"; printf 'unit\tmode\tstem\ttier\tfiles\traw_bytes\tnewest\n' > "$PLAN"
n_units=0; odd=0; W4="$WORK/t4"
while IFS=$'\t' read -r unit mode; do
    n_units=$((n_units + 1)); rm -rf "${W4:?}"; mkdir -p "$W4"
    list_unit_files "$unit" "$mode" | classify_into "$W4" || { odd=$((odd + 1)); log "  odd names in $unit: $(head -c 200 "$W4/bad.tsv")"; }
    for t in core media weights; do
        read -r n b < <(tsv_stats "$W4/$t.tsv")
        newest="$(awk -F'\t' '$3 > m { m = $3 } END { print substr(m, 1, 16) }' "$W4/$t.tsv")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$unit" "$mode" "$(unit_stem "$unit")" "$t" "$n" "$b" "$newest" >> "$PLAN"
    done
done < <(list_units)
clash="$(awk -F'\t' 'NR > 1 { print $1 "\t" $3 }' "$PLAN" | sort -u | cut -f2 | sort | uniq -d | tr '\n' ' ')"
read -r raw_all raw_core raw_media raw_weights big big_id < <(awk -F'\t' 'NR > 1 { a += $6; r[$4] += $6
        if ($6 > m) { m = $6; id = $3 "." $4 } } END { printf "%.0f %.0f %.0f %.0f %.0f %s\n", a, r["core"], r["media"], r["weights"], m, id }' "$PLAN")
files_all="$(awk -F'\t' 'NR > 1 { n += $5 } END { printf "%.0f", n }' "$PLAN")"
kv N_UNITS "$n_units"; kv TOTAL_FILES "$files_all"; kv TOTAL_RAW_BYTES "$raw_all"; kv RAW_CORE_BYTES "$raw_core"
kv RAW_MEDIA_BYTES "$raw_media"; kv RAW_WEIGHTS_BYTES "$raw_weights"; kv LARGEST_ARCHIVE_RAW_BYTES "$big"
since="$(date -d '24 hours ago' '+%Y-%m-%d %H:%M' 2>/dev/null)"
live="$(awk -F'\t' -v s="$since" 'NR > 1 && $7 >= s { print $1 }' "$PLAN" | sort -u | tr '\n' ' ')"
kv LIVE_UNITS "$live"
if [ -n "$live" ]; then
    res T4_live WARN "written in the last 24 h: ${live}— pause the jobs writing there, or SKIP_UNITS=\"…\" now and pack them later"
else
    res T4_live PASS "no unit was written in the last 24 h"
fi
if [ "$odd" -eq 0 ] && [ -z "$clash" ]; then
    res T4_plan PASS "$n_units units, $files_all files, $(hb "$raw_all") raw = core $(hb "$raw_core") + media $(hb "$raw_media") + weights $(hb "$raw_weights"); largest archive $big_id $(hb "$big") raw → units_plan.tsv"
else
    res T4_plan FAIL "odd-name units: $odd · stem clashes: ${clash:-none}"
fi

# ── T5 smallest real unit: compress → restore → diff ─────────────────────────
pick="$(awk -F'\t' 'NR > 1 && $2 == "tree" { b[$1] += $6; n[$1] += $5 }
        END { for (u in b) if (n[u] > 0 && b[u] < 200 * 1048576) printf "%.0f\t%s\n", b[u], u }' "$PLAN" | sort -n | awk -F'\t' 'NR == 1 { print $2 }')"
if [ -n "$pick" ]; then
    W5="$WORK/t5"; mkdir -p "$W5/tsv" "$W5/arch" "$W5/rec" "$W5/restore"; ok=1; MANIFESTS_SAVE="$MANIFESTS"; MANIFESTS="$W5/rec"
    list_unit_files "$pick" tree | classify_into "$W5/tsv" || ok=0
    for t in core media weights; do
        [ -s "$W5/tsv/$t.tsv" ] || continue
        pack_one "$pick" tree "$t" "$W5/tsv/$t.tsv" file "$W5/arch" "$W5/rec/$t.packed" || ok=0
        zstd -dc "$W5/arch/$(unit_stem "$pick").$t.tar.zst" | tar -xf - -C "$W5/restore" || ok=0
    done
    MANIFESTS="$MANIFESTS_SAVE"
    diff -r --no-dereference "$REPO/$LOGS_REL/$pick" "$W5/restore/$LOGS_REL/$pick" > "$W5/diff" 2>&1 || ok=0
    if [ "$ok" = 1 ]; then res T5_real_roundtrip PASS "logs/$pick restored byte-identical (diff -r empty)"
    else res T5_real_roundtrip FAIL "logs/$pick: $(head -c 300 "$W5/diff")"; fi
else
    res T5_real_roundtrip SKIP "no tree unit under 200 MiB"
fi

# ── T6 ratio + speed probe on a real ~1.5 GiB unit ───────────────────────────
probe="$(awk -F'\t' 'NR > 1 && $2 == "tree" { b[$1] += $6 } END { for (u in b) if (b[u] > 0) { d = b[u] - 1.5 * 1073741824
        if (d < 0) d = -d; printf "%.0f\t%s\n", d, u } }' "$PLAN" | sort -n | awk -F'\t' 'NR == 1 { print $2 }')"
r_core=0.45; r_media=0.97; r_weights=0.93; speed=""; pdetail=""
if [ -n "$probe" ]; then
    W6="$WORK/t6"; mkdir -p "$W6"; list_unit_files "$probe" tree | classify_into "$W6"
    tot_raw=0; tot_s=0
    for t in core media weights; do
        [ -s "$W6/$t.tsv" ] || continue
        read -r n b < <(tsv_stats "$W6/$t.tsv"); [ "$b" -gt 0 ] || continue
        s0=$(date +%s.%N); pack_one "$probe" tree "$t" "$W6/$t.tsv" null - - || continue; s1=$(date +%s.%N)
        r="$(ratio "$PACK_ARC_BYTES" "$b")"; eval "r_$t=$r"
        tot_raw=$((tot_raw + b)); tot_s="$(awk -v a="$tot_s" -v d="$(secs "$s0" "$s1")" 'BEGIN { printf "%.3f", a + d }')"
        pdetail+=" $t x$r @ $(mbps "$b" "$(secs "$s0" "$s1")") MB/s;"
    done
    speed="$(mbps "$tot_raw" "$tot_s")"
fi
est="$(awk -v c="$raw_core" -v m="$raw_media" -v w="$raw_weights" -v rc="$r_core" -v rm="$r_media" -v rw="$r_weights" \
        'BEGIN { printf "%.0f", c * rc + m * rm + w * rw }')"
eta_pack="$(awk -v b="$raw_all" -v s="${speed:-0}" 'BEGIN { if (s > 0) printf "%.0f min", b / 1e6 / s / 60; else printf "n/a" }')"
kv RATIO_CORE "$r_core"; kv RATIO_MEDIA "$r_media"; kv RATIO_WEIGHTS "$r_weights"; kv PROBE_MBPS "${speed:-0}"; kv EST_TOTAL_ARC_BYTES "$est"
res T6_probe INFO "probe unit ${probe:-none}:${pdetail:- defaults used} → bundle ≈ $(hb "$est") (from $(hb "$raw_all") raw), packing ≈ $eta_pack at ${speed:-?} MB/s"

# ── T7 Google Drive round-trip (route B) ─────────────────────────────────────
drive_ok=skip
if have_remote; then
    RT="$(remote_stamp "_selftest_$TS")"; ok=1; detail=""
    free="$(drive_free --contimeout 15s --timeout 30s --retries 1 --low-level-retries 2)"
    if [ -z "$free" ] && ! rclone lsf "$GDRIVE_REMOTE:" --max-depth 1 --contimeout 15s --timeout 30s --retries 1 --low-level-retries 2 >/dev/null 2>&1; then
        ok=0; detail="no connection from $(hostname) to Google Drive (compute node without internet?) → route A"
    else
        rclone copyto "$ARCHIVES/demo.core.tar.zst" "$RT/archives/demo.core.tar.zst" "${RCLONE_FLAGS[@]}" \
            && remote_md5_ok "$RT/archives/demo.core.tar.zst" "$(rget "$RECEIPTS/demo.core.packed" md5)" || { ok=0; detail+=" copyto"; }
        REPO="$SYN"; MANIFESTS_SAVE="$MANIFESTS"; MANIFESTS="$WORK"
        pack_one demo tree media "$W3/media.tsv" rcat "$RT/archives" "$WORK/rcat.receipt" || { ok=0; detail+=" rcat"; }
        REPO="$REPO_REAL"; MANIFESTS="$MANIFESTS_SAVE"
        mkdir -p "$WORK/dl" "$WORK/restore7"
        for t in core media; do rclone copyto "$RT/archives/demo.$t.tar.zst" "$WORK/dl/demo.$t.tar.zst" "${RCLONE_FLAGS[@]}" || { ok=0; detail+=" download:$t"; }; done
        [ "$(sha256sum < "$WORK/dl/demo.core.tar.zst" | cut -d' ' -f1)" = "$(rget "$RECEIPTS/demo.core.packed" sha256)" ] || { ok=0; detail+=" sha256"; }
        cp "$ARCHIVES/demo.weights.tar.zst" "$WORK/dl/"
        for t in core media weights; do zstd -dc "$WORK/dl/demo.$t.tar.zst" | tar -xf - -C "$WORK/restore7" || { ok=0; detail+=" extract:$t"; }; done
        diff -r --no-dereference "$SYN/logs/demo" "$WORK/restore7/logs/demo" >/dev/null 2>&1 || { ok=0; detail+=" diff"; }
        head -c "${LOGARCH_SPEED_MB:-512}M" /dev/urandom > "$WORK/speed.bin"
        s0=$(date +%s.%N); rclone copyto "$WORK/speed.bin" "$RT/speed.bin" "${RCLONE_FLAGS[@]}" || { ok=0; detail+=" speed-upload"; }; s1=$(date +%s.%N)
        up="$(mbps $(("${LOGARCH_SPEED_MB:-512}" * MiB)) "$(secs "$s0" "$s1")")"
        rclone purge "$RT" >/dev/null 2>&1 || detail+=" (purge of $RT failed — delete it by hand)"
        kv DRIVE_UP_MBPS "$up"; kv DRIVE_FREE_BYTES "${free:-unknown}"
        eta_b="$(awk -v b="$est" -v u="$up" -v p="${speed:-0}" 'BEGIN { r = u; if (p > 0 && p * 0.8 < r) r = p * 0.8
                  if (r <= 0) { print "n/a"; exit } h = b / 1e6 / r / 3600; printf "%.1f h (%s)", h, (h < 6 ? "one job" : "auto-continues over " int(h / 7 + 1) " jobs") }')"
        kv ROUTE_B_HOURS "$eta_b"
        detail="Drive free $(hb "${free:-0}") · upload ${up} MB/s → raw layer ≈ $eta_b · copyto+rcat+download+sha256+restore${detail:- OK}"
    fi
    if [ "$ok" = 1 ]; then drive_ok=1; res T7_gdrive PASS "$detail"; else drive_ok=0; res T7_gdrive FAIL "$detail"; fi
else
    res T7_gdrive SKIP "no rclone remote '$GDRIVE_REMOTE:' on the cluster (plan §4.2) — route B untested"
fi
kv DRIVE_OK "$drive_ok"

# ── T8 download kit for the laptop leg ───────────────────────────────────────
head -c "${LOGARCH_KIT_MB:-256}M" /dev/urandom > "$ST/speed.bin"
summarize
res T8_kit PASS "mini bundle in $ST (3 archives, receipts, manifests, SHA256SUMS) + speed.bin ${LOGARCH_KIT_MB:-256} MiB → laptop: logarch_local.sh selftest"

# ── verdict ───────────────────────────────────────────────────────────────────
budget_gb=$(( (home_free - MIN_FREE_GB * GiB) / GiB - 5 )); [ "$budget_gb" -gt 20 ] && budget_gb=20
{ echo; echo "## Verdict"; echo
  if [ "$FAILS" -gt 0 ]; then echo "**$FAILS test(s) FAILED — do not start a real run.**"; echo; fi
  dfree="$(awk -F= '$1 == "DRIVE_FREE_BYTES" { print $2 }' "$ENVF")"
  if [ "$drive_ok" = 1 ] && [ -n "$dfree" ] && [ "$dfree" != unknown ] && [ "$dfree" -gt $((est + est / 10)) ]; then
      echo "- **Route B (recommended): Google Drive direct.** \`./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_pack_gdrive.sh <STAMP>\`"
  elif [ "$drive_ok" = 1 ]; then
      echo "- Drive reachable, but free $(hb "${dfree:-0}") < bundle estimate $(hb "$est") + 10 % → more Drive storage, or TIERS=core first."
  else
      echo "- **Route A: rolling download.** Laptop: \`logarch_local.sh pull-rolling <STAMP>\` (BUDGET_GB=$budget_gb)."
  fi
  if [ "$budget_gb" -lt $(( big / GiB + 1 )) ]; then
      echo "- ⚠️ Route A cannot stage the largest archive ($big_id, $(hb "$big") raw) above the $MIN_FREE_GB GiB guard — use route B or free space first."
  fi
  echo "- Bundle estimate $(hb "$est") · packing ≈ $eta_pack · largest archive $big_id ($(hb "$big") raw)"
} >> "$REPORT"
log "report: $REPORT"
cat "$REPORT"
[ "$FAILS" -eq 0 ] || exit 1
