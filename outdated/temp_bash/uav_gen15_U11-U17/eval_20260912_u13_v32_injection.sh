#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Gen15 U13 — `corridor_ball_v3_2` FAST INJECTION TEST   (1 job, ~12 min)
#
#   mf · corridor · K=2 · geo=corridor_ball_v2 · seed 6 · n=10 · 2 variants
#
# WHAT CHANGED: the ball radius only. 0.05 -> 0.01. A 2 cm ball, 5x smaller than the four
# wall-end caps (r=0.05), 31x smaller than the drone. Same centre [0.0, 0.0, 1.13] -- on the
# measured flown trajectory -- same walls, caps, workspace box, constraint_types, inflation.
#
#   keep-out         0.36 -> 0.32 m
#   blocked at y=0   z in [0.81, 1.45]   (at y=+/-0.12: [0.83, 1.43])
#   flown band       z in [0.956, 1.236] -> still fully blocked on all three channels
#   escape UP        z in [1.45, 2.49] = 1.04 m wide,  climb 0.32 m
#   escape DOWN      z in [0.61, 0.81] = 0.20 m wide
#
# TWO GATES:
#   1  `diffuser`  n_violations > 0              -> the ball still binds
#   2  `dpcc-t`    collision_free_completed > 0   <- THE ONE THAT DECIDES v3_2
#
# ⚠️ Read against the right expectation. r 0.35 / 0.12 / 0.05 all gave cfree 0.000, and so did
# `dpcc-t-bounds_free` with the action cap removed entirely (job 25683). `phys_min_z` has been
# 1.1265-1.1266 in EVERY corridor row measured so far, including plain `corridor_hg` where
# there is no ball at all -- the projector has never changed the plan's altitude under any
# configuration. The keep-out is dominated by the drone's own 0.31 m inflation, so this change
# moves it 0.36 -> 0.32.
#
# This script sets every knob itself and CLEARS the ones it does not use, so a
# polluted login shell cannot leak into the job. (On 2026-09-11 a mangled paste
# left UAV_MIX_GEO_VARIANTS=corridor_ball_v2export and FMPCC_UAV_EVAL_TAG=u7hgexport
# exported in the shell — this script is immune to that.)
#
#     bash Slurm_Codes/temp_bash/eval_20260911_u12_injection.sh
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

GEO=corridor_ball_v3_2
VARIANTS=diffuser,dpcc-t

grep -q "name: ${GEO}\b" config/uav_projection.yaml \
    || { echo "[FAIL] '${GEO}' not in config/uav_projection.yaml -- pull U13 first."; exit 1; }
echo "[ ok ] geo      = ${GEO}"
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
    ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/eval_k_sweep.sh mf corridor "6" "2"

cat <<'NOTE'

Submitted. When the CHILD log appears:

  grep -hE "U11 . geo|E9 geo|variant=(diffuser|dpcc-t) \(B=" \
      Slurm_Codes/logs/$(date +%F)/*uav_mix_eval*.log

  expect:  [ U11 ] geo variants for 'corridor': ['corridor_ball_v3_2']
           E9 geo ... variant 'corridor_ball_v3_2' ... (bounds=True, hs=2, obs=5)
           results path containing  corridor_hgb32_

  GATE 1   diffuser  n_violations > 0
  GATE 2   dpcc-t    collision_free_completed > 0   <- the one that decides U13
NOTE
