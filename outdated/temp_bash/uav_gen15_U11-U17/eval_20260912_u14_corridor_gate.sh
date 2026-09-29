#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# U14 — `corridor_gate`: slanted halfspace across the corridor
#
#   usage:  bash Slurm_Codes/temp_bash/eval_20260912_u14_corridor_gate.sh          # injection (fast)
#           bash Slurm_Codes/temp_bash/eval_20260912_u14_corridor_gate.sh full     # overnight wave
#
# INJECTION  mf, K=2, seed 6, variants diffuser + dpcc-t.  ~20-40 min.  Answers the gates.
# FULL       mf, K=2,5,10, seed 6, full projector set.     overnight.   Only worth it if
#            the injection passes gate 2 or 3.
#
# NOTHING IS MUTATED. Unlike the U13 threshold script this touches no shared key -- the geo
# variant is selected per job through UAV_MIX_GEO_VARIANTS, so no restore step and no queue
# interlock is needed. `diffusion_timestep_threshold` stays at its on-disk value (0.5).
#
# GATES
#   1  diffuser  n_violations > 0                          the gate bites
#   2  dpcc-t    collision_free_completed > 0               the projector solves it
#   3  dpcc-t    executed y differs from diffuser > 1 mm    THE REAL QUESTION (U12 failed this)
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

GEO=corridor_gate
MODE="${1:-inject}"

grep -q "name: ${GEO}\b" config/uav_projection.yaml \
    || { echo "[FAIL] '${GEO}' not in config/uav_projection.yaml -- pull U14 first."; exit 1; }

# the gate line must be the 3rd halfspace of the entry, and x_active must start at 0.40:
# 0.13 is the PLANNER slot; the SCORER's does not open until 0.3327 and collision_free could
# then never reach 1. Guard it so a hand-edit cannot silently break the metric.
grep -q "x_active: \[ 0.40, 2.0\]" config/uav_projection.yaml \
    || { echo "[FAIL] gate x_active is not [0.40, 2.0] -- see U14 changelog section 3."; exit 1; }
echo "[ ok ] geo      = ${GEO}   (x_active guard passed)"

case "$MODE" in
  inject) VARIANTS=diffuser,dpcc-t ;      KS="2"        ;;
  full)   VARIANTS=diffuser,dpcc-r,dpcc-c,dpcc-t,dpcc-t-tightened,dpcc-t-geo_free,dpcc-t-bounds_free
          KS="2 5 10" ;;
  *) echo "[FAIL] mode must be 'inject' or 'full', got '$MODE'"; exit 1 ;;
esac
echo "[ ok ] mode     = ${MODE}"
echo "[ ok ] K        = ${KS}"
echo "[ ok ] variants = ${VARIANTS}"
echo

# env -u clears anything this run must NOT inherit; the assignments override the rest.
env -u UAV_MIX_BONE_AF -u UAV_MIX_AF_ALPHA_END -u UAV_MIX_EPOCH \
    -u UAV_MIX_CONTROLLER -u UAV_MIX_HF_OFF -u FMPCC_HF_ALLOW_DEGENERATE \
    UAV_EVAL_HOURS=24 \
    FMPCC_SAFE_EPS_MODE=scaled \
    FMPCC_UAV_EVAL_TAG=u7hg \
    UAV_MIX_GEO_VARIANTS="${GEO}" \
    UAV_MIX_VARIANTS="${VARIANTS}" \
    ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/eval_k_sweep.sh mf corridor "6" "${KS}"

cat <<'NOTE'

Submitted. When the CHILD log appears:

  grep -hE "U11 . geo|E9 geo|Fix_16 projector|variant=(diffuser|dpcc-t) \(B=" \
      Slurm_Codes/logs/$(date +%F)/*uav_mix_eval*.log

  expect:  [ U11 ] geo variants for 'corridor': ['corridor_gate']
           E9 geo ... 'corridor_gate' ... (bounds=True, hs=3, obs=4)      <- hs=3, not 2
           results path containing  corridor_hgg_
           action_bounds=auto -> lb=[ 1.24e-04 -2.20e-05 ...]             <- the predicted cap

  GATE 1   diffuser  n_violations > 0
  GATE 2   dpcc-t    collision_free_completed > 0
  GATE 3   dpcc-t    executed y differs from diffuser by > 1 mm   <- the one that matters

  Gate 3 needs the rollout logs, so download the batch folder, not just the CSVs.

NOTE
