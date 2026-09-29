#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# U16 — injection: WIDE corridor (scene_corridor_v2.xml) + slide halfspace
#
#   usage:  bash Slurm_Codes/temp_bash/eval_20260913_u16_corridor_v2_slide.sh
#
# WHAT IS NEW vs U15: the MuJoCo scene. Geo entry `corridor_v2_slide` carries
# `scene_xml: scene_corridor_v2.xml`: both corridor walls moved outward in parallel (clear width
# 0.90 -> 1.90 m) so the 0.62 m quadrotor has room to be pushed around a halfspace that visibly
# crosses the routes. Dataset, checkpoint, routes, starts, goals: unchanged `corridor` (no retraining).
# Everything else as U15: FMPCC_SAFE_EPS_FRAC=1.0, K=3, 2 trials, same three variants.
#
# OUTPUT (per variant folder, results path contains corridor_cv2s_):
#   <variant>.png                  top-down with walls, slide, drone-centre limit, drone width, red violations
#   diagnostics/rollout_<i>.gif    MuJoCo overhead GIF, 320 px, slide + walls painted in (orange) with
#                                  the drone-centre limit (red). The matplotlib _traj.gif stays OFF.
#
# SMALL ON PURPOSE (target < 5 min + GIF render):
#   variants  diffuser (control) | dpcc-t-bounds_free (least-constrained PCC) | hardflow_new (HF)
#   K = 3     HardFlow runs no real math at K <= 2 (A=0.5)
#   trials=2  trial 0 = L (blocked x 1.01..2.0), trial 1 = C (blocked x 0.53..2.0)
#
# PASS
#   1  diffuser             hits the slide (it is unprojected) and does not crash into the wide walls
#   2  dpcc-t-bounds_free   L and C slide under the drone-centre limit (y <= -0.37 by x = 2.0), collision_free
#   3  hardflow_new         same, and does not flip
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

GEO=corridor_v2_slide
XML=d3il/environments/d3il/models/mj/robot/quadrotor/scenes/scene_corridor_v2.xml
VARIANTS=diffuser,dpcc-t-bounds_free,hardflow_new
KS="3"
NTRIALS=2
FRAC=1.0

grep -q "name: ${GEO}\b" config/uav_projection.yaml \
    || { echo "[FAIL] '${GEO}' not in config/uav_projection.yaml -- pull U16 first."; exit 1; }
[ -f "$XML" ] || { echo "[FAIL] $XML missing -- pull U16 first (it is a NEW file: git add it)."; exit 1; }
grep -q "scene_xml" mix_uav_test/eval_mix_uav.py \
    || { echo "[FAIL] eval_mix_uav.py has no scene_xml support -- pull U16 first."; exit 1; }
grep -qE "^diffusion_timestep_threshold: 0.5\b" config/uav_projection.yaml \
    || { echo "[FAIL] diffusion_timestep_threshold is not 0.5 -- restore it first."; exit 1; }
echo "[ ok ] geo       = ${GEO}   (scene XML: $(basename "$XML"))"
echo "[ ok ] variants  = ${VARIANTS}"
echo "[ ok ] K = ${KS}   n_trials = ${NTRIALS}   FMPCC_SAFE_EPS_FRAC = ${FRAC}   record = gif (320 px)"
echo

# env -u clears anything this run must NOT inherit; the assignments override the rest.
env -u UAV_MIX_BONE_AF -u UAV_MIX_AF_ALPHA_END -u UAV_MIX_EPOCH \
    -u UAV_MIX_CONTROLLER -u UAV_MIX_HF_OFF -u FMPCC_HF_ALLOW_DEGENERATE -u UAV_MIX_TRAJ_GIF \
    UAV_EVAL_HOURS=24 \
    FMPCC_SAFE_EPS_MODE=scaled \
    FMPCC_SAFE_EPS_FRAC="${FRAC}" \
    FMPCC_UAV_EVAL_TAG=u7hg \
    UAV_MIX_GEO_VARIANTS="${GEO}" \
    UAV_MIX_VARIANTS="${VARIANTS}" \
    UAV_MIX_GIF_RES=320 \
    ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/eval_k_sweep.sh mf corridor "6" "${KS}" "${NTRIALS}" "fm_only" "gif"

cat <<'NOTE'

Submitted. When the CHILD log appears, confirm:

  grep -hE "\[ U16 \]|geo variants for|E9 geo|Fix_16 DEGENERATE actions\[1\]|render unavailable|overlay on GIF" \
      Slurm_Codes/logs/$(date +%F)/*uav_mix_eval*.log

  expect:  [ U16 ] geo entry 'corridor_v2_slide': MuJoCo scene .../scene_corridor_v2.xml ...
                   walls: wall_y_neg y=-1.00 half=0.05, wall_y_pos y=+1.00 half=0.05   <- NOT +/-0.50
           geo variants for 'corridor': ['corridor_v2_slide']   ... hs=3, obs=4
           Fix_16 DEGENERATE actions[1] ... eps=2.188e-02                              <- NOT 2.2e-05
           results path containing  corridor_cv2s_
  must NOT see:  render unavailable   /   geometry overlay on GIF frames failed

Then download the whole `corridor_cv2s_...` folder plus the CHILD log into temp/<ddmm>/.
The GIFs are in <variant>/diagnostics/rollout_<i>.gif.
NOTE
