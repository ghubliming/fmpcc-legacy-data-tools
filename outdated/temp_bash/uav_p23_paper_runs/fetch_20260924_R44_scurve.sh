#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# R44 UAV-s-curve — ONE download for every R44 tag that exists on the cluster: the result folders (results.json, npz,
# png, diagnostics/), the job logs and the job-id ledgers of p23scgrid (A), p23scproj (B), p23scmjpc (C).
# Read-only on the cluster: it only runs tar and md5sum.
#
#   bash Slurm_Codes/temp_bash/fetch_20260924_R44_scurve.sh                 # every R44 tag present (run after B and C)
#   TAGS="p23scgrid" bash Slurm_Codes/temp_bash/fetch_20260924_R44_scurve.sh  # one tag only
#
# Writes export_tmp/R44_scurve_<stamp>.tar.gz and export_tmp/R44_scurve_<stamp>_MANIFEST.txt (md5 of every file).
# Laptop:  scp <cluster>:~/FMPCC/FM-PCC/export_tmp/R44_scurve_<stamp>{.tar.gz,_MANIFEST.txt} temp/<dd-mm>/
#          cd temp/<dd-mm> && tar -xzf R44_scurve_<stamp>.tar.gz          then tell Claude the folder.
# Why: the DA of Table 6.14 is made from the DA_UAV_v1 batch; the npz add the flown paths and the commanded setpoints
# (tracking versus plan at the violating steps, plan smoothness against nfe, the flown-path figure).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/../.."                      # repo root
TAGS="${TAGS:-p23scgrid p23scproj p23scmjpc}"
STAMP=$(date +%Y%m%d_%H%M%S)
OUT="export_tmp/R44_scurve_${STAMP}.tar.gz"
MAN="export_tmp/R44_scurve_${STAMP}_MANIFEST.txt"
mkdir -p export_tmp
LIST="$(mktemp)"
for t in $TAGS; do
    n0=$(wc -l < "$LIST")
    { find logs/UAV_MIX/uav-s_curve/plans -mindepth 3 -maxdepth 3 -type d -name "E*_${t}" 2>/dev/null || true; } | sort >> "$LIST"
    n1=$(wc -l < "$LIST")
    { find Slurm_Codes/logs -maxdepth 2 -type f \( -name "*_${t}_*.log" -o -name "R44_${t}_jobids.tsv" \) 2>/dev/null || true; } \
        | sort >> "$LIST"
    n2=$(wc -l < "$LIST")
    echo "[ fetch ] ${t}: $((n1 - n0)) result folder(s), $((n2 - n1)) log/ledger file(s)"
done
if ! grep -q "^logs/" "$LIST"; then echo "[ fetch ] no R44 result folder found for [${TAGS}] — nothing written"; rm -f "$LIST"; exit 1; fi
tar -czf "$OUT" -T "$LIST"
{
    echo "# R44 s-curve fetch ${STAMP}  tags: ${TAGS}  git $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
    echo "# md5  path   (every file in the archive)"
    while read -r item; do
        if [ -d "$item" ]; then find "$item" -type f | sort | xargs -r md5sum; else md5sum "$item"; fi
    done < "$LIST"
} > "$MAN"
rm -f "$LIST"
echo "[ fetch ] wrote $OUT ($(du -h "$OUT" | cut -f1)): $(tar -tzf "$OUT" | grep -c '/results\.json$') results.json," \
     "$(tar -tzf "$OUT" | grep -c '\.npz$') npz, $(tar -tzf "$OUT" | grep -c '\.log$') job log(s); manifest $MAN ($(grep -vc '^#' "$MAN") files)"
echo "[ fetch ] laptop: scp <cluster>:~/FMPCC/FM-PCC/${OUT%.tar.gz}{.tar.gz,_MANIFEST.txt} temp/<dd-mm>/   then   tar -xzf $(basename "$OUT")"
