#!/bin/bash
#SBATCH --job-name=B2_r26_avoid_eval_K2_5seeds
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --gres=gpu:1
#SBATCH --time=12:00:00
#SBATCH --partition=gpu-1-student
set -e
CURRENT_LOG=$(scontrol show job $SLURM_JOB_ID | grep -oP 'StdOut=\K\S+')
[ -n "$CURRENT_LOG" ] && ln -snf "$CURRENT_LOG" Slurm_Codes/logs/latest.log
echo "================================================================================"
echo "JOB START: $(date)   ID: $SLURM_JOB_ID   NODE: $(hostname)   NAME: $SLURM_JOB_NAME"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | head -1 || echo "no GPU"
echo "GIT REV:   $(git rev-parse --short HEAD 2>/dev/null || echo '-')"
echo "================================================================================"
trap 'echo "================================================================================"; echo "JOB END: $(date)"' EXIT
export LR_K=2
export LR_SEED=''
export FMPCC_RUN_MSG=dpccproto
export FMPCC_MPC_BATCH=4
FMPCC_ROOT="$HOME/FMPCC"; REPO="$FMPCC_ROOT/FM-PCC"
source "$HOME/miniconda3/etc/profile.d/conda.sh"; conda activate FMPCC
export FMPCC="$REPO"; export D3IL_ROOT="$FMPCC/d3il"
export GYM_AV="$D3IL_ROOT/environments/d3il/envs/gym_avoiding_env"
export PYTHONPATH="$FMPCC:$D3IL_ROOT:$GYM_AV:$PYTHONPATH"
export MUJOCO_GL="egl"; export PYOPENGL_PLATFORM="egl"; export MPLBACKEND="agg"
export PYTHONUNBUFFERED=1
export CUDA_DEVICE_ORDER="PCI_BUS_ID"
export MUJOCO_EGL_DEVICE_ID="${CUDA_VISIBLE_DEVICES%%,*}"
echo "[ GPU-CHECK ] CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES  MUJOCO_EGL_DEVICE_ID=$MUJOCO_EGL_DEVICE_ID"
if [ "$MUJOCO_EGL_DEVICE_ID" != "${CUDA_VISIBLE_DEVICES%%,*}" ]; then
    echo "[ GPU-LEAK ] EGL device != CUDA device -- aborting"; exit 1
fi
if [ -f "$HOME/FMPCC/.wandb_api_key" ]; then
    export WANDB_API_KEY=$(cat $HOME/FMPCC/.wandb_api_key); export WANDB_MODE="online"
    [ -n "$SLURM_JOB_ID" ] && export WANDB_TAGS="slurm-$SLURM_JOB_ID"
fi
cd "$REPO"
echo "[ lr22 ] disk free on logs:"; df -h logs 2>/dev/null | tail -1 || true
NT=$(grep -E '^n_trials:' config/projection_eval.yaml | tr -d '\r' | awk '{print $2}')
[ "$NT" = "2" ] || { echo "[ lr22 ] ❌ projection_eval.yaml n_trials=$NT at job start — protocol is 2"; exit 2; }
# 🔴 HARDENED 2026-09-22, after job 26056. The old guard only asked whether ANY state_*.pt
# existed. Training writes one every n_steps_per_epoch (1000) up to n_train_steps (1e5), so a
# seed that started minutes ago already passes that test — which is how 26056 came to evaluate
# a half-trained seed 10. The guard now demands the FINAL step, calibrated against seed 6,
# whose checkpoint came from the completed job 25965. Anything short of it aborts the job.
BASE="logs/avoiding-d3il/diffusion/H8_K${LR_K}_Dmodels.GaussianDiffusion_aw10"
last_step() { ls -1 "$1"/state_*.pt 2>/dev/null | sed -E 's/.*state_([0-9]+)\.pt/\1/' | sort -n | tail -1; }
REF="$(last_step "$BASE/6")"
[ -n "$REF" ] || { echo "[ lr22 ] ❌ no seed-6 reference checkpoint under $BASE/6"; exit 2; }
echo "[ lr22 ] reference: seed 6 trained to step $REF (job 25965)"
for s in 6 7 8 9 10; do
    HAVE="$(last_step "$BASE/$s")"
    [ -n "$HAVE" ] || { echo "[ lr22 ] ❌ no K=${LR_K} checkpoint at all for seed $s"; exit 2; }
    if [ "$HAVE" -lt "$REF" ]; then
        echo "[ lr22 ] ❌ seed $s is INCOMPLETE: step $HAVE < reference $REF."
        echo "[ lr22 ]    Its training job has not finished. Refusing to evaluate a half-trained model."
        exit 2
    fi
    echo "[ lr22 ] seed $s: step $HAVE ✅"
done
python "Slurm_Codes/temp_bash/_lr22_avoid_eval.py"
echo "[ lr22 ] result folders:"
find logs/avoiding-d3il/plans/diffusion -maxdepth 3 -type d -path "*K${LR_K}_*" -name "*_msg${FMPCC_RUN_MSG}*" 2>/dev/null | sort || true
echo "Evaluation completed successfully."
