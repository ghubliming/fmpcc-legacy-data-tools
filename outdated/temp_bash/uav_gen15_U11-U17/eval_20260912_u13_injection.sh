#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Gen15 U13 — `corridor_ball_v3` FAST INJECTION TEST   (1 job, ~12 min)
#
#   mf · corridor · K=2 · geo=corridor_ball_v2 · seed 6 · n=10 · 2 variants
#
# WHAT CHANGED FROM v2: the ball radius, 0.12 -> 0.05. Nothing else. Same centre
# [0.0, 0.0, 1.13] (on the measured flown path), same walls, same caps, same workspace box,
# same constraint_types, same inflation.
#
#   keep-out        0.43 -> 0.36 m
#   blocked at y=0  z in [0.77, 1.49]   (at y=+/-0.12: [0.79, 1.47])
#   flown band      z in [0.956, 1.236] -> still fully blocked on all three channels
#   escape UP       z in [1.49, 2.49] = 1.00 m wide   (v2: 0.93 m)
#   climb needed    0.43 -> 0.36 m
#
# TWO GATES:
#   1  `diffuser`  n_violations > 0              -> the ball still binds
#   2  `dpcc-t`    collision_free_completed > 0   <- THE ONE THAT DECIDES v3
#
# ⚠️ For the record, so the result is not a surprise: v2 failed gate 2 with `phys_min_z`
# constant to 0.2 mm across 340 rollouts. The measured vertical action authority on corridor
# is 2.2e-05 m/step = 8.7 mm per episode, against a 0.36 m climb. If that cap is what binds,
# a smaller ball does not change it. Job 25682 (`dpcc-t-bounds_free` on v2) tests that cap
# directly and is already queued.
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

GEO=corridor_ball_v3
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

  expect:  [ U11 ] geo variants for 'corridor': ['corridor_ball_v3']
           E9 geo ... variant 'corridor_ball_v3' ... (bounds=True, hs=2, obs=5)
           results path containing  corridor_hgb3_

  GATE 1   diffuser  n_violations > 0
  GATE 2   dpcc-t    collision_free_completed > 0   <- the one that decides U13
NOTE
