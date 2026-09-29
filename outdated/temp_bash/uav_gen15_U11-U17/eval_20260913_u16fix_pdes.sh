#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# U16 FIX — injection: same corridor_v2 slide, geometry bound to the SETPOINT p_des (`-pdes`)
#
#   usage:  bash Slurm_Codes/temp_bash/eval_20260913_u16fix_pdes.sh
#
# WHAT IS NEW vs U16 (same scene, same slide, same K/trials/FRAC): ONE change, the constraint binding.
# U16 overshoot: the drone lags its setpoint by ~0.4 m, the projector constrained the lagging drone
# position p and kept pushing the setpoint until the drone caught up -> setpoint wound up to y -0.65
# against a -0.37 limit, the drone followed it down and missed the goal (0/2 success).
# `-pdes` binds halfspace/obstacles/box to the setpoint p_des (the exact integral of the action) and
# gates the slide's x_active by the setpoint's x. Violations are still SCORED on the real drone p.
#
# variants  dpcc-t-bounds_free-pdes | hardflow_new-pdes     (diffuser omitted: identical to U16, keeps
#                                                             U16's result folder untouched)
# OUTPUT    corridor_cv2s_.../<variant>/ incl. diagnostics/rollout_<i>.gif (MuJoCo, 320 px, slide painted)
#
# PREDICTION (written before the run)
#   * no overshoot: drone y at x = 2.0 near the -0.37 limit (U16: -0.63), not on the floor
#   * slide violations fewer/shallower than U16 (30 steps, 8-9 cm): the setpoint leads, so it meets the
#     slide ~0.4 m before the drone does
#   * horizon steps past x = 2 still see the infinite slide line -> may end a few cm deeper than -0.37
#   * goal: L (goal y -0.12) likely reachable; C (goal y 0.00) likely still MISSES by ~7 cm -- the corridor
#     model never learned to steer sideways, so nothing brings it back up after the slide
#
# PASS   no overshoot + collision_free on L and C for at least one projected arm.
#        Goal on C is a stretch, see prediction.
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
VARIANTS=dpcc-t-bounds_free-pdes,hardflow_new-pdes
KS="3"
NTRIALS=2
FRAC=1.0

grep -q "name: ${GEO}\b" config/uav_projection.yaml \
    || { echo "[FAIL] '${GEO}' not in config/uav_projection.yaml -- pull U16 first."; exit 1; }
[ -f "$XML" ] || { echo "[FAIL] $XML missing -- pull U16 first (it is a NEW file: git add it)."; exit 1; }
grep -q "scene_xml" mix_uav_test/eval_mix_uav.py \
    || { echo "[FAIL] eval_mix_uav.py has no scene_xml support -- pull U16 first."; exit 1; }
grep -q "_geo_on_pdes" mix_uav_test/eval_mix_uav.py \
    || { echo "[FAIL] eval_mix_uav.py has no -pdes toggle -- pull the U16 fix first."; exit 1; }
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

  expect:  UAV_MIX_VARIANTS -> running 2/... variants: ['dpcc-t-bounds_free-pdes', 'hardflow_new-pdes']
           [ U16 ] geo entry 'corridor_v2_slide': MuJoCo scene .../scene_corridor_v2.xml ...
                   walls: wall_y_neg y=-1.00 half=0.05, wall_y_pos y=+1.00 half=0.05   <- NOT +/-0.50
           geo variants for 'corridor': ['corridor_v2_slide']   ... hs=3, obs=4
           Fix_16 DEGENERATE actions[1] ... eps=2.188e-02                              <- NOT 2.2e-05
           results path containing  corridor_cv2s_
  must NOT see:  render unavailable   /   geometry overlay on GIF frames failed

Then download the whole `corridor_cv2s_...` folder plus the CHILD log into temp/<ddmm>/.
The GIFs are in <variant>/diagnostics/rollout_<i>.gif.
NOTE
