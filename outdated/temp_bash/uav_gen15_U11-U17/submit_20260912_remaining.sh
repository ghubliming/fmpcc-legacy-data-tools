#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 2026-09-12 — the two evals still outstanding
#
#   1  pillars · diffusion · `dpcc-t-tightened` only      ~8 h   (eval only)
#      25636 hit its 24 h wall at trial 3/10 on this one variant, leaving an
#      n=3 partial that would pool silently with the n=10 cells. This finishes
#      it so the baseline reference row is 5/5 at matched n.
#
#   2  corridor_ball_v2 · mf · K=2 · +`dpcc-t-bounds_free`   ~12 min  (DIAGNOSTIC)
#      Does the projector fail to route around the ball because its ACTION
#      BOUND has no authority in y/z on corridor?
#        `dpcc-t`             action-magnitude family ON  (as shipped)
#        `dpcc-t-bounds_free` that family OFF; dynamics + geometry still ON
#                             (eval_mix_uav.py:1259 -- substring gate)
#      collision_free > 0  -> the cap IS the blocker  (fix: explicit action_bounds)
#      collision_free = 0  -> the cap is NOT it; the diagnosis is wrong
#
# Sets every knob itself and clears the rest, so a polluted login shell cannot
# leak in. Run from anywhere in the repo:
#     bash Slurm_Codes/temp_bash/submit_20260912_remaining.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

find_repo_root() {
    local d
    for d in "$PWD" "$(cd "$(dirname "$0")" && pwd)"; do
        while [ "$d" != "/" ] && [ -n "$d" ]; do
            if [ -f "$d/Slurm_Codes/submit.sh" ]; then echo "$d"; return 0; fi
            d="$(dirname "$d")"
        done
    done
    return 1
}
REPO="$(find_repo_root)" || { echo "[FAIL] no Slurm_Codes/submit.sh above \$PWD or this script."; exit 1; }
cd "$REPO"; echo "[ ok ] repo root: $REPO"

grep -q "name: corridor_ball_v2\b" config/uav_projection.yaml \
    || { echo "[FAIL] corridor_ball_v2 missing -- pull U12 first."; exit 1; }
grep -q "'dpcc-t-bounds_free'" config/uav_projection.yaml \
    || { echo "[FAIL] dpcc-t-bounds_free not in projection_variants -- pull U12 first."; exit 1; }
echo "[ ok ] config carries corridor_ball_v2 + dpcc-t-bounds_free"
echo

CLEAR=( -u UAV_MIX_BONE_AF -u UAV_MIX_AF_ALPHA_END -u UAV_MIX_EPOCH
        -u UAV_MIX_CONTROLLER -u UAV_MIX_HF_OFF -u FMPCC_HF_ALLOW_DEGENERATE
        -u UAV_MIX_GEO_VARIANTS )

echo "### 1/2  pillars · diffusion · dpcc-t-tightened   (finishes 25636, ~8 h)"
env "${CLEAR[@]}" \
    UAV_EVAL_HOURS=24 FMPCC_SAFE_EPS_MODE=scaled FMPCC_UAV_EVAL_TAG=u7hg \
    UAV_MIX_VARIANTS=dpcc-t-tightened \
    ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/eval_mix_uav.sh \
        diffusion pillars 6 "" fm_only none ""
echo

echo "### 2/2  corridor_ball_v2 · mf · K=2 · action-bound probe   (~12 min)"
env "${CLEAR[@]}" \
    UAV_EVAL_HOURS=24 FMPCC_SAFE_EPS_MODE=scaled FMPCC_UAV_EVAL_TAG=u7hg \
    UAV_MIX_GEO_VARIANTS=corridor_ball_v2 \
    UAV_MIX_VARIANTS=diffuser,dpcc-t,dpcc-t-bounds_free \
    ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/eval_k_sweep.sh mf corridor "6" "2"
echo

cat <<'NOTE'
Submitted 2.

  job 1  results path must contain  pillars_hg_   and  Ediffusion_K20_
         -> gives the baseline reference row 5/5 at n=10

  job 2  results path must contain  corridor_hgb2_
         -> compare, in the SAME log:
              dpcc-t             collision_free_rate   (expect 0.000, as in 25657)
              dpcc-t-bounds_free collision_free_rate   <-- THE ANSWER

Then cut the DA batch so both waves land in one set of CSVs:
  ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/DA/run_da_batch_uav.sh
NOTE
