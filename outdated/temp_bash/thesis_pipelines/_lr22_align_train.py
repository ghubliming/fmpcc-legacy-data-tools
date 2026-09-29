# THROWAWAY — written by pipeline_20260922_all_lacking_runs.sh. Gitignored. Read AT JOB START.
# mix_visual_aligning_test/train_mix_visual_aligning.py, diffusion arm, with n_diffusion_steps
# patched in memory (it is a training property AND a checkpoint-path key: H8_K<n>_...).
import importlib, os, sys, runpy
DIFFK = int(os.environ['LR_DIFF_K'])
SEEDS = os.environ.get('LR_SEEDS', '6').split()
mod = importlib.import_module('config.aligning-d3il-visual')
for blk in ('mix_visual_aligning_diffusion', 'plan_mix_visual_aligning_diffusion'):
    b = mod.base[blk]
    print(f"[ lr22 ] {blk}.n_diffusion_steps {b.get('n_diffusion_steps')} -> {DIFFK}", flush=True)
    b['n_diffusion_steps'] = DIFFK
script = 'mix_visual_aligning_test/train_mix_visual_aligning.py'
sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
argv = [script, '--engine', 'diffusion', '--seeds', *SEEDS]
if os.environ.get('PANEL_WANDB', '1') == '1':
    argv += ['--use-wandb', '--wandb-project', 'FM-PCC-visual-aligning-gen14']
print('[ lr22 ] argv: ' + ' '.join(argv), flush=True)
sys.argv = argv
runpy.run_path(script, run_name='__main__')
