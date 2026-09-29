#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 2026-09-23 — the MUST-NEED runs still open in PENDING_20260922_all_lacking_runs.md (NOW table),
# excluding the quadrotor scenes (corridor R33, s-curve R44, pillars R39 — other files) and every
# optional item (R43). What is left is exactly two ledger items, six small jobs:
#
#   R16  Table 6.5 (tab:va-models) — three *pending* unprojected rows, D3IL-aligning, seed 6, ten contexts
#          R16a  FM         K=2   (eta 0.5 names the folder; unprojected, eta does not act)
#          R16b  FM         K=10  (eta 0.4, as the MeanFM K=10 row)
#          R16c  CI-MeanFM  K=10  (alpha_end 0.2, latest checkpoint, eta 0.4)
#   R36  Table 6.3 (tab:avoiding-projectors) — three *lacking* matched four-candidate cells,
#        D3IL-avoiding, seed 6, DPCC protocol (3 geometries x 2 episodes), both projectors, tightened
#          R36a  CI-MeanFM  K=3   endpoint activation 1.0 (two guiding steps, as MeanFM K=3 / job 25444)
#          R36b  FM         K=3   endpoint activation 1.0
#          R36c  MeanFM     K=10  endpoint activation 0.5 (four guiding steps, as the CI-MeanFM/FM K=10 rows)
#
#   bash Slurm_Codes/temp_bash/pipeline_20260923_must_need.sh            # PLAN — submits nothing
#   bash Slurm_Codes/temp_bash/pipeline_20260923_must_need.sh submit     # SUBMIT all six
#   WAVE="R16a R16b R16c" bash ... submit                                 # one item only
#   ANCHOR=<jobid> bash ... submit        # first job waits for <jobid> (afterok)
#   SERIAL=0 bash ... submit              # no chain; the QOS still runs two at a time
#
# ONE FILE TO COPY. It writes every wrapper, sbatch file and pruned yaml it needs into
# Slurm_Codes/temp_bash/_mn23_* at run time; nothing is looked up by name, and the driver can be
# renamed freely. Dependencies go through Slurm_Codes/submit_after.sh (explicit --dependency),
# NEVER the SBATCH_DEPENDENCY environment variable (that silently failed on job 26056).
#
# CHECKED AGAINST THE CORPUS BEFORE WRITING (the R37a lesson — a "missing" cell can already exist):
#   R16: no FM K2, FM K10 or CI-MeanFM K10 folder exists on D3IL-aligning (batch_va2_20260923_210100).
#   R36: no CI-MeanFM K3, FM K3, or MeanFM K10 B4 cell exists on D3IL-avoiding (TenpK2D batch);
#        MeanFM K10 exists only as B1 (single candidate), which is what Table 6.3 says.
#   R35 needed no run at all (found in the corpus 23-09) and is not here.
#
# HOW EACH CELL IS MATCHED TO WHAT THE TABLES ALREADY PRINT
#   R16 — Table 6.5 reads combined_5, variant `diffuser`, keyed on the H8_K<n>_ folder prefix. The
#         jobs run `diffuser` only (the geo loop adds the tightened twin itself; it costs minutes).
#         FM rows of the table use the config-default checkpoint (`_Efm`, no epoch token) -> no
#         --epoch. CI-MeanFM rows use alpha_end 0.2 at the latest checkpoint (`…_AFAFend0p2`,
#         `_EPlatest`) -> MIX_AF_ALPHA_END=0.2 and --epoch latest. Ten contexts injected in memory.
#   R36 — Table 6.3's existing cells: MeanFM K3 = job 25444 (`eval_meanflow_hardflow.sh`,
#         HFFM_BATCH=4, FMPCC_MPC_BATCH=4, HFFM_ACT_THRESHOLD=1.0, MF_BACKBONE=unet, MF_HORIZON=8);
#         CI-MeanFM K10 = `A0.5_B4 … _msgafon02_s6`, seed 6; FM K10 = `thres0.5_mpc4_n2`, seed 6.
#         The new cells use the same three stock entrypoints with the same knobs. Seeds, episodes
#         and variants come from a PRUNED COPY of each entrypoint's own yaml, passed as
#         `--config <copy>` — the hook all three evals document ("--config <a pruned projection
#         yaml>"). The shared yamls are never edited. Variants: dpcc-{r,c,t}-tightened against
#         hardflow_new-{r,c,t}-tightened (folders land as hardflow_sls-*), so every rule the
#         existing K=10 rows carry is carried here too.
#
# COST: R16 ~5-15 min per cell (seed 6); R36c ~10-30 min (seed 6); R36a/b run four seeds each since
# v3.77, ~40 min-2 h per cell. About 2-5 h in total even fully serial.
# R16 jobs get 6 h; R36 jobs keep their entrypoints' own 24 h limit.
#
# OWNERSHIP: submits and validates. Never downloads, copies or deletes results. The generated
# _mn23_* files are read AT JOB START — keep them until every job has ended.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

find_repo_root() {
    local d
    for d in "$PWD" "$(cd "$(dirname "$0")" && pwd)"; do
        while [ "$d" != "/" ] && [ -n "$d" ]; do
            if [ -f "$d/Slurm_Codes/submit.sh" ]; then echo "$d"; return 0; fi
            d="$(dirname "$d")"
        done
    done
    return 1
}
REPO="$(find_repo_root)" || { echo "[FAIL] no Slurm_Codes/submit.sh above \$PWD or this script."; exit 1; }
cd "$REPO"; echo "[ ok ] repo root: $REPO"

MODE="${1:-plan}"
case "$MODE" in plan|submit) ;; *) echo "[FAIL] mode must be plan | submit (got '$MODE')"; exit 1 ;; esac

HERE="Slurm_Codes/temp_bash"
P="_mn23"
WAVE="${WAVE:-R16a R16b R16c R36a R36b R36c}"
ANCHOR="${ANCHOR:-none}"
SERIAL="${SERIAL:-1}"
SEED="${SEED:-6}"
# v3.77 (23-09): the two K=3 cells of R36 run on the seeds of the printed MeanFM K=3 row of Table 6.3
# (job 25444: seeds 7-10), so the K=3 block is paired on one seed set. R36c (K=10) stays at $SEED, the
# seed of the printed K=10 rows. Yaml flow form: "7, 8, 9, 10".
SEEDS_K3="${SEEDS_K3:-7, 8, 9, 10}"
NCTX="${NCTX:-10}"
TAG16="${TAG16:-R16}"
TAG36="${TAG36:-R36}"
R16_HOURS="${R16_HOURS:-6}"
RECORD="${RECORD:-none}"

MF_ENTRY="Slurm_Codes/sbatch/MeanFlow/eval_meanflow_hardflow.sh"
AF_ENTRY="Slurm_Codes/sbatch/AlphaFlow/eval_alphaflow_hardflow.sh"
FM_ENTRY="Slurm_Codes/sbatch/hardflow_fmv3/eval_fmv3_hardflow_job.sh"
MF_YAML="config/meanflow_projection_eval.yaml"
AF_YAML="config/alphaflow_projection_eval.yaml"
FM_YAML="config/hardflow_projection_eval.yaml"
R36_VARIANTS=( dpcc-r-tightened dpcc-c-tightened dpcc-t-tightened
               hardflow_new-r-tightened hardflow_new-c-tightened hardflow_new-t-tightened )

say() { printf '%s\n' "$*"; }
hr()  { say "────────────────────────────────────────────────────────────────────────────"; }
want() { case " $WAVE " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ── pre-flight ───────────────────────────────────────────────────────────────
fail=0
for f in Slurm_Codes/submit.sh Slurm_Codes/submit_after.sh "$MF_ENTRY" "$AF_ENTRY" "$FM_ENTRY" \
         "$MF_YAML" "$AF_YAML" "$FM_YAML" config/aligning-d3il-visual.py config/avoiding-d3il.py \
         config/visual_aligning_eval.yaml mix_visual_aligning_test/eval_mix_visual_aligning.py \
         FM_v3_meanflow_test/eval_flow_matching_v3_meanflow.py \
         FM_v3_alphaflow_test/eval_flow_matching_v3_alphaflow.py \
         FM_v3_hardflow_test/eval_FM_v3_hardflow.py ; do
    [ -f "$f" ] || { say "[FAIL] missing $f"; fail=1; }
done
grep -q "'--config' in remaining_argv" FM_v3_meanflow_test/eval_flow_matching_v3_meanflow.py  || { say "[FAIL] MeanFlow eval has no --config hook"; fail=1; }
grep -q "'--config' in remaining_argv" FM_v3_alphaflow_test/eval_flow_matching_v3_alphaflow.py || { say "[FAIL] AlphaFlow eval has no --config hook"; fail=1; }
grep -q "add_argument('--config'" FM_v3_hardflow_test/eval_FM_v3_hardflow.py                    || { say "[FAIL] FM HardFlow eval has no --config flag"; fail=1; }
grep -q "os.environ.get('AF_ALPHA_END'" config/avoiding-d3il.py || { say "[FAIL] config/avoiding-d3il.py does not read AF_ALPHA_END"; fail=1; }
grep -q "'MIX_AF_ALPHA_END'" config/aligning-d3il-visual.py      || { say "[FAIL] config/aligning-d3il-visual.py does not read MIX_AF_ALPHA_END"; fail=1; }
grep -q "custom_msg = _sanitize_msg(os.environ.get('FMPCC_RUN_MSG'" config/aligning-d3il-visual.py || { say "[FAIL] no FMPCC_RUN_MSG hook in the aligning config"; fail=1; }
for y in "$MF_YAML" "$AF_YAML" "$FM_YAML"; do
    grep -q '^projection_variants: \[' "$y" || { say "[FAIL] $y: no 'projection_variants: [' block to prune"; fail=1; }
    grep -q '^seeds:'    "$y" || { say "[FAIL] $y: no seeds: line"; fail=1; }
    grep -q '^n_trials:' "$y" || { say "[FAIL] $y: no n_trials: line"; fail=1; }
done
[ "$fail" -eq 0 ] || { say "ABORT — fix the pre-flight before submitting."; exit 1; }
say "[ ok ] pre-flight passed"
say "[ git ] $(git rev-parse --short HEAD 2>/dev/null || echo '-')"
say "[ disk ] $(df -h "$REPO" | awk 'NR==2 {print $4" free on "$6}')"

# ── R36: pruned yaml copies (shared yamls untouched) ─────────────────────────
# Copy the entrypoint's own yaml; replace the projection_variants block; pin seeds and n_trials.
prune_yaml() {   # $1 = source yaml, $2 = destination, $3 = seed list in yaml flow form (default $SEED)
    local src="$1" dst="$2" seeds="${3:-$SEED}" list v
    list="projection_variants: ["$'\n'
    for v in "${R36_VARIANTS[@]}"; do list+="  '$v',"$'\n'; done
    list+="]"
    awk -v block="$list" '
        /^projection_variants: \[/ { print "# PRUNED by pipeline_20260923_must_need.sh (R36) — original block replaced"; print block; skip=1; next }
        skip && /^\]/ { skip=0; next }
        skip { next }
        { print }
    ' "$src" \
    | sed -E "s/^seeds:.*/seeds: [${seeds}]   # PINNED (R36)/; s/^n_trials:.*/n_trials: 2   # PINNED (R36): DPCC protocol/" > "$dst"
    grep -q "^seeds: \[${seeds}\]" "$dst" && grep -q '^n_trials: 2' "$dst" && grep -q "'hardflow_new-t-tightened'" "$dst" \
        || { say "[FAIL] pruning $src -> $dst did not take"; exit 1; }
    ! grep -q "^  'diffuser'" "$dst" || { say "[FAIL] $dst still carries the old variant list"; exit 1; }
}
Y_MF="$HERE/${P}_R36_meanflow.yaml";  prune_yaml "$MF_YAML" "$Y_MF" "$SEED"       # R36c, K=10
Y_AF="$HERE/${P}_R36_alphaflow.yaml"; prune_yaml "$AF_YAML" "$Y_AF" "$SEEDS_K3"   # R36a, K=3 (v3.77)
Y_FM="$HERE/${P}_R36_hardflow.yaml";  prune_yaml "$FM_YAML" "$Y_FM" "$SEEDS_K3"   # R36b, K=3 (v3.77)

# ── R16: one aligning wrapper (shared yaml patched in memory, as the red wave did) ──
cat > "$HERE/${P}_align_eval.py" <<'PY'
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
PY

gen_align() {   # NAME ENGINE K ETA EPOCH
    local name="$1" engine="$2" k="$3" eta="$4" epoch="$5"
    local f="$HERE/${P}_${name}.sh" uc
    uc="$(echo "$engine" | tr '[:lower:]' '[:upper:]')"
    {
    cat <<SB
#!/bin/bash
#SBATCH --job-name=mn23_${name}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --gres=gpu:1
#SBATCH --time=${R16_HOURS}:00:00
#SBATCH --partition=gpu-1-student
set -e
CURRENT_LOG=\$(scontrol show job \$SLURM_JOB_ID | grep -oP 'StdOut=\\K\\S+')
[ -n "\$CURRENT_LOG" ] && ln -snf "\$CURRENT_LOG" Slurm_Codes/logs/latest.log
echo "================================================================================"
echo "JOB START: \$(date)   ID: \$SLURM_JOB_ID   NODE: \$(hostname)   NAME: \$SLURM_JOB_NAME"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | head -1 || echo "no GPU"
echo "GIT REV:   \$(git rev-parse --short HEAD 2>/dev/null || echo '-')"
echo "================================================================================"
trap 'echo "================================================================================"; echo "JOB END: \$(date)"' EXIT
export MN_ENGINE=${engine}
export MN_SEED=${SEED}
export MN_NCTX=${NCTX}
export MN_K=${k}
export MN_ETA=${eta}
export MN_EPOCH=${epoch}
export MN_RECORD=${RECORD}
export FMPCC_RUN_MSG=${TAG16}
export MIX_BONE_${uc}=unet
export MIX_FILM_MODE_${uc}=v1
SB
    if [ "$engine" = "af" ]; then
        printf 'export MIX_AF_ALPHA_END=0.2    # -> checkpoint …_afschsigmoid_AFAFend0p2, the thesis CI-MeanFM\n'
    else
        printf 'unset MIX_AF_ALPHA_END MIX_AF_ALPHA_SCHED MIX_AF_ALPHA_INIT MIX_AF_ALPHA_CLAMP MIX_AF_ALPHA_GAMMA || true\n'
    fi
    cat <<'SB'
FMPCC_ROOT="$HOME/FMPCC"; REPO="$FMPCC_ROOT/FM-PCC"
source "$HOME/miniconda3/etc/profile.d/conda.sh"; conda activate FMPCC
export FMPCC="$REPO"; export D3IL_ROOT="$FMPCC/d3il"
export D3IL_ENV_ROOT="$D3IL_ROOT/environments/d3il"
export PYTHONPATH="$FMPCC:$D3IL_ROOT:$D3IL_ENV_ROOT:$PYTHONPATH"
export MUJOCO_GL="egl"; export PYOPENGL_PLATFORM="egl"; export MPLBACKEND="agg"
export PYTHONUNBUFFERED=1
export CUDA_DEVICE_ORDER="PCI_BUS_ID"
export MUJOCO_EGL_DEVICE_ID="${CUDA_VISIBLE_DEVICES%%,*}"
echo "[ GPU-CHECK ] CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES  MUJOCO_EGL_DEVICE_ID=$MUJOCO_EGL_DEVICE_ID"
if [ "$MUJOCO_EGL_DEVICE_ID" != "${CUDA_VISIBLE_DEVICES%%,*}" ]; then
    echo "[ GPU-LEAK ] EGL device != CUDA device -- aborting"; exit 1
fi
unset MIX_PROJ_T MIX_EPOCH MIX_BONE MIX_FILM_MODE HFFM_VARIANTS
cd "$REPO"
python "Slurm_Codes/temp_bash/_mn23_align_eval.py"
echo "[ mn23 ] result dirs written by this run:"
find logs/aligning-d3il-visual -maxdepth 6 -type d -name "*_msg${FMPCC_RUN_MSG}*" 2>/dev/null | sort || true
echo "Evaluation completed successfully."
SB
    } > "$f"
    chmod +x "$f"
    echo "$f"
}
F_16A="$(gen_align R16a_fm_K2   fm 2  0.5 '')"
F_16B="$(gen_align R16b_fm_K10  fm 10 0.4 '')"
F_16C="$(gen_align R16c_af_K10  af 10 0.4 latest)"

# ── env for the R36 stock entrypoints (inherited through sbatch --export=ALL) ──
# -u first: kill anything a previous run left in this shell, so each job is provable from here.
R36_UNSET=( -u HFFM_FLOW_STEPS -u HFFM_ACT_THRESHOLDS -u HFFM_SOLVERS -u FMPCC_HF_ALLOW_DEGENERATE
            -u FMPCC_HF_MIN_GENUINE -u MF_FLOW_STEPS -u MF_REPLAN_STEPS -u AF_SEEDS -u AF_NTRIALS
            -u AF_FLOW_STEPS -u AF_ALPHA_CLAMP -u AF_BONE -u AF_ALPHA_END -u AF_EPOCH -u FMPCC_RUN_MSG
            -u FORCE_OVERWRITE )
R36_COMMON=( HFFM_BATCH=4 FMPCC_MPC_BATCH=4 FMPCC_RUN_MSG="$TAG36" )

hr
say "MUST-NEED WAVE · 23-09 (R36 seeds updated v3.77)   R16 seed $SEED · R36a/b seeds [$SEEDS_K3], R36c seed $SEED · tags _msg$TAG16 / _msg$TAG36"
hr
say "  R16a  D3IL-aligning  FM         K=2   eta 0.5  diffuser, combined_5, ${NCTX} ctx   [${R16_HOURS}h]  $F_16A"
say "  R16b  D3IL-aligning  FM         K=10  eta 0.4  diffuser, combined_5, ${NCTX} ctx   [${R16_HOURS}h]  $F_16B"
say "  R16c  D3IL-aligning  CI-MeanFM  K=10  eta 0.4  diffuser, alpha_end 0.2, latest   [${R16_HOURS}h]  $F_16C"
say "  R36a  D3IL-avoiding  CI-MeanFM  K=3   A=1.0  B4/mpc4  unet ae0.2 latest   --config $Y_AF"
say "  R36b  D3IL-avoiding  FM         K=3   A=1.0  B4/mpc4                      --config $Y_FM"
say "  R36c  D3IL-avoiding  MeanFM     K=10  A=0.5  B4/mpc4  unet H8             --config $Y_MF"
say "        R36 variants: ${R36_VARIANTS[*]}"
say "        R36 protocol: 3 geometries x 2 episodes; seeds R36a/b [$SEEDS_K3] (as the printed MeanFM K=3 row), R36c [$SEED] (pinned in the pruned yamls)"
hr
say "  submitting : $WAVE"
say "  anchor     : $ANCHOR   chaining: $([ "$SERIAL" = "1" ] && echo 'serial, each afterok the previous (submit_after.sh)' || echo 'none (QOS runs two at a time)')"
hr

if [ "$MODE" != "submit" ]; then
    say "PLAN ONLY — nothing submitted. Generated files are in $HERE/${P}_* for inspection."
    say "Submit with:  bash $0 submit"
    exit 0
fi

if [ "$ANCHOR" != "none" ] && ! scontrol show job "$ANCHOR" >/dev/null 2>&1; then
    say "[FAIL] Slurm does not know job $ANCHOR. Use ANCHOR=none to start immediately."; exit 1
fi
DEP=""; [ "$ANCHOR" != "none" ] && DEP="$ANCHOR"
IDS=()
submit_one() {   # LABEL [env ...] -- ENTRY [script args ...]
    local label="$1"; shift
    local envs=() out id
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
    if [ -n "$DEP" ]; then
        say "### $label  ⛓ afterok:$DEP"
        out="$(env "${envs[@]}" ./Slurm_Codes/submit_after.sh "$DEP" "$@")"
    else
        say "### $label  (no dependency)"
        out="$(env "${envs[@]}" ./Slurm_Codes/submit.sh "$@")"
    fi
    say "$out"
    id="$(printf '%s\n' "$out" | grep -oP 'Job ID:\s*\K[0-9]+' | tail -1)"
    [ -n "$id" ] || { say "❌ no job id for $label — stopping; later jobs NOT submitted"; exit 1; }
    IDS+=("$id:$label")
    [ "$SERIAL" = "1" ] && DEP="$id"
}

want R16a && submit_one R16a -u SBATCH_DEPENDENCY -- "$F_16A"
want R16b && submit_one R16b -u SBATCH_DEPENDENCY -- "$F_16B"
want R16c && submit_one R16c -u SBATCH_DEPENDENCY -- "$F_16C"
want R36a && submit_one R36a "${R36_UNSET[@]}" "${R36_COMMON[@]}" HFFM_ACT_THRESHOLD=1.0 \
                 AF_BONE=unet AF_ALPHA_END=0.2 AF_EPOCH=latest \
                 -- "$AF_ENTRY" --flow-steps 3 --config "$Y_AF"
want R36b && submit_one R36b "${R36_UNSET[@]}" "${R36_COMMON[@]}" HFFM_ACT_THRESHOLD=1.0 HFFM_FLOW_STEPS=3 \
                 -- "$FM_ENTRY" --config "$Y_FM"
want R36c && submit_one R36c "${R36_UNSET[@]}" "${R36_COMMON[@]}" HFFM_ACT_THRESHOLD=0.5 \
                 MF_FLOW_STEPS=10 MF_BACKBONE=unet MF_HORIZON=8 \
                 -- "$MF_ENTRY" --config "$Y_MF"

hr
say "SUBMITTED:"; for j in "${IDS[@]}"; do say "  $j"; done
say ""
say "Verify every chained job carries its dependency (the 26056 check):"
say "  squeue -u \$USER -o \"%.8i %.26j %.10T %.22r %.26E\""
say "First lines of each log must show:"
say "  R16    [ mn23 ] identity: engine=… K=… eta=… n_contexts=10 … tag=_msg$TAG16   (R16c: af_alpha_end=0.2, epoch=latest)"
say "  R36    [ hardflow ] HFFM_BATCH=4 … FMPCC_MPC_BATCH=4 … HFFM_ACT_THRESHOLD=<1.0|0.5>"
say "         [ eval ] config: $HERE/${P}_R36_<…>.yaml   and a savepath ending _msg$TAG36"
say "         hf_n_genuine = 2 at K=3, 4 at K=10; no [hardflow][BLOCKED] line"
say "         R36a/b evaluate seeds 7 8 9 10 (four seed blocks in the log), R36c seed $SEED only"
say "Record the ids in SLURM_RUNBOOK_20260922_all_lacking_runs.md §7. No download was performed."
say "Keep $HERE/${P}_* until every job has ended."
