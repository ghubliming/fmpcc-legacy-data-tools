# THROWAWAY — written by pipeline_20260922_all_lacking_runs.sh. Gitignored. Read AT JOB START.
# mix_visual_aligning_test/eval_mix_visual_aligning.py with the SHARED yaml patched in memory:
#   n_contexts -> LR_NCTX, projection_variants -> LR_VARIANTS, active_geo_variants -> LR_GEOS.
# The yaml file itself is never touched (it is shared with the Gen6V4/Gen7 evals and read at
# job start by anything queued). For the diffusion arm LR_DIFF_K also patches n_diffusion_steps
# on the train AND plan blocks (the plan block mirrors the train key at import, so both).
import importlib, os, sys, runpy, yaml
ENGINE = os.environ['LR_ENGINE']
SEEDS  = os.environ.get('LR_SEEDS', '6').split()
NCTX   = int(os.environ.get('LR_NCTX', '10'))
VARS   = [v for v in os.environ.get('LR_VARIANTS', 'diffuser,dpcc-r,dpcc-c,dpcc-t').split(',') if v]
GEOS   = [g for g in os.environ.get('LR_GEOS', 'combined_5').split(',') if g]
K      = os.environ.get('LR_K', '').strip()
T      = os.environ.get('LR_T', '').strip()
EPOCH  = os.environ.get('LR_EPOCH', '').strip()
DIFFK  = os.environ.get('LR_DIFF_K', '').strip()
mod = importlib.import_module('config.aligning-d3il-visual')
if DIFFK:
    for blk in ('mix_visual_aligning_diffusion', 'plan_mix_visual_aligning_diffusion'):
        b = mod.base[blk]
        print(f"[ lr22 ] {blk}.n_diffusion_steps {b.get('n_diffusion_steps')} -> {DIFFK}", flush=True)
        b['n_diffusion_steps'] = int(DIFFK)
_orig = yaml.safe_load
def _patched(stream):
    d = _orig(stream)
    if isinstance(d, dict) and str(getattr(stream, 'name', '')).endswith('visual_aligning_eval.yaml'):
        print(f"[ lr22 ] yaml n_contexts {d.get('n_contexts')} -> {NCTX}", flush=True)
        print(f"[ lr22 ] yaml projection_variants {len(d.get('projection_variants', []))} entries -> {VARS}", flush=True)
        print(f"[ lr22 ] yaml active_geo_variants {d.get('active_geo_variants')} -> {GEOS}", flush=True)
        d['n_contexts'] = NCTX
        d['projection_variants'] = VARS
        d['active_geo_variants'] = GEOS
    return d
yaml.safe_load = _patched
script = 'mix_visual_aligning_test/eval_mix_visual_aligning.py'
sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
argv = [script, '--engine', ENGINE, '--seeds', *SEEDS,
        '--record', os.environ.get('LR_RECORD', 'none'), '--eval-on-train']
if K:     argv += ['--flow-steps', K]
if T:     argv += ['--proj-threshold', T]
if EPOCH: argv += ['--epoch', EPOCH]
print('[ lr22 ] argv: ' + ' '.join(argv), flush=True)
print(f"[ lr22 ] identity: engine={ENGINE} seeds={SEEDS} n_contexts={NCTX} eval_on_train=True "
      f"K={K or '<block>'} diffK={DIFFK or '<block>'} T={T or '<yaml>'} geos={GEOS} variants={VARS} "
      f"tag=_msg{os.environ.get('FMPCC_RUN_MSG', '')}", flush=True)
sys.argv = argv
runpy.run_path(script, run_name='__main__')
