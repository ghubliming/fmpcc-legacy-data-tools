# THROWAWAY — written by the 2026-09-23 red-wave driver. Gitignored. Read AT JOB START.
import os, sys, runpy, yaml
ENGINE = os.environ['RW_ENGINE']
SEED   = os.environ.get('RW_SEED', '6')
NCTX   = int(os.environ.get('RW_NCTX', '10'))
VARS   = [v for v in os.environ['RW_VARIANTS'].split(',') if v]
GEOS   = [g for g in os.environ['RW_GEOS'].split(',') if g]
ETA    = os.environ['RW_ETA']
K      = os.environ.get('RW_K', '').strip()     # empty for the diffusion arm: K is a TRAINING key
_orig = yaml.safe_load
def _patched(stream):
    d = _orig(stream)
    if isinstance(d, dict) and str(getattr(stream, 'name', '')).endswith('visual_aligning_eval.yaml'):
        print(f"[ rw23 ] yaml n_contexts {d.get('n_contexts')} -> {NCTX}", flush=True)
        print(f"[ rw23 ] yaml projection_variants {len(d.get('projection_variants', []))} -> {VARS}", flush=True)
        print(f"[ rw23 ] yaml active_geo_variants {d.get('active_geo_variants')} -> {GEOS}", flush=True)
        print(f"[ rw23 ] yaml diffusion_timestep_threshold {d.get('diffusion_timestep_threshold')} "
              f"-> {ETA}  (passed as --proj-threshold)", flush=True)
        d['n_contexts'] = NCTX
        d['projection_variants'] = VARS
        d['active_geo_variants'] = GEOS
    return d
yaml.safe_load = _patched
script = 'mix_visual_aligning_test/eval_mix_visual_aligning.py'
sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
argv = [script, '--engine', ENGINE, '--seeds', SEED,
        '--record', os.environ.get('RW_RECORD', 'none'), '--eval-on-train',
        '--proj-threshold', ETA]
if K:
    argv += ['--flow-steps', K]
print('[ rw23 ] argv: ' + ' '.join(argv), flush=True)
print(f"[ rw23 ] identity: engine={ENGINE} seed={SEED} K={K or '<plan block>'} eta={ETA} "
      f"n_contexts={NCTX} eval_on_train=True geos={GEOS} per-step={VARS} "
      f"endpoint={os.environ.get('HFFM_VARIANTS', '<none>')} "
      f"epoch=<config default> tag=_msg{os.environ.get('FMPCC_RUN_MSG','')}", flush=True)
sys.argv = argv
runpy.run_path(script, run_name='__main__')
