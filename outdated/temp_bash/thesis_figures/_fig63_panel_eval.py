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
