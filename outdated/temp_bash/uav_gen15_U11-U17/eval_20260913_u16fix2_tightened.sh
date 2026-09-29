#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# U16 FIX 2 — injection: -pdes + DPCC tightening, and HardFlow now honours x_active
#
#   usage:  bash Slurm_Codes/temp_bash/eval_20260913_u16fix2_tightened.sh
#
# RESULT OF FIX 1 (-pdes, temp/1309/test_Pde): overshoot GONE (drone at x=2: -0.35/-0.37 vs -0.63),
# slide depth 8-9 cm -> 1-2 cm, DPCC-pdes reached the goal on L. Still 0/2 collision-free: the drone now
# RIDES the limit (~80% of violating steps < 5 mm, none > 2.5 cm).
# HardFlow also drifted after the exit (y -0.57 at x=2.8): a PRE-EXISTING bug, HardFlow built its NLP once
# with every x_active halfspace always on. Fixed in this pull (update_constraint_list per replan).
#
# FIX 2 = two things, each aimed at one measured failure:
#   -tightened   DPCC's own margin (enlarge_constraints 0.025 m) > every -pdes penetration seen (<= 2.5 cm)
#   HF gating    hardflow_new* now switches x_active halfspaces per replan, like the DPCC arm always did
#
# variants  dpcc-t-bounds_free-tightened-pdes   DPCC, -pdes + margin
#           hardflow_new-pdes                    HF, gating fix only  (isolates the bug fix; OVERWRITES the remote
#                                                hardflow_sls-pdes folder -- the buggy copy is kept locally in test_Pde)
#           hardflow_new-tightened-pdes          HF, gating fix + margin
#
# WIN (the user's own definition: "slide along the halfspace and cross the final line")
#   relaxed_and_constraints = crossed the finish line AND zero violations. Strict success also needs the
#   goal point; route C cannot reach it after being pushed down -0.37 (the corridor model never learned
#   sideways motion), so strict is reported but is not the demo criterion.
#
# PREDICTION (before the run)
#   dpcc-...-tightened-pdes   collision_free on L and C (margin 2.5 cm > max penetration seen)
#   hardflow_new-pdes         no drift past the exit (y at x=2.8 near -0.39, was -0.57); still shallow violations
#   hardflow_new-tightened-pdes  collision_free on L and C
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
VARIANTS=dpcc-t-bounds_free-tightened-pdes,hardflow_new-pdes,hardflow_new-tightened-pdes
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
grep -q "def update_constraint_list" mix_uav/sampling/hardflow_projection.py \
    || { echo "[FAIL] hardflow_projection.py has no update_constraint_list -- pull U16 fix 2 first."; exit 1; }
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

  expect:  UAV_MIX_VARIANTS -> running 2/... variants: ['dpcc-t-bounds_free-tightened-pdes', 'hardflow_new-pdes', 'hardflow_new-tightened-pdes']
           [ U16 ] geo entry 'corridor_v2_slide': MuJoCo scene .../scene_corridor_v2.xml ...
                   walls: wall_y_neg y=-1.00 half=0.05, wall_y_pos y=+1.00 half=0.05   <- NOT +/-0.50
           geo variants for 'corridor': ['corridor_v2_slide']   ... hs=3, obs=4
           Fix_16 DEGENERATE actions[1] ... eps=2.188e-02                              <- NOT 2.2e-05
           results path containing  corridor_cv2s_
  must NOT see:  render unavailable   /   geometry overlay on GIF frames failed

Then download the whole `corridor_cv2s_...` folder plus the CHILD log into temp/<ddmm>/.
The GIFs are in <variant>/diagnostics/rollout_<i>.gif.
NOTE
