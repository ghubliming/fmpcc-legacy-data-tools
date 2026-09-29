#!/bin/bash
#SBATCH --job-name=fig63_panel
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
echo "JOB START: $(date)   ID: $SLURM_JOB_ID   NODE: $(hostname)"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader || echo "no GPU"
echo "GIT REV:   $(git rev-parse --short HEAD 2>/dev/null || echo '-')"
echo "================================================================================"
trap 'echo "================================================================================"; echo "JOB END: $(date)"' EXIT

FMPCC_ROOT="$HOME/FMPCC"; REPO="$FMPCC_ROOT/FM-PCC"
source "$HOME/miniconda3/etc/profile.d/conda.sh"; conda activate FMPCC
export FMPCC="$REPO"; export D3IL_ROOT="$FMPCC/d3il"
export GYM_AV="$D3IL_ROOT/environments/d3il/envs/gym_avoiding_env"
export PYTHONPATH="$FMPCC:$D3IL_ROOT:$GYM_AV:$PYTHONPATH"
export MUJOCO_GL="egl"; export PYOPENGL_PLATFORM="egl"; export MPLBACKEND="agg"
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

# ── pick the checkpoint: aw10 if it exists (matches the baseline and the other panels) ──
CKPT_BASE="logs/avoiding-d3il/flow_matching_v3_ode_selectable"
STEM="H8_Dmodels.diffusion.GaussianDiffusion_a1.5_b1.0_aw"
if [ "${PANEL_AW:-auto}" = "auto" ]; then
    if [ -d "$CKPT_BASE/${STEM}10" ]; then PANEL_AW=10
    elif [ -d "$CKPT_BASE/${STEM}1" ]; then PANEL_AW=1
    else
        echo "[ fig63 ] ❌ no ode_selectable GaussianDiffusion checkpoint under $CKPT_BASE"
        ls -1 "$CKPT_BASE" 2>/dev/null || true
        echo "[ fig63 ]    Option B is not runnable without it — fall back to Option A (train K=2)."
        exit 2
    fi
    echo "[ fig63 ] PANEL_AW=auto -> aw$PANEL_AW"
fi
export PANEL_AW
if [ ! -d "$CKPT_BASE/${STEM}${PANEL_AW}" ]; then
    echo "[ fig63 ] ❌ requested checkpoint $CKPT_BASE/${STEM}${PANEL_AW} does not exist"; exit 2
fi
echo "[ fig63 ] checkpoint: $CKPT_BASE/${STEM}${PANEL_AW}"
[ "$PANEL_AW" != "10" ] && echo "[ fig63 ] ⚠️ aw$PANEL_AW, not the baseline's aw10 — say so in the caption."

for K in ${PANEL_KS:-1 2}; do
    echo "================================================================================"
    echo "[ fig63 ] K = $K   ($(date))"
    echo "================================================================================"
    PANEL_K="$K" python "Slurm_Codes/temp_bash/_fig63_panel_eval.py"
done

echo "[ fig63 ] dashboards written this run:"
find logs/avoiding-d3il/plans/flow_matching_v3_ode_selectable \
     -path "*GaussianDiffusion*_msg${FMPCC_RUN_MSG}*" -name 'diffuser.png' -newermt '-1 day' \
     2>/dev/null | sort || true
echo "Evaluation completed successfully."
