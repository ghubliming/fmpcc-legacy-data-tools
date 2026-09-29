# THROWAWAY — written by pipeline_20260923_must_need.sh (R16). Gitignored. Read AT JOB START.
import os, sys, runpy, yaml
ENGINE = os.environ['MN_ENGINE']
SEED   = os.environ.get('MN_SEED', '6')
NCTX   = int(os.environ.get('MN_NCTX', '10'))
K      = os.environ['MN_K']
ETA    = os.environ['MN_ETA']
EPOCH  = os.environ.get('MN_EPOCH', '').strip()
_orig = yaml.safe_load
def _patched(stream):
    d = _orig(stream)
    if isinstance(d, dict) and str(getattr(stream, 'name', '')).endswith('visual_aligning_eval.yaml'):
        print(f"[ mn23 ] yaml n_contexts {d.get('n_contexts')} -> {NCTX}", flush=True)
        print(f"[ mn23 ] yaml projection_variants {len(d.get('projection_variants', []))} -> ['diffuser']", flush=True)
        print(f"[ mn23 ] yaml active_geo_variants {d.get('active_geo_variants')} -> ['combined_5']", flush=True)
        d['n_contexts'] = NCTX
        d['projection_variants'] = ['diffuser']
        d['active_geo_variants'] = ['combined_5']
    return d
yaml.safe_load = _patched
script = 'mix_visual_aligning_test/eval_mix_visual_aligning.py'
sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
argv = [script, '--engine', ENGINE, '--seeds', SEED, '--record', os.environ.get('MN_RECORD', 'none'),
        '--eval-on-train', '--flow-steps', K, '--proj-threshold', ETA]
if EPOCH:
    argv += ['--epoch', EPOCH]
print('[ mn23 ] argv: ' + ' '.join(argv), flush=True)
print(f"[ mn23 ] identity: engine={ENGINE} seed={SEED} K={K} eta={ETA} (names the folder; unprojected) "
      f"n_contexts={NCTX} geo=combined_5 variant=diffuser epoch={EPOCH or '<config default>'} "
      f"af_alpha_end={os.environ.get('MIX_AF_ALPHA_END', '<unset>')} tag=_msg{os.environ.get('FMPCC_RUN_MSG','')}", flush=True)
sys.argv = argv
runpy.run_path(script, run_name='__main__')
