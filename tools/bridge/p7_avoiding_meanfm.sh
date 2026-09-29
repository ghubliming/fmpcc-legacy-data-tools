#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --gres=gpu:1
#SBATCH --time=01:00:00
#SBATCH --partition=gpu-1-student
# P7 injection test (not part of the release): the old MeanFM weights of one avoiding cell are converted, the
# cell is re-run with Released/, and every old result file is compared with the new one. Ends with one verdict.
# From the old repo root:  Slurm_Codes/submit.sh logs_in_develop/Rebuild_Repo_Agent/bridge/p7_avoiding_meanfm.sh [cell] [seed]
#   or on a GPU node:      bash logs_in_develop/Rebuild_Repo_Agent/bridge/p7_avoiding_meanfm.sh [cell] [seed]
REPO="${SLURM_SUBMIT_DIR:-$(pwd)}"
cd "$REPO"
TRAIN=flow_matching_v3_meanflow/H8_Dflow_matcher_v3_meanflow.models.MeanFlowODE_aw10_objmeanflow_bbunet_tslogit_normal_dp0.5
CELL="${1:-H8_K2_Meuler_T0.5_A1_B4_Dflow_matcher_v3_meanflow.models.MeanFlowODE_msghfmink_A1_mfunet_s6}"
SEED="${2:-7}"
OLD_RUN="logs/avoiding-d3il/$TRAIN/$SEED"
OLD_RES="logs/avoiding-d3il/plans/$TRAIN/$CELL/$SEED/results"
DATA="d3il/environments/dataset/data/avoiding/data"
OUT="logs/bridge_p7/$(date +%Y%m%d_%H%M%S)/avoiding/meanfm"
B=logs_in_develop/Rebuild_Repo_Agent/bridge

CONDA_ENV="${CONDA_ENV:-FMPCC}"
source Released/slurm/common.sh "$@"
export PYTHONPATH="$REPO/Released${PYTHONPATH:+:$PYTHONPATH}"

for p in "$OLD_RUN/state_best.pt" "$OLD_RES" "$DATA" Released/scripts/evaluate.py; do
    [ -e "$p" ] || { echo "[ p7 ] missing: $p"; exit 1; }
done
echo "[ p7 ] cell $CELL, seed $SEED -> $OUT"
[ -f "$OLD_RES/../run_provenance.json" ] && { echo "--- old run_provenance.json"; cat "$OLD_RES/../run_provenance.json"; echo; echo "---"; }
mkdir -p "$OUT"

python - "$OLD_RES" "$SEED" "$OUT" <<'PY'
import glob, json, os, re, sys
import numpy as np
res, seed, out = sys.argv[1], sys.argv[2], sys.argv[3]
cell = os.path.basename(os.path.dirname(os.path.dirname(res)))
tok = lambda p, d: (re.search(p, cell) or [None, d])[1]
steps, a, b = tok(r'_K(\d+)_', None), float(tok(r'_A([\d.]+)_', 0.5)), int(tok(r'_B(\d+)_', 4))
prov = os.path.join(os.path.dirname(res), 'run_provenance.json')
prov = json.load(open(prov))['config']['resolved'] if os.path.exists(prov) else {}
arms = {'ps': (float(prov.get('dpcc_threshold', a)), int(prov.get('batch_size_dpcc_arms', b))),
        'ep': (float(prov.get('hf_act_threshold', a)), int(prov.get('hf_batch_size', b)))}
rules = {'r': 'random', 'c': 'cumulative_cost', 't': 'temporal_consistency'}
known = ('top_right_hard', 'top_left_hard', 'both_hard')
order = ['unguided'] + [f'{p}:{r}' for p in ('per_step', 'endpoint') for r in rules.values()]
name = re.compile(r'(diffuser|dpcc-([rct])|hardflow_sls-([rct]))(-tightened)?')
geos, episodes, pairs = [], [], []
variants, tight = {'ps': set(), 'ep': set()}, {'ps': set(), 'ep': set()}
for d in sorted(glob.glob(os.path.join(res, 'halfspace_*'))):
    geo = os.path.basename(d)[len('halfspace_'):].replace('-', '_')
    for f in sorted(glob.glob(os.path.join(d, '*.npz'))):
        stem = os.path.basename(f)[:-4]
        m = name.fullmatch(stem)
        if geo not in known or not m:
            print(f'[ p7 ] no release counterpart, not compared: {geo}/{stem}')
            continue
        if m.group(1) == 'diffuser':
            arm, v, label = 'ps', 'unguided', 'unguided'
        else:
            arm, proj, r = ('ps', 'per_step', m.group(2)) if m.group(2) else ('ep', 'endpoint', m.group(3))
            v, label = f'{proj}:{rules[r]}', f'{proj}_{rules[r]}' + ('_tightened' if m.group(4) else '')
            tight[arm].add(bool(m.group(4)))
        variants[arm].add(v)
        episodes.append(len(np.load(f, allow_pickle=True)['obs_all']))
        geos += [geo] if geo not in geos else []
        pairs.append(f'{f}\t{arm}\t{geo}/seed_{seed}/{label}')
geos = [g for g in known if g in geos]
if not pairs:
    sys.exit('[ p7 ] no comparable old result file')
for arm, (eta, cand) in arms.items():
    if not variants[arm]:
        continue
    sets = [f'seeds=[{seed}]', f'steps={steps}', f'activation_threshold={eta}', f'candidates={cand}',
            f'episodes={max(episodes)}', 'geometries=[' + ','.join(geos) + ']',
            'variants=[' + ','.join(f"'{v}'" for v in order if v in variants[arm]) + ']',
            'tightened=[' + ','.join(str(t).lower() for t in sorted(tight[arm] or {False})) + ']']
    open(os.path.join(out, f'sets_{arm}.txt'), 'w').write('\n'.join(sets) + '\n')
    print(f'[ p7 ] release settings ({arm}): ' + ' '.join(sets))
open(os.path.join(out, 'pairs.tsv'), 'w').write('\n'.join(pairs) + '\n')
print(f'[ p7 ] {len(pairs)} old result files to compare')
PY

python $B/convert.py --env avoiding --model meanfm --old "$OLD_RUN" --which best --data "$DATA" --out "$OUT" --seed "$SEED"
for arm in ps ep; do
    [ -f "$OUT/sets_$arm.txt" ] || continue
    mapfile -t SETS < "$OUT/sets_$arm.txt"
    python Released/scripts/evaluate.py Released/configs/eval/avoiding.yaml --run "$OUT" --tag "p7$arm" --set "${SETS[@]}"
done

n=0; agree=0; drift=0; BAD=()
while IFS=$'\t' read -r old arm rel; do
    n=$((n + 1))
    new="$(ls -d "$OUT"/eval/*_p7$arm 2>/dev/null || true)/$rel.npz"
    echo "=== $rel  <-  $old"
    if [ ! -f "$new" ]; then
        echo "!! the release wrote no $rel.npz"; BAD+=("$rel"); continue
    fi
    res="$(python $B/compare.py --env avoiding --old "$old" --new "$new" 2>&1)" || true
    echo "$res"
    if [ "$(tail -n 1 <<< "$res")" = "AGREE" ]; then
        agree=$((agree + 1))
    elif [ "$(tail -n 1 <<< "$res")" = "DIFFER" ] && ! grep '^!!' <<< "$res" | grep -qv 'obs_all\|act_all'; then
        drift=$((drift + 1))
    else
        BAD+=("$rel")
    fi
done < "$OUT/pairs.tsv"

echo "========================================"
echo "[ p7 ] $n compared: $agree agree, $drift decisions agree but paths drift beyond 1e-5, ${#BAD[@]} differ"
for b in "${BAD[@]}"; do echo "[ p7 ]   differs: $b"; done
if [ "${#BAD[@]}" -gt 0 ]; then
    echo "P7 VERDICT: DIFFER"
elif [ "$drift" -gt 0 ]; then
    echo "P7 VERDICT: AGREE ON DECISIONS, PATH DRIFT (re-run on the old job's GPU type to tell hardware drift from code)"
else
    echo "P7 VERDICT: AGREE"
fi
