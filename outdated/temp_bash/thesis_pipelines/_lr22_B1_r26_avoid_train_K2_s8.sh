#!/bin/bash
#SBATCH --job-name=B1_r26_avoid_train_K2_s8
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
export LR_SEED=8
export PANEL_WANDB=1
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
CKPT="logs/avoiding-d3il/diffusion/H8_K${LR_K}_Dmodels.GaussianDiffusion_aw10/${LR_SEED}"
if [ -d "$CKPT" ] && ls "$CKPT"/state_*.pt >/dev/null 2>&1; then
    echo "[ lr22 ] ❌ $CKPT already holds checkpoints — refusing to retrain over it"; exit 2
fi
python "Slurm_Codes/temp_bash/_lr22_avoid_train.py"
echo "[ lr22 ] checkpoint dir: $CKPT"
ls -1 "$CKPT" 2>/dev/null | tail -5 || { echo "[ lr22 ] ❌ no checkpoint written"; exit 2; }
echo "Training completed successfully."
