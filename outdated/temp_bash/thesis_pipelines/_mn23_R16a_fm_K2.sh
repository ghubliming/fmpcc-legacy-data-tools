#!/bin/bash
#SBATCH --job-name=mn23_R16a_fm_K2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --gres=gpu:1
#SBATCH --time=6:00:00
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
export MN_ENGINE=fm
export MN_SEED=6
export MN_NCTX=10
export MN_K=2
export MN_ETA=0.5
export MN_EPOCH=
export MN_RECORD=none
export FMPCC_RUN_MSG=R16
export MIX_BONE_FM=unet
export MIX_FILM_MODE_FM=v1
unset MIX_AF_ALPHA_END MIX_AF_ALPHA_SCHED MIX_AF_ALPHA_INIT MIX_AF_ALPHA_CLAMP MIX_AF_ALPHA_GAMMA || true
FMPCC_ROOT="$HOME/FMPCC"; REPO="$FMPCC_ROOT/FM-PCC"
source "$HOME/miniconda3/etc/profile.d/conda.sh"; conda activate FMPCC
export FMPCC="$REPO"; export D3IL_ROOT="$FMPCC/d3il"
export D3IL_ENV_ROOT="$D3IL_ROOT/environments/d3il"
export PYTHONPATH="$FMPCC:$D3IL_ROOT:$D3IL_ENV_ROOT:$PYTHONPATH"
export MUJOCO_GL="egl"; export PYOPENGL_PLATFORM="egl"; export MPLBACKEND="agg"
export PYTHONUNBUFFERED=1
export CUDA_DEVICE_ORDER="PCI_BUS_ID"
export MUJOCO_EGL_DEVICE_ID="${CUDA_VISIBLE_DEVICES%%,*}"
echo "[ GPU-CHECK ] CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES  MUJOCO_EGL_DEVICE_ID=$MUJOCO_EGL_DEVICE_ID"
if [ "$MUJOCO_EGL_DEVICE_ID" != "${CUDA_VISIBLE_DEVICES%%,*}" ]; then
    echo "[ GPU-LEAK ] EGL device != CUDA device -- aborting"; exit 1
fi
unset MIX_PROJ_T MIX_EPOCH MIX_BONE MIX_FILM_MODE HFFM_VARIANTS
cd "$REPO"
python "Slurm_Codes/temp_bash/_mn23_align_eval.py"
echo "[ mn23 ] result dirs written by this run:"
find logs/aligning-d3il-visual -maxdepth 6 -type d -name "*_msg${FMPCC_RUN_MSG}*" 2>/dev/null | sort || true
echo "Evaluation completed successfully."
