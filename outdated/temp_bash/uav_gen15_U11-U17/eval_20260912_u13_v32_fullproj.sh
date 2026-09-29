#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# U13 — `corridor_ball_v3_2` at FULL PROJECTION (threshold 0.5 -> 1.0)
#
#   usage:  bash .../eval_20260912_u13_v32_fullproj.sh          # set 1.0 + submit
#           bash .../eval_20260912_u13_v32_fullproj.sh restore  # put 0.5 back
#
# WHAT THIS VARIES. `diffusion_timestep_threshold` gates how many ODE steps the projector
# touches (mf_diffusion.py:284):
#       snapping_start_idx = int((1.0 - threshold) * flow_steps)
#   K=2, T=0.5  -> int(1.0) = 1  -> ONLY the final ODE step of 2 is projected
#   K=2, T=1.0  -> int(0.0) = 0  -> ALL K steps projected
# Ball radius (0.35 / 0.12 / 0.05 / 0.01), the ceiling, and the action-magnitude bound have all
# been ruled out -- every one gave collision_free = 0.000. This is the remaining axis.
#
# ⚠️ TEMPER EXPECTATIONS: at K=5, T=0.5 already projects int(0.5*5)=2 -> steps 2,3,4 = 3 of 5
# (60%), and the U11/U12 Tier-B runs at that setting failed identically. T=1.0 at K=2 is 100%
# of 2 steps -- a modest increase over 60% of 5, not a strong favourite.
#
# 🔴 THE KEY IS SHARED AND IS READ AT **RUN** TIME, NOT SUBMIT TIME.
# config/uav_projection.yaml is read by config/uav.py (Gen11) AND config/uav_mix.py (Gen15).
# A job that starts while the value is 1.0 will USE 1.0. So:
#   * this script refuses to run if any other job of yours is queued or running;
#   * do NOT restore until this job's CHILD log exists and shows T1 (see the note it prints).
# `threshold` is a results-path key, so output lands in `..._T1_...` and cannot pool with T0.5.
# NOTE the tag is built with f'T{thresh:g}' (eval_mix_uav.py:121), so 1.0 renders as "T1".
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

YAML=config/uav_projection.yaml
KEY=diffusion_timestep_threshold
cur() { grep -E "^${KEY}:" "$YAML" | head -1 | awk '{print $2}'; }
setv() { sed -i -E "s|^${KEY}: *[0-9.]+|${KEY}: $1|" "$YAML"; }

if [ "${1:-}" = "restore" ]; then
    setv 0.5
    echo "[ ok ] ${KEY} restored to $(cur)"
    grep -nE "^${KEY}:" "$YAML"
    exit 0
fi

echo "[ ok ] current ${KEY} = $(cur)"
[ "$(cur)" = "0.5" ] || { echo "[FAIL] expected 0.5, found $(cur). Run 'restore' first."; exit 1; }

# the shared key is read at RUN time -> nothing else of ours may be in the queue
OTHERS=$(squeue -u "$USER" -h -o "%i %T %j" 2>/dev/null | grep -v "^$" || true)
if [ -n "$OTHERS" ]; then
    echo "[FAIL] you have jobs in the queue -- they would read the changed threshold at run time:"
    echo "$OTHERS" | sed 's/^/        /'
    echo "        wait for them to finish, or restore the key and run this later."
    exit 1
fi
echo "[ ok ] queue is clear"

GEO=corridor_ball_v3_2
VARIANTS=diffuser,dpcc-t
grep -q "name: ${GEO}\b" "$YAML" || { echo "[FAIL] '${GEO}' not in $YAML -- pull U13 first."; exit 1; }

setv 1.0
echo "[ ok ] ${KEY} set to $(cur)  (FULL projection: all K steps)"
echo

env -u UAV_MIX_BONE_AF -u UAV_MIX_AF_ALPHA_END -u UAV_MIX_EPOCH \
    -u UAV_MIX_CONTROLLER -u UAV_MIX_HF_OFF -u FMPCC_HF_ALLOW_DEGENERATE \
    UAV_EVAL_HOURS=24 \
    FMPCC_SAFE_EPS_MODE=scaled \
    FMPCC_UAV_EVAL_TAG=u7hg \
    UAV_MIX_GEO_VARIANTS="${GEO}" \
    UAV_MIX_VARIANTS="${VARIANTS}" \
    ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/eval_k_sweep.sh mf corridor "6" "2"

cat <<'NOTE'

🔴 THE THRESHOLD IS STILL 1.0 ON DISK. Leave it until the CHILD job has loaded its config.

  1  wait for the child log to appear, then confirm it picked up the new value:
       grep -hE "T1\b|threshold" Slurm_Codes/logs/$(date +%F)/*uav_mix_eval*.log | head
       the results path must contain  _T1_   (NOT _T1.0_ — the tag uses :g, so 1.0 renders as "T1")

  2  ONLY THEN restore:
       bash Slurm_Codes/temp_bash/eval_20260912_u13_v32_fullproj.sh restore

  GATE   dpcc-t  collision_free_completed > 0
         diffuser is unprojected, so it is unaffected by the threshold and should read
         the same 19.60 violations as the T0.5 run -- that is the control.
NOTE
