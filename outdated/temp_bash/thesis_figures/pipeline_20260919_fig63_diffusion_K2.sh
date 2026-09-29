#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 2026-09-19 — HOTFIX: the last empty panel of fig:raw-plans (diffusion, K=2).
#   logs_in_develop/Writing/Working_Space/data_status/PENDING_20260919_fig63_diffusion_K2_panel.md
#   Ledger row R24.
#
#   bash Slurm_Codes/temp_bash/pipeline_20260919_fig63_diffusion_K2.sh          # PLAN (default): print, submit NOTHING
#   bash Slurm_Codes/temp_bash/pipeline_20260919_fig63_diffusion_K2.sh submit   # SUBMIT
#
# WHAT IT RUNS  (Option B of the PENDING note — the recommended one)
#   ONE job, TWO evaluations, NO training: the GaussianDiffusion engine driven through the
#   `flow_matching_v3_ode_selectable` plan route, sampled at K=1 and K=2 off ONE checkpoint.
#   Both diffusion panels of the figure are redrawn from this job — the row must not mix a
#   trained-at-1 model (the current K=1 panel) with a sampled-at-2 one.
#
# WHY THIS ROUTE AND NOT THE BASELINE ROUTE
#   plans/diffusion/…          — K is a TRAINING decision. config/avoiding-d3il.py:1074 puts K
#                                in diffusion_loadpath ('…/H{horizon}_K{n_diffusion_steps}_…'),
#                                so planning at K=2 looks for a checkpoint trained at 2, and
#                                none exists. That is Option A: a training job. See below.
#   plans/flow_matching_v3_ode_selectable/… — K is a SAMPLING choice. avoiding-d3il.py:1268:
#                                flow_steps_v3 is "K in the results exp_name (not the loadpath)",
#                                and the 19-09 batch already holds K=1,5,10,20 cells under ONE
#                                folder H8_Dmodels.diffusion.GaussianDiffusion_a1.5_b1.0_aw*.
#
# HOW THE ENGINE IS SWITCHED WITHOUT EDITING A TRACKED FILE
#   The plan block `plan_fm_v3_ode_selectable` hard-codes diffusion='models.diffusion.FlowMatchingODE'
#   and has NO env override for it. Rather than sed a tracked config in the working tree — the
#   trap the 09-18 runbook documents for n_trials — this driver writes a THROWAWAY wrapper
#   (_fig63_panel_eval.py, beside this file) that patches the config MODULE dict in memory and
#   then runs the stock eval through runpy. That is exactly the data path the eval itself uses
#   for --flow-steps (eval_flow_matching_v3_ode_selectable.py:57-72), so nothing is monkey-patched
#   that the eval does not already patch itself.
#   ⚠️ The wrapper and the generated sbatch are read AT JOB START. Do not delete
#      Slurm_Codes/temp_bash/_fig63_* until the job is finished.
#
# COST CONTROL
#   --seed 6 only (the panel is seed 6). The yaml's five seeds would be 5x the work for four
#   unused seeds. projection_variants and the three halfspace variants are NOT narrowed: the eval
#   reads config/projection_eval.yaml by a hard-coded path, and narrowing it would mean editing a
#   tracked file. Only seed 6 / both-hard / variant `diffuser` is used by the figure; the rest is
#   sunk cost, and lands as extra rows in the next DA batch rather than being wasted.
#   n_trials MUST stay 2 — the dashboard is then 3000x1000 px, the layout the crop box in
#   plotting/sources.py (2312, 92, 2715, 492) is calibrated for. The driver refuses otherwise.
#
# OPTION A, if the author wants the bottom row to stay "the baseline as DPCC deploys it"
#   Not submitted here, because it needs a TRACKED CONFIG EDIT and a GPU training:
#     1. config/avoiding-d3il.py, the `diffusion` training block: n_diffusion_steps 20 -> 2
#     2. ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/train_dpcc_job.sh   (edit --seeds 6 first)
#     3. put n_diffusion_steps back to 20
#     4. FMPCC_RUN_MSG=planpanel63 ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/eval_dpcc_job.sh --seed 6
#   Only step 4's panel would then replace the empty cell, and the existing K=1 panel stays.
#   Ask before doing this: it is a training run, and cluster disk has been tight all week.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

MODE="${1:-plan}"
HERE="Slurm_Codes/temp_bash"
WRAP="$HERE/_fig63_panel_eval.py"
SB="$HERE/_fig63_panel_job.sh"

SEED="${SEED:-6}"
KS="${KS:-1 2}"
RUN_MSG="${RUN_MSG:-planpanel63}"
# Action weight selects WHICH ode_selectable GaussianDiffusion checkpoint is loaded:
#   aw10 — matches the DPCC baseline's action weight and the other seven panels. Preferred.
#   aw1  — the folder that holds most of the existing K=1/5/20 cells in the batch.
# Leave PANEL_AW unset to let the job pick aw10 if that checkpoint exists, else aw1.
PANEL_AW="${PANEL_AW:-auto}"

say() { printf '%s\n' "$*"; }
hr()  { say "────────────────────────────────────────────────────────────────────────────"; }

# ── guard 1: n_trials must be 2, or the crop box is wrong ────────────────────
# (the yaml is CRLF on this tree — strip \r before comparing)
NT=$(grep -E '^n_trials:' config/projection_eval.yaml | tr -d '\r' | awk '{print $2}')
if [ "$NT" != "2" ]; then
    say "❌ config/projection_eval.yaml has n_trials: $NT — the panel needs 2."
    say "   (2 episodes => the 3000x1000 dashboard the crop box in plotting/sources.py expects.)"
    exit 1
fi

# ── guard 2: 'diffuser' (unprojected) must be in the variant list ────────────
if ! grep -qE "^\s*'diffuser'," config/projection_eval.yaml; then
    say "❌ config/projection_eval.yaml has no 'diffuser' variant — that IS the panel (no projection)."
    exit 1
fi

# ── the wrapper: patch the config module, then run the stock eval ────────────
cat > "$WRAP" <<'PY'
# THROWAWAY — written by pipeline_20260919_fig63_diffusion_K2.sh. Gitignored, do not commit.
# Runs FM_v3_ode_selectable_test/eval_flow_matching_v3_ode_selectable.py with the
# `plan_fm_v3_ode_selectable` block pointed at the GaussianDiffusion engine, so K becomes a
# sampling choice instead of a training one. Same in-memory config-module patch the eval uses
# for --flow-steps; Python caches modules, so the eval's own import sees these values.
import importlib, os, sys, runpy

K  = os.environ['PANEL_K']
AW = int(os.environ['PANEL_AW'])
EXP = os.environ.get('PANEL_EXP', 'avoiding-d3il')

mod = importlib.import_module('config.' + EXP)
blk = mod.base['plan_fm_v3_ode_selectable']
blk['diffusion'] = 'models.diffusion.GaussianDiffusion'
blk['action_weight'] = AW
print(f'[ fig63 ] engine -> {blk["diffusion"]}   aw{AW}   K={K}   (loadpath: '
      f'flow_matching_v3_ode_selectable/H{blk["horizon"]}_D{blk["diffusion"]}'
      f'_a{blk["time_beta_alpha_v3"]}_b{blk["time_beta_beta_v3"]}_aw{AW})', flush=True)

sys.argv = ['eval_flow_matching_v3_ode_selectable.py',
            '--flow-steps', str(K), '--seed', os.environ.get('PANEL_SEED', '6')]
runpy.run_path('FM_v3_ode_selectable_test/eval_flow_matching_v3_ode_selectable.py',
               run_name='__main__')
PY

# ── the sbatch: the stock eval_fmv3_ode_job.sh environment, our python line ──
cat > "$SB" <<'SBATCH_EOF'
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
SBATCH_EOF
chmod +x "$SB"

hr
say "fig:raw-plans · diffusion panel hotfix (R24) — Option B, no training"
hr
say "  route     plans/flow_matching_v3_ode_selectable/  (K is a sampling choice here)"
say "  engine    models.diffusion.GaussianDiffusion      (patched in memory by $WRAP)"
say "  K         $KS          — BOTH panels of the row are redrawn from this job"
say "  seed      $SEED                 n_trials $NT (from config/projection_eval.yaml)"
say "  aw        $PANEL_AW            (auto = aw10 if that checkpoint exists, else aw1)"
say "  tag       _msg$RUN_MSG   — cannot clobber any published cell"
say "  job       1 job, 2 evaluations, 12 h wall limit"
hr
say "  submit: ./Slurm_Codes/submit.sh $SB"
hr

if [ "$MODE" != "submit" ]; then
    say "PLAN only — nothing submitted. Re-run with:  bash $0 submit"
    exit 0
fi

PANEL_KS="$KS" PANEL_SEED="$SEED" PANEL_AW="$PANEL_AW" FMPCC_RUN_MSG="$RUN_MSG" \
    ./Slurm_Codes/submit.sh "$SB"

hr
say "When it finishes, bring back the two dashboards:"
say "  find logs/avoiding-d3il/plans/flow_matching_v3_ode_selectable \\"
say "       -path '*GaussianDiffusion*_msg${RUN_MSG}*' -path '*both-hard*' -name diffuser.png"
say "Land them as:"
say "  Data_Analysis/DA_Result_Curated_MD/Report_20260903_AF_UNet/fig8g_plans_diffusion_K1_seed6.png"
say "  Data_Analysis/DA_Result_Curated_MD/Report_20260903_AF_UNet/fig8h_plans_diffusion_K2_seed6.png"
hr
