#!/bin/bash
# Gen15 U18 — pack the R39 pillars-v2 LIVE results (tag p23uavpv2live) + plant sidecars into ONE tar.gz under
# export_tmp/ (the folder export_to_laptop.sh already uses), for scp to the laptop.
#
#   bash Slurm_Codes/temp_bash/export_20260923_p23_pillars_live.sh            # pack (default tag p23uavpv2live)
#   TAG=p23uavpv2live bash Slurm_Codes/temp_bash/export_20260923_p23_pillars_live.sh
#   then on the laptop:  scp <cluster>:~/FMPCC/FM-PCC/export_tmp/p23_pillars_live_<stamp>.tar.gz temp/23-09/
#
# What goes in (all small: npz + png + eval/realtime logs + provenance json; no GIFs exist for these runs):
#   logs/avoiding-d3il/plans/flow_matching_v3_meanflow/<train>/H8_K{1,2}_*_msg${TAG}/     (MeanFM K1, K2)
#   logs/avoiding-d3il/plans/flow_matching_v3_alphaflow/<train>/H8_K{1,2}_*_msg${TAG}/    (CI-MeanFM K1, K2)
#   logs/UAV_MIX/uav-pillars/plans/avoiding_bridge/_live/${TAG}/                            (plant sidecars)
#   Slurm_Codes/logs/*/*live_p23_pillars_*.log                                             (the 4 job logs)
set -eo pipefail
cd "$(dirname "$0")/../.."          # repo root
TAG="${TAG:-p23uavpv2live}"
STAMP=$(date +%Y%m%d_%H%M%S)
OUT="export_tmp/p23_pillars_live_${STAMP}.tar.gz"
mkdir -p export_tmp

# collect the folders (relative paths, so the archive unpacks into the same tree)
LIST=$(mktemp)
find logs/avoiding-d3il/plans/flow_matching_v3_meanflow logs/avoiding-d3il/plans/flow_matching_v3_alphaflow \
     -maxdepth 3 -type d -name "*_msg${TAG}" 2>/dev/null >> "$LIST" || true
[ -d "logs/UAV_MIX/uav-pillars/plans/avoiding_bridge/_live/${TAG}" ] && echo "logs/UAV_MIX/uav-pillars/plans/avoiding_bridge/_live/${TAG}" >> "$LIST"
ls Slurm_Codes/logs/*/*live_p23_pillars_*.log 2>/dev/null >> "$LIST" || true

echo "[ export ] tag=${TAG}  items:"
sed 's/^/   /' "$LIST"
N=$(wc -l < "$LIST")
if [ "$N" -lt 5 ]; then echo "[ export ] expected 4 result trees + 1 sidecar dir (+ logs); found $N entries — check the tag / paths above"; fi
echo "[ export ] sizes:"; xargs -a "$LIST" du -sh 2>/dev/null | sed 's/^/   /'

tar -czf "$OUT" -T "$LIST"
rm -f "$LIST"
echo "[ export ] wrote $OUT  ($(du -h "$OUT" | cut -f1))"
echo "[ export ] contents check: $(tar -tzf "$OUT" | grep -c '\.npz$') npz, $(tar -tzf "$OUT" | grep -c 'uav_plant_records' ) sidecars, $(tar -tzf "$OUT" | grep -c 'live_p23_pillars.*\.log$') job logs"
echo "[ export ] scp it to the laptop and unpack in temp/23-09/:  tar -xzf $(basename "$OUT")"
