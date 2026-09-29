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
