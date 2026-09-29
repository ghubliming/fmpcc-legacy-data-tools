#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 2026-09-19 — fig:raw-plans, the diffusion K=2 panel. OPTION A: train it, then plot it.
#   logs_in_develop/Writing/Working_Space/data_status/PENDING_20260919_fig63_diffusion_K2_panel.md
#   Ledger R24. Replaces the dead Option B (job 25964 — that route's "GaussianDiffusion" is the
#   FLOW model under its pre-26-May class name, so it was never the diffusion engine).
#
#   bash Slurm_Codes/temp_bash/pipeline_20260919_fig63_K2_optionA.sh          # PLAN
#   bash Slurm_Codes/temp_bash/pipeline_20260919_fig63_K2_optionA.sh submit   # SUBMIT both, chained
#
# TWO JOBS, CHAINED
#   1  train   scripts/train.py --seed 6   with n_diffusion_steps = 2
#              -> logs/avoiding-d3il/diffusion/H8_K2_Dmodels.GaussianDiffusion_aw10/6/
#   2  eval    scripts/eval.py  --seed 6   with n_diffusion_steps = 2   (afterok on job 1)
#              -> logs/avoiding-d3il/plans/diffusion/H8_K2_Dmodels.GaussianDiffusion_aw10/
#                 H8_K2_T0.5_Dmodels.GaussianDiffusion_msgplanpanel63/6/results/halfspace_both-hard/diffuser.png
#   The plan block's loadpath is 'f:diffusion/H{horizon}_K{n_diffusion_steps}_D{diffusion}_aw{action_weight}'
#   (config/avoiding-d3il.py:1074) and the train block's exp_name watches the same four keys
#   (args_to_watch_dpcc_train, :146), so setting K=2 on both sides makes them meet. Nothing else
#   in the repo writes or reads that folder — no published cell can be touched.
#
# WHY A WRAPPER INSTEAD OF EDITING config/avoiding-d3il.py
#   n_diffusion_steps has no env override in either block. Editing the tracked config would mean a
#   20 -> 2 -> 20 round trip around a job that reads the file at START, in a working tree shared with
#   other queued jobs — the exact trap SLURM_RUNBOOK_20260918 documents for n_trials, and here it
#   would be open for HOURS while the training runs. So each job patches the config MODULE dict in
#   memory and runs the stock script through runpy. Same data path the ode_selectable eval already
#   uses for --flow-steps. The tracked tree is never modified, so a concurrent job is unaffected.
#   ⚠️ _fig63a_*.py are read AT JOB START. Keep them until both jobs finish.
#
# COST
#   Training is the real cost: n_train_steps 1e5, batch 8, grad-accum 2, one A5000 — a few hours,
#   and the 24 h limit is the usual 2x margin. K=2 does not make it cheaper: the budget changes the
#   noise schedule, not the network or the step count. The eval is seed 6 only and short.
#   Disk: one more checkpoint folder. Check free space before submitting — it has been tight.
#
# WHAT THIS PANEL WILL MEAN
#   A diffusion model TRAINED at K=2 and run at K=2 — the same reading as the existing K=1 panel
#   (trained at 1) and as every other cell of the figure. The row stays internally consistent and
#   the v3.41 caption's claim is unaffected: the budget was still fixed at training time. Filling
#   the cell shows what the baseline's plan fan looks like at that budget; it does not weaken the
#   point that the baseline cannot be re-dialled after training the way a flow model can.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

MODE="${1:-plan}"
HERE="Slurm_Codes/temp_bash"
SEED="${SEED:-6}"
K="${K:-2}"
RUN_MSG="${RUN_MSG:-planpanel63}"
TRAIN_HOURS="${TRAIN_HOURS:-24}"
SKIP_TRAIN="${SKIP_TRAIN:-0}"      # 1 = checkpoint already there, submit only the eval

say() { printf '%s\n' "$*"; }
hr()  { say "────────────────────────────────────────────────────────────────────────────"; }

# ── guard: the panel's crop box assumes 2 episodes ───────────────────────────
NT=$(grep -E '^n_trials:' config/projection_eval.yaml | tr -d '\r' | awk '{print $2}')
if [ "$NT" != "2" ]; then
    say "❌ config/projection_eval.yaml has n_trials: $NT — the panel needs 2"
    say "   (2 episodes => the 3000x1000 dashboard the crop box in plotting/sources.py expects)"
    exit 1
fi
if ! grep -qE "^\s*'diffuser'," config/projection_eval.yaml; then
    say "❌ no 'diffuser' variant in config/projection_eval.yaml — that IS the panel (no projection)"
    exit 1
fi

# ── wrapper 1: train at K=2 ──────────────────────────────────────────────────
cat > "$HERE/_fig63a_train.py" <<'PY'
# THROWAWAY — written by pipeline_20260919_fig63_K2_optionA.sh. Gitignored.
# scripts/train.py with the `diffusion` block's n_diffusion_steps overridden, in memory.
import importlib, os, sys, runpy
K   = int(os.environ['PANEL_K'])
EXP = os.environ.get('PANEL_EXP', 'avoiding-d3il')
mod = importlib.import_module('config.' + EXP)
blk = mod.base['diffusion']
blk['n_diffusion_steps'] = K
print(f'[ fig63a ] TRAIN  n_diffusion_steps -> {K}   '
      f'(checkpoint: diffusion/H{blk["horizon"]}_K{K}_D{blk["diffusion"]}_aw{blk["action_weight"]})',
      flush=True)
sys.argv = ['scripts/train.py', '--seed', os.environ.get('PANEL_SEED', '6')]
if os.environ.get('PANEL_WANDB', '1') == '1':
    sys.argv += ['--use-wandb', '--wandb-project', 'FMPCC-knoll']
runpy.run_path('scripts/train.py', run_name='__main__')
PY

# ── wrapper 2: evaluate at K=2, unprojected panel included ───────────────────
cat > "$HERE/_fig63a_eval.py" <<'PY'
# THROWAWAY — written by pipeline_20260919_fig63_K2_optionA.sh. Gitignored.
# scripts/eval.py with the `plan` block's n_diffusion_steps overridden, so the loadpath
# resolves to the K=2 checkpoint trained by _fig63a_train.py.
import importlib, os, sys, runpy
K   = int(os.environ['PANEL_K'])
EXP = os.environ.get('PANEL_EXP', 'avoiding-d3il')
mod = importlib.import_module('config.' + EXP)
blk = mod.base['plan']
blk['n_diffusion_steps'] = K
print(f'[ fig63a ] EVAL   n_diffusion_steps -> {K}   '
      f'(loadpath: diffusion/H{blk["horizon"]}_K{K}_D{blk["diffusion"]}_aw{blk["action_weight"]})',
      flush=True)
sys.argv = ['scripts/eval.py', '--seed', os.environ.get('PANEL_SEED', '6')]
runpy.run_path('scripts/eval.py', run_name='__main__')
PY

# ── the shared sbatch preamble ───────────────────────────────────────────────
_preamble() {
cat <<'SB'
set -e
CURRENT_LOG=$(scontrol show job $SLURM_JOB_ID | grep -oP 'StdOut=\K\S+')
[ -n "$CURRENT_LOG" ] && ln -snf "$CURRENT_LOG" Slurm_Codes/logs/latest.log
echo "================================================================================"
echo "JOB START: $(date)   ID: $SLURM_JOB_ID   NODE: $(hostname)"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | head -1 || echo "no GPU"
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
SB
}

# ── job 1: train ─────────────────────────────────────────────────────────────
{
cat <<SB
#!/bin/bash
#SBATCH --job-name=fig63a_trainK${K}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --gres=gpu:1
#SBATCH --time=${TRAIN_HOURS}:00:00
#SBATCH --partition=gpu-1-student
SB
_preamble
cat <<'SB'
echo "[ fig63a ] disk free on logs:"; df -h logs 2>/dev/null | tail -1 || true
python "Slurm_Codes/temp_bash/_fig63a_train.py"
CKPT="logs/avoiding-d3il/diffusion/H8_K${PANEL_K}_Dmodels.GaussianDiffusion_aw10/${PANEL_SEED}"
echo "[ fig63a ] checkpoint dir: $CKPT"
ls -1 "$CKPT" 2>/dev/null | tail -5 || { echo "[ fig63a ] ❌ no checkpoint written"; exit 2; }
echo "Training completed successfully."
SB
} > "$HERE/_fig63a_train_job.sh"

# ── job 2: eval ──────────────────────────────────────────────────────────────
{
cat <<SB
#!/bin/bash
#SBATCH --job-name=fig63a_evalK${K}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --gres=gpu:1
#SBATCH --time=12:00:00
#SBATCH --partition=gpu-1-student
SB
_preamble
cat <<'SB'
CKPT="logs/avoiding-d3il/diffusion/H8_K${PANEL_K}_Dmodels.GaussianDiffusion_aw10/${PANEL_SEED}"
if [ ! -d "$CKPT" ]; then
    echo "[ fig63a ] ❌ no K=${PANEL_K} checkpoint at $CKPT — the training job did not deliver"; exit 2
fi
echo "[ fig63a ] loading from $CKPT"
python "Slurm_Codes/temp_bash/_fig63a_eval.py"
echo "[ fig63a ] the panel:"
find logs/avoiding-d3il/plans/diffusion -path "*K${PANEL_K}*_msg${FMPCC_RUN_MSG}*" \
     -path '*both-hard*' -name 'diffuser.png' 2>/dev/null | sort || true
echo "Evaluation completed successfully."
SB
} > "$HERE/_fig63a_eval_job.sh"

chmod +x "$HERE/_fig63a_train_job.sh" "$HERE/_fig63a_eval_job.sh"

hr
say "fig:raw-plans · diffusion K=$K panel — OPTION A: train it, then plot it (R24)"
hr
say "  1  train   scripts/train.py --seed $SEED,  n_diffusion_steps=$K   [${TRAIN_HOURS} h limit, 1 GPU]"
say "     writes  logs/avoiding-d3il/diffusion/H8_K${K}_Dmodels.GaussianDiffusion_aw10/$SEED/"
say "  2  eval    scripts/eval.py  --seed $SEED,  n_diffusion_steps=$K   [afterok on job 1]"
say "     writes  .../plans/diffusion/H8_K${K}_..._msg${RUN_MSG}/$SEED/results/halfspace_both-hard/diffuser.png"
hr
say "  protocol  seed $SEED · both-hard · variant diffuser (unprojected) · n_trials $NT"
say "  tag       _msg$RUN_MSG — its own folder, no published cell can be touched"
say "  config    NOT edited: both jobs patch the module dict in memory (see header)"
[ "$SKIP_TRAIN" = "1" ] && say "  SKIP_TRAIN=1 — only job 2 will be submitted"
hr

if [ "$MODE" != "submit" ]; then
    say "PLAN only — nothing submitted. Re-run with:  bash $0 submit"
    say "Before submitting, check disk:  df -h ~/FMPCC"
    exit 0
fi

export PANEL_K="$K" PANEL_SEED="$SEED" FMPCC_RUN_MSG="$RUN_MSG"

TRAIN_ID=""
if [ "$SKIP_TRAIN" != "1" ]; then
    OUT=$(./Slurm_Codes/submit.sh "$HERE/_fig63a_train_job.sh")
    say "$OUT"
    TRAIN_ID=$(printf '%s\n' "$OUT" | grep -oP 'Job ID:\s*\K[0-9]+' | tail -1)
    [ -z "$TRAIN_ID" ] && { say "❌ could not read the training job id — eval NOT submitted"; exit 1; }
    say "⛓  chaining the eval on afterok:$TRAIN_ID"
    export SBATCH_DEPENDENCY="afterok:$TRAIN_ID"
fi

OUT2=$(./Slurm_Codes/submit.sh "$HERE/_fig63a_eval_job.sh")
say "$OUT2"
unset SBATCH_DEPENDENCY

hr
say "When both are done, fetch the panel:"
say "  find logs/avoiding-d3il/plans/diffusion -path '*K${K}*_msg${RUN_MSG}*' -path '*both-hard*' -name diffuser.png"
say "Land it as:"
say "  Data_Analysis/DA_Result_Curated_MD/Report_20260903_AF_UNet/fig8h_plans_diffusion_K2_seed6.png"
say "The existing K=1 panel stays as it is — both are now trained-at-their-own-budget."
hr
