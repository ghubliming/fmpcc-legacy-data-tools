#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# U16 — corridor_v2 PAPER evaluation (all engines, projector -pdes + -tightened)
#
#   bash Slurm_Codes/temp_bash/eval_20260913_u16_corridor_v2_paper.sh          # PLAN  (default): print every job + checkpoint checks, submit NOTHING
#   bash Slurm_Codes/temp_bash/eval_20260913_u16_corridor_v2_paper.sh smoke    # SMOKE: ONE short job (mf, K=3, 3 trials = L/C/R, GIF on) to validate the paper names
#   bash Slurm_Codes/temp_bash/eval_20260913_u16_corridor_v2_paper.sh submit   # SUBMIT the full wave
#
#   overrides:  ENGINES="mf fm af diffusion"  SEEDS="6"  NTRIALS=12  RECORD=none  bash ... submit
#
# FIXED FOR EVERY ARM (the U16 bench that passed fix 2):
#   scene/geo   corridor_v2_slide  (scene_corridor_v2.xml, walls ±1.0, 14° slide)   — unchanged
#   normaliser  FMPCC_SAFE_EPS_FRAC=1.0, FMPCC_SAFE_EPS_MODE=scaled
#   projector   geometry on the setpoint (-pdes) + DPCC margin (-tightened), action cap off (-bounds_free)
#   metrics     exactly as pillars / s_curve (strict success, S&C, violations on the real drone)
#   tag         FMPCC_UAV_EVAL_TAG=u17cv2  -> results in E<engine>_K<k>_..._u17cv2/, never mixed with injections
#
# ARMS (names keep `-tightened` LAST: DA_UAV_v1 reads it with endswith)
#   diffuser                                      unprojected reference
#   dpcc-{r,c,t}-bounds_free-pdes-tightened       DPCC, random / min-cost / temporal selection
#   hardflow_new-bounds_free-pdes-tightened       HardFlow B=1          (flow engines, K >= 3 only)
#   hardflow_new-t-bounds_free-pdes-tightened     HardFlow B=4, matched to dpcc-t
#
# JOBS PER SEED (split against the 24 h wall; one job per K is launched by eval_k_sweep.sh)
#   mf / fm / af   K=1        diffuser + dpcc-r/c/t                (HardFlow is degenerate at K<=2)
#                  K=3 and 5  part A: diffuser + dpcc-r + dpcc-c
#                             part B: dpcc-t + hardflow B=1 + hardflow-t B=4   (HF never runs without its dpcc row)
#   diffusion      K=20 (a TRAINING property — plan block, no K arg)
#                             part A: diffuser + dpcc-r   part B: dpcc-c + dpcc-t   (no HardFlow: no velocity field)
#                  if no corridor diffusion checkpoint exists: TRAIN + EVAL via uav_mix_ksweep_pipeline.sh
#
# KNOWN, REPORTED AS-IS (not fixed): routes C and R cannot meet strict success on this slide (the corridor
# model never steers back sideways after the forced detour); HardFlow may lose 1-2 mm at the corridor exit.
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

MODE="${1:-plan}"
case "$MODE" in plan|smoke|submit) ;; *) echo "[FAIL] mode must be plan | smoke | submit (got '$MODE')"; exit 1 ;; esac

GEO=corridor_v2_slide
XML=d3il/environments/d3il/models/mj/robot/quadrotor/scenes/scene_corridor_v2.xml
TAG=u17cv2      # the first wave (jobs 25750-25759) ran with this tag - keep it so later seeds / re-runs pool with it
ENGINES="${ENGINES:-mf fm af diffusion}"
SEEDS="${SEEDS:-6}"
NTRIALS="${NTRIALS:-12}"          # 12 = 4 per route (homotopies cycle L, C, R)
RECORD="${RECORD:-none}"          # gif/all renders MuJoCo GIFs for every rollout (slow) — smoke turns it on

PCC_R=dpcc-r-bounds_free-pdes-tightened
PCC_C=dpcc-c-bounds_free-pdes-tightened
PCC_T=dpcc-t-bounds_free-pdes-tightened
HF_1=hardflow_new-bounds_free-pdes-tightened
HF_T=hardflow_new-t-bounds_free-pdes-tightened

# ── pre-flight: the code and config this wave depends on ─────────────────────
fail=0
grep -q "name: ${GEO}\b" config/uav_projection.yaml                || { echo "[FAIL] geo '${GEO}' missing from config/uav_projection.yaml"; fail=1; }
[ -f "$XML" ]                                                       || { echo "[FAIL] $XML missing"; fail=1; }
grep -q "_geo_on_pdes" mix_uav_test/eval_mix_uav.py                 || { echo "[FAIL] eval_mix_uav.py lacks the -pdes toggle (U16 fix 1)"; fail=1; }
grep -q "def update_constraint_list" mix_uav/sampling/hardflow_projection.py || { echo "[FAIL] hardflow_projection.py lacks update_constraint_list (U16 fix 2)"; fail=1; }
grep -q "_TOGGLES = ('-pdes'" mix_uav_test/eval_mix_uav.py          || { echo "[FAIL] eval_mix_uav.py lacks composed-toggle allow-list (U16 fix 2)"; fail=1; }
grep -qE "^diffusion_timestep_threshold: 0.5\b" config/uav_projection.yaml || { echo "[FAIL] diffusion_timestep_threshold is not 0.5"; fail=1; }
grep -q "dpcc-t-bounds_free-pdes-tightened" Data_Analysis/DA_UAV_v1/config.py || echo "[WARN] DA_UAV_v1/config.py does not list the U16 paper-run names (they will still be discovered, just not in the headline table)"
[ "$fail" -eq 0 ] || { echo "ABORT — pull the U16 fixes / paper-run commit first."; exit 1; }
echo "[ ok ] pre-flight passed  (geo=${GEO}, tag=${TAG})"

ckpt_dirs() {   # $1=engine $2=seed -> matching checkpoint dirs (training output, not plans/)
    compgen -G "logs/UAV_MIX/uav-corridor/mix_uav_${1}/*/${2}" || true
}

BASE_ENV=( UAV_EVAL_HOURS=24 FMPCC_SAFE_EPS_MODE=scaled FMPCC_SAFE_EPS_FRAC=1.0
           FMPCC_UAV_EVAL_TAG="${TAG}" UAV_MIX_GEO_VARIANTS="${GEO}" UAV_MIX_GIF_RES=320 )
UNSET=( -u UAV_MIX_BONE_AF -u UAV_MIX_AF_ALPHA_END -u UAV_MIX_EPOCH -u UAV_MIX_CONTROLLER
        -u UAV_MIX_HF_OFF -u FMPCC_HF_ALLOW_DEGENERATE -u UAV_MIX_TRAJ_GIF )
engine_env() {  # extra knobs per engine (af: the corridor af_unet checkpoint of campaign T2)
    case "$1" in af) echo "UAV_MIX_BONE_AF=unet UAV_MIX_AF_ALPHA_END=0.2 UAV_MIX_EPOCH=latest" ;; *) echo "" ;; esac
}

N_JOBS=0
run() {  # $1=label  $2..=command (after env settings)
    local label="$1"; shift
    N_JOBS=$((N_JOBS + 1))
    printf '  %-3s %s\n' "$N_JOBS" "$label"
    if [ "$MODE" = "plan" ]; then return 0; fi
    "$@"
}

flow_job() {  # $1=engine $2=seed $3="K list" $4=variants(csv) $5=trials $6=record $7=tag
    local e="$1" s="$2" ks="$3" v="$4" n="$5" rec="$6" tag="$7"
    # shellcheck disable=SC2046
    run "${e} seed ${s} K=[${ks}] n=${n} rec=${rec}: ${v}" \
        env "${UNSET[@]}" "${BASE_ENV[@]}" FMPCC_UAV_EVAL_TAG="${tag}" UAV_MIX_VARIANTS="${v}" $(engine_env "$e") \
        ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/eval_k_sweep.sh "$e" corridor "$s" "$ks" "$n" fm_only "$rec"
}

# ── SMOKE: one job, validates names / binding / HF gating on all three routes ─
if [ "$MODE" = "smoke" ]; then
    echo; echo "SMOKE — mf, seed 6, K=3, 3 trials (L, C, R), MuJoCo GIF on, tag u16smoke"
    flow_job mf 6 "3" "diffuser,${PCC_T},${HF_T}" 3 gif u16smoke
    cat <<'NOTE'

  check in the CHILD log:
    UAV_MIX_VARIANTS -> running 3/... variants: ['diffuser', 'dpcc-t-bounds_free-pdes-tightened', 'hardflow_new-t-bounds_free-pdes-tightened']
    [ U16 ] geo entry 'corridor_v2_slide': MuJoCo scene .../scene_corridor_v2.xml ... walls ... y=-1.00 ... y=+1.00
    Fix_16 DEGENERATE actions[1] ... eps=2.188e-02
  results: .../Emf_K3_..._u16smoke/6/corridor_cv2s_.../{diffuser, dpcc-t-bounds_free-pdes-tightened, hardflow_sls-t-bounds_free-pdes-tightened}/
  pass = both projected arms collision_free on L, C and R. Then run:  bash <this script> submit
NOTE
    exit 0
fi

# ── PLAN / SUBMIT: the full wave ────────────────────────────────────────────
echo; echo "engines=[${ENGINES}]  seeds=[${SEEDS}]  n_trials=${NTRIALS}  record=${RECORD}  mode=${MODE}"
echo; echo "checkpoints (logs/UAV_MIX/uav-corridor/mix_uav_<engine>/*/<seed>):"
declare -A HAVE
for e in $ENGINES; do
    for s in $SEEDS; do
        d="$(ckpt_dirs "$e" "$s")"
        if [ -n "$d" ]; then HAVE["$e/$s"]=1; echo "  [ ok ] $e seed $s:"; echo "$d" | sed 's/^/           /'
        else HAVE["$e/$s"]=0; echo "  [MISS] $e seed $s: no checkpoint dir"; fi
    done
done

echo; echo "jobs:"
for e in $ENGINES; do
    for s in $SEEDS; do
        if [ "$e" = "diffusion" ]; then
            if [ "${HAVE[$e/$s]}" = "1" ]; then
                for part in "diffuser,${PCC_R}" "${PCC_C},${PCC_T}"; do
                    run "diffusion seed ${s} K=20 (plan block) n=${NTRIALS}: ${part}" \
                        env "${UNSET[@]}" "${BASE_ENV[@]}" UAV_MIX_VARIANTS="${part}" \
                        ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/eval_mix_uav.sh diffusion corridor "$s" "$NTRIALS" fm_only "$RECORD" ""
                done
            else
                run "diffusion seed ${s}: TRAIN + EVAL (no checkpoint) n=${NTRIALS}: diffuser,${PCC_R},${PCC_C},${PCC_T}" \
                    env "${UNSET[@]}" "${BASE_ENV[@]}" UAV_MIX_VARIANTS="diffuser,${PCC_R},${PCC_C},${PCC_T}" \
                    ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/uav_mix_ksweep_pipeline.sh diffusion corridor "$s" "$NTRIALS" fm_only "$RECORD" ""
            fi
            continue
        fi
        if [ "${HAVE[$e/$s]}" != "1" ]; then
            echo "  --  SKIP ${e} seed ${s}: no checkpoint (train it first: ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/train_mix_uav.sh ${e} corridor \"${s}\")"
            continue
        fi
        flow_job "$e" "$s" "1"   "diffuser,${PCC_R},${PCC_C},${PCC_T}" "$NTRIALS" "$RECORD" "$TAG"
        flow_job "$e" "$s" "3 5" "diffuser,${PCC_R},${PCC_C}"          "$NTRIALS" "$RECORD" "$TAG"
        flow_job "$e" "$s" "3 5" "${PCC_T},${HF_1},${HF_T}"             "$NTRIALS" "$RECORD" "$TAG"
    done
done

echo
if [ "$MODE" = "plan" ]; then
    echo "PLAN only — ${N_JOBS} submission(s) listed, nothing submitted."
    echo "(each K list of 2 values launches 2 eval children). Run:  bash $0 smoke   then   bash $0 submit"
    exit 0
fi
cat <<NOTE
Submitted ${N_JOBS} submission(s).

Results:  logs/UAV_MIX/uav-corridor/plans/mix_uav_<engine>/<train-id>/E<engine>_K<k>_mpc4_pid_stopgo_T0.5_${TAG}/<seed>/corridor_cv2s_bounds+dynamics+geo_bounds+halfspace+obstacles/<variant>/
DA (after everything finished):
  ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/DA/run_da_batch_uav.sh "\$(ls -d logs/UAV_MIX/uav-corridor/plans/mix_uav_*/*/E*_${TAG} | paste -sd, -)"
NOTE
