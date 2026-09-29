# THROWAWAY — written by pipeline_20260922_all_lacking_runs.sh. Gitignored. Read AT JOB START.
# scripts/eval.py with the `plan` block's n_diffusion_steps overridden in memory, so the
# loadpath resolves to the K=<K> checkpoints. Seeds, n_trials, geometries and variants come
# from config/projection_eval.yaml (the DPCC protocol: 5 seeds x 3 geometries x 2 episodes).
import importlib, os, sys, runpy
K   = int(os.environ['LR_K'])
mod = importlib.import_module('config.avoiding-d3il')
blk = mod.base['plan']
blk['n_diffusion_steps'] = K
print(f'[ lr22 ] EVAL   n_diffusion_steps -> {K}   '
      f'(loadpath: diffusion/H{blk["horizon"]}_K{K}_D{blk["diffusion"]}_aw{blk["action_weight"]})   '
      f'tag=_msg{os.environ.get("FMPCC_RUN_MSG", "")}', flush=True)
sys.argv = ['scripts/eval.py']
if os.environ.get('LR_SEED', '').strip():
    sys.argv += ['--seed', os.environ['LR_SEED']]
runpy.run_path('scripts/eval.py', run_name='__main__')
