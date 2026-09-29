# THROWAWAY — written by pipeline_20260922_all_lacking_runs.sh. Gitignored. Read AT JOB START.
# scripts/train.py with the `diffusion` block's n_diffusion_steps overridden in memory
# (the job-25965 pattern). Checkpoint lands in diffusion/H8_K<K>_Dmodels.GaussianDiffusion_aw10/<seed>.
import importlib, os, sys, runpy
K   = int(os.environ['LR_K'])
mod = importlib.import_module('config.avoiding-d3il')
blk = mod.base['diffusion']
blk['n_diffusion_steps'] = K
print(f'[ lr22 ] TRAIN  n_diffusion_steps -> {K}   '
      f'(checkpoint: diffusion/H{blk["horizon"]}_K{K}_D{blk["diffusion"]}_aw{blk["action_weight"]})', flush=True)
sys.argv = ['scripts/train.py', '--seed', os.environ['LR_SEED']]
if os.environ.get('PANEL_WANDB', '1') == '1':
    sys.argv += ['--use-wandb', '--wandb-project', 'FMPCC-knoll']
runpy.run_path('scripts/train.py', run_name='__main__')
