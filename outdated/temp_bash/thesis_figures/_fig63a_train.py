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
