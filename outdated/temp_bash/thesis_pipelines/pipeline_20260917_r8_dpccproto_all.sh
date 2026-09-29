#!/usr/bin/env bash
# 2026-09-17 R8 login-shell submission driver. Run with:
#   bash Slurm_Codes/temp_bash/pipeline_20260917_r8_dpccproto_all.sh
#
# It creates this Slurm graph directly from the terminal:
#
#   FM K1/K2 eval ------------------------------ independent
#   CI-MeanFM seeds 7--10 train --> CI-MeanFM K1/K2 eval
#
# At most two Slurm jobs from this wave can run concurrently. Every GPU job has
# its own 24 h allocation; no long phases are combined into one allocation.
set -euo pipefail

find_repo_root() {
    local d
    for d in "$PWD" "$(cd "$(dirname "$0")" && pwd)"; do
        while [ "$d" != "/" ] && [ -n "$d" ]; do
            if [ -f "$d/Slurm_Codes/submit.sh" ]; then
                echo "$d"
                return 0
            fi
            d="$(dirname "$d")"
        done
    done
    return 1
}

REPO="$(find_repo_root)" || {
    echo "[FAIL] no Slurm_Codes/submit.sh above \$PWD or this script."
    exit 1
}
cd "$REPO"
echo "[ ok ] repo root: $REPO"

FM_ENTRY="Slurm_Codes/sbatch/eval_fmv3_ode_job.sh"
TRAIN_ENTRY="Slurm_Codes/sbatch/AlphaFlow/train_alphaflow.sh"
EVAL_ENTRY="Slurm_Codes/sbatch/AlphaFlow/eval_alphaflow.sh"
for entry in "$FM_ENTRY" "$TRAIN_ENTRY" "$EVAL_ENTRY"; do
    [ -f "$entry" ] || { echo "[FAIL] missing $entry"; exit 1; }
done

grep -Eq '^seeds: *\[6, *7, *8, *9, *10\]' config/projection_eval.yaml || {
    echo "[FAIL] config/projection_eval.yaml is not the five-seed protocol."
    exit 1
}
grep -Eq '^n_trials: *2([[:space:]]|$)' config/projection_eval.yaml || {
    echo "[FAIL] config/projection_eval.yaml does not set n_trials: 2."
    exit 1
}
grep -Eq '^n_trials: *2([[:space:]]|$)' config/alphaflow_projection_eval.yaml || {
    echo "[FAIL] config/alphaflow_projection_eval.yaml does not set n_trials: 2."
    exit 1
}

FREE_KIB="$(df -Pk "$REPO" | awk 'NR==2 {print $4}')"
MIN_KIB=$((4 * 1024 * 1024))
if [ -n "$FREE_KIB" ] && [ "$FREE_KIB" -lt "$MIN_KIB" ]; then
    echo "[FAIL] less than 4 GiB free on the repository/log filesystem."
    df -h "$REPO"
    exit 1
fi

# Exact path recorded in Data_Analysis/analysis_results_checkpoint/16_09_logs_tree.txt
# lines 3615--3626. AF_EPOCH=latest resolves to state_80000.pt.
CI_MODEL_DIR="H8_Dflow_matcher_v3_alphaflow.models.AlphaFlowODE_aw10_bbunet_tslogit_normal_ai1.0_ae0.2_ag25.0_rf0.5"
SEED6="logs/avoiding-d3il/flow_matching_v3_alphaflow/$CI_MODEL_DIR/6/state_80000.pt"
[ -f "$SEED6" ] || {
    echo "[FAIL] expected seed-6 checkpoint is missing:"
    echo "       $SEED6"
    exit 1
}

# Match submit.sh's date-organized logging while allowing the dependency option
# required by this aggregate driver. This follows the repository's established
# *_pipeline.sh pattern: the driver uses sbatch --parsable for its child jobs.
DATE="$(date +%Y-%m-%d)"
TIME="$(date +%H_%M_%S)"
LOG_DIR="Slurm_Codes/logs/$DATE"
mkdir -p "$LOG_DIR"
LOG_OPTS=(
    "--output=$LOG_DIR/${TIME}_%x_%j.log"
    "--error=$LOG_DIR/${TIME}_%x_%j.log"
)

echo "[R8-20260917] seed-6 checkpoint: $SEED6"
echo "[R8-20260917] submitting two initial jobs; dependent eval waits for training"
df -h "$REPO"

FM_ID="$(
    env -u AF_BONE -u AF_ALPHA_END -u AF_EPOCH -u AF_SEEDS -u AF_NTRIALS \
        FMV3_FLOW_STEPS="1 2" FMPCC_RUN_MSG=dpccproto \
        sbatch --parsable "${LOG_OPTS[@]}" \
            --job-name=r8_fm_eval_20260917 \
            "$FM_ENTRY"
)"
echo "[1] FM K1/K2 evaluation submitted: $FM_ID"

TRAIN_ID="$(
    env -u AF_SEEDS -u AF_NTRIALS -u AF_FLOW_STEPS -u AF_EPOCH -u FMPCC_RUN_MSG \
        TRAIN_SEEDS="7 8 9 10" AUTO_RESUME=1 AF_BONE=unet AF_ALPHA_END=0.2 \
        sbatch --parsable "${LOG_OPTS[@]}" \
            --job-name=r8_ci_train_20260917 \
            "$TRAIN_ENTRY"
)"
echo "[2] CI-MeanFM seeds 7--10 training submitted: $TRAIN_ID"

EVAL_ID="$(
    env -u TRAIN_SEEDS -u AUTO_RESUME \
        AF_BONE=unet AF_ALPHA_END=0.2 AF_EPOCH=latest \
        AF_SEEDS="6 7 8 9 10" AF_NTRIALS=2 AF_FLOW_STEPS="1 2" \
        FMPCC_RUN_MSG=dpccproto \
        sbatch --parsable "${LOG_OPTS[@]}" \
            --job-name=r8_ci_eval_20260917 \
            --dependency="afterok:$TRAIN_ID" \
            "$EVAL_ENTRY"
)"
echo "[3] CI-MeanFM K1/K2 evaluation queued afterok:$TRAIN_ID: $EVAL_ID"

cat <<NOTE

[R8-20260917] dependency graph
  $FM_ID    FM evaluation (independent)
  $TRAIN_ID CI-MeanFM training (independent)
  $EVAL_ID  CI-MeanFM evaluation (afterok:$TRAIN_ID)

At most two jobs from this wave can RUN concurrently.
No download action was performed.
NOTE

