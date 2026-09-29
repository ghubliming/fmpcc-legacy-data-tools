#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=48G
#SBATCH --gres=gpu:1
#SBATCH --time=02:00:00
#SBATCH --partition=gpu-1-student
# Release smoke test (not part of the release): every training path runs 4 steps, every evaluation path 3 control
# steps, each process under a line tracer. The log ends with ok/FAIL per process, the lines of the release that
# never ran, a check that the repository is unchanged, and SMOKE VERDICT. Everything runs on a scratch copy of
# Released/ under $TMPDIR (or /tmp) that is deleted at the end; the D3IL data are only read through symlinks.
# From the repository root:  Slurm_Codes/submit.sh logs_in_develop/Rebuild_Repo_Agent/smoke/smoke_release.sh
#   env: MJX_ENV=<conda env with requirements-mjx.txt> adds the MuJoCo MPC controller path; KEEP=1 keeps the scratch
#        copy; AVOID_DATA / ALIGN_DATA override the D3IL data folders; CONDA_ENV (default FMPCC).
REPO="${SLURM_SUBMIT_DIR:-$(pwd)}"
cd "$REPO" || exit 1
[ -f Released/scripts/train.py ] || { echo "[ smoke ] run from the repository root"; exit 1; }
HERE="$REPO/logs_in_develop/Rebuild_Repo_Agent/smoke"
AVOID_DATA="${AVOID_DATA:-$REPO/d3il/environments/dataset/data/avoiding/data}"
ALIGN_DATA="${ALIGN_DATA:-$REPO/d3il/environments/dataset/data/aligning/all_data}"
SCRATCH="${TMPDIR:-/tmp}/fmpcc_smoke_${SLURM_JOB_ID:-$$}"
REL="$SCRATCH/rel"; COV="$SCRATCH/cov"; TOOLS="$SCRATCH/tools"

CONDA_ENV="${CONDA_ENV:-FMPCC}"
source Released/slurm/common.sh "$@"
set +e

[ -e "$SCRATCH" ] && { echo "[ smoke ] $SCRATCH exists already"; exit 1; }
mkdir -p "$SCRATCH" "$COV" "$TOOLS" || exit 1
cleanup() {
    cd /
    if [ "${KEEP:-0}" = 1 ]; then
        echo "[ smoke ] scratch kept: $SCRATCH"
    else
        case "$SCRATCH" in */fmpcc_smoke_*) rm -rf -- "$SCRATCH" && echo "[ smoke ] scratch removed: $SCRATCH" ;; esac
    fi
    echo "JOB END: $(date)"
}
trap cleanup EXIT
free_gb=$(df -Pk "$SCRATCH" | awk 'NR == 2 {print int($4 / 1048576)}')
[ "${free_gb:-0}" -ge 20 ] || { echo "[ smoke ] only ${free_gb} GB free under $SCRATCH (20 needed)"; exit 1; }
git -C "$REPO" status --porcelain --untracked-files=all | grep -v ' Slurm_Codes/logs/' | sort > "$SCRATCH/repo_before.txt"

cp -a Released "$REL" && cp "$HERE/trace_lines.py" "$TOOLS/" || exit 1
find "$REL" -name __pycache__ -type d -prune -exec rm -rf {} +
rm -rf "$REL/logs" "$REL/datasets"
mkdir -p "$REL/datasets/d3il/avoiding" "$REL/datasets/d3il/aligning"
[ -d "$AVOID_DATA" ] && ln -s "$AVOID_DATA" "$REL/datasets/d3il/avoiding/data"
[ -d "$ALIGN_DATA" ] && ln -s "$ALIGN_DATA" "$REL/datasets/d3il/aligning/all_data"
cd "$REL" || exit 1
export PYTHONPATH="$REL" PYTHONDONTWRITEBYTECODE=1 WANDB_MODE=disabled MPLCONFIGDIR="$SCRATCH/mpl"
python - "$REL" <<'PY' || { echo "[ smoke ] fmpcc does not resolve to the scratch copy"; exit 1; }
import os, sys
import fmpcc
where = os.path.realpath(fmpcc.__file__)
print(f'[ smoke ] fmpcc from {where}')
sys.exit(0 if where.startswith(os.path.realpath(sys.argv[1]) + os.sep) else 1)
PY
python - fmpcc/envs/d3il/data/aligning/train_files.pkl <<'PY'
import pickle, sys
import numpy as np
names = list(np.load(sys.argv[1], allow_pickle=True))[:3]
with open(sys.argv[1], 'wb') as f:
    pickle.dump(names, f)
print(f'[ smoke ] aligning training split cut to {len(names)} episodes (scratch copy only)')
PY

RESULTS=(); FAILED=()
step() {
    local name="$1"; shift
    local t0=$SECONDS
    echo "=== [ $name ] $*"
    python "$TOOLS/trace_lines.py" run --root "$REL" --out "$COV/$name.json" -- "$@"
    local rc=$?
    RESULTS+=("$(printf '%-40s %-4s %5ss' "$name" "$([ $rc -eq 0 ] && echo ok || echo FAIL)" $((SECONDS - t0)))")
    [ $rc -eq 0 ] || FAILED+=("$name")
    return $rc
}
skip() { RESULTS+=("$(printf '%-40s %-4s %s' "$1" skip "$2")"); echo "[ smoke ] skip $1: $2"; }
run_dir() {
    case "$2" in
        diffusion) echo "logs/$1/diffusion_K20" ;;
        ci_meanfm) echo "logs/$1/ci_meanfm_ae0.2" ;;
        *) echo "logs/$1/$2" ;;
    esac
}
MODELS="diffusion fm meanfm ci_meanfm"
TRAIN=(training.steps=4 training.checkpoints=2 training.log_every=1 training.test_batches=1 training.workers=0
       training.lr_warmup=2 training.ema_start=1 training.ema_every=1)
EVAL=("seeds=[6]" steps=2 activation_threshold=1.0)
HAVE_ALIGN=0; [ -e datasets/d3il/aligning/all_data ] && HAVE_ALIGN=1

# data: quadrotor demonstrations (generator); training: every environment x model, resume, CI-MeanFM at alpha_end 0
for scene in corridor s_curve; do
    step collect_$scene scripts/collect_uav_demonstrations.py --scene $scene --trials 3
done
if [ -e datasets/d3il/avoiding/data ]; then
    for m in $MODELS; do
        step train_avoiding_$m scripts/train.py configs/train/avoiding.yaml --model $m --seed 6 --set "${TRAIN[@]}"
    done
    step train_avoiding_fm_resume scripts/train.py configs/train/avoiding.yaml --model fm --seed 6 --resume \
        --set "${TRAIN[@]}" training.steps=6
    step train_avoiding_ci_meanfm_ae0 scripts/train.py configs/train/avoiding.yaml --model ci_meanfm --seed 6 \
        --set "${TRAIN[@]}" models.ci_meanfm.alpha_end=0.0
else
    skip train_avoiding "no data at $AVOID_DATA"
fi
if [ $HAVE_ALIGN = 1 ]; then
    for m in $MODELS; do
        step train_aligning_$m scripts/train.py configs/train/aligning.yaml --model $m --seed 6 --set "${TRAIN[@]}"
    done
else
    skip train_aligning "no data at $ALIGN_DATA"
fi
for scene in corridor s_curve; do
    for m in $MODELS; do
        step train_uav_${scene}_$m scripts/train.py configs/train/uav.yaml --model $m --seed 6 --set "${TRAIN[@]}" \
            dataset.scene=$scene
    done
done

# evaluation: every configuration x model, all variants and tightenings, 1 seed, 1 episode / context / flight
for m in $MODELS; do
    tag=(); [ $m = fm ] && tag=(--tag smoke)
    extra=(); [ $m = ci_meanfm ] && extra=(checkpoint=4)
    step eval_avoiding_$m scripts/evaluate.py configs/eval/avoiding.yaml --run "$(run_dir avoiding $m)" "${tag[@]}" \
        --set "${EVAL[@]}" episodes=1 episode_limit=3 "geometries=[both_hard]" "${extra[@]}"
done
step eval_uav_pillars scripts/evaluate.py configs/eval/uav_pillars.yaml --run "$(run_dir avoiding meanfm)" \
    --set "${EVAL[@]}" episodes=1 episode_limit=3 "geometries=[both_hard]" \
    "variants=['unguided','per_step:temporal_consistency','endpoint:temporal_consistency']"
if [ $HAVE_ALIGN = 1 ]; then
    for m in $MODELS; do
        split=(); [ $m = fm ] && split=(context_split=test)
        step eval_aligning_$m scripts/evaluate.py configs/eval/aligning.yaml --run "$(run_dir aligning $m)" \
            --set "${EVAL[@]}" contexts=1 episode_limit=3 "${split[@]}"
    done
else
    skip eval_aligning "no data at $ALIGN_DATA"
fi
for m in $MODELS; do
    for c in uav_corridor_tilt uav_corridor_hump; do
        step eval_${c}_$m scripts/evaluate.py configs/eval/$c.yaml --run "$(run_dir uav_corridor $m)" \
            --set "${EVAL[@]}" flights=1 episode_limit=3
    done
    step eval_uav_scurve_$m scripts/evaluate.py configs/eval/uav_scurve.yaml --run "$(run_dir uav_s_curve $m)" \
        --set "${EVAL[@]}" flights=1 episode_limit=3
done
if [ -n "$MJX_ENV" ]; then
    if conda activate "$MJX_ENV"; then
        step eval_uav_scurve_mjpc scripts/evaluate.py configs/eval/uav_scurve.yaml --run "$(run_dir uav_s_curve fm)" \
            --set "${EVAL[@]}" flights=1 episode_limit=2 controller=predictive_sampling "variants=['unguided','per_step:random']"
        conda activate "$CONDA_ENV"
    else
        skip eval_uav_scurve_mjpc "conda env $MJX_ENV not found"
    fi
else
    skip eval_uav_scurve_mjpc "MJX_ENV not set (MuJoCo MPC controller path)"
fi

echo "========================================"
for r in "${RESULTS[@]}"; do echo "[ smoke ] $r"; done
echo "----------------------------------------"
python "$TOOLS/trace_lines.py" report --root "$REL" "$COV"/*.json
echo "----------------------------------------"
git -C "$REPO" status --porcelain --untracked-files=all | grep -v ' Slurm_Codes/logs/' | sort > "$SCRATCH/repo_after.txt"
if cmp -s "$SCRATCH/repo_before.txt" "$SCRATCH/repo_after.txt"; then
    echo "[ smoke ] repository unchanged by this job (git status, Slurm logs aside)"
else
    echo "[ smoke ] git status changed during this job:"
    diff "$SCRATCH/repo_before.txt" "$SCRATCH/repo_after.txt"
fi
echo "========================================"
if [ ${#FAILED[@]} -eq 0 ]; then
    echo "SMOKE VERDICT: PASS (${#RESULTS[@]} steps, skips listed above)"
else
    echo "SMOKE VERDICT: FAIL (${#FAILED[@]}: ${FAILED[*]})"
    exit 1
fi
