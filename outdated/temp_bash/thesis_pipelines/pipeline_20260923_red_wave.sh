#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 2026-09-23 — the RED wave of PENDING_20260922, as ONE self-contained driver.
#
# ONE FILE TO COPY. Like pipeline_20260922_all_lacking_runs.sh, this writes every wrapper and
# every sbatch file it needs into Slurm_Codes/temp_bash/_rw23_* at run time. Nothing is looked
# up by name, nothing is searched for, no second script has to be copied across. Rename this
# file to whatever you like; it does not refer to itself or to any sibling.
#
#   bash Slurm_Codes/temp_bash/pipeline_20260923_red_wave.sh            # PLAN — submits nothing
#   bash Slurm_Codes/temp_bash/pipeline_20260923_red_wave.sh submit     # SUBMIT the chain
#   ANCHOR=26112 bash ... submit        # chain the first link on afterok:26112 (the default)
#   ANCHOR=none  bash ... submit        # no anchor: start the chain immediately
#   WAVE="R2fix" bash ... submit        # just one part
#
# THE CHAIN, each link waiting for the one before it (author's instruction, 23-09):
#
#   26112  B2 · R26 diffusion K2 five-seed eval            [already queued, afterok:26055]
#     └─►  R2fix  aligning diffusion K20 @ eta 0.2   ~4.5 h   tag _msgR2fix
#            └─►  R37a  MeanFM K2   eta 0.5, per-step          ~0.5 h   tag _msgR37
#                   └─►  R37b  MeanFM K100 eta 0.1, per-step + endpoint  ~5.6 h   tag _msgR37
#
# Every link is submitted with Slurm_Codes/submit_after.sh, the repo's own dependent wrapper,
# which passes an explicit `--dependency=afterok:<id>`. The SBATCH_DEPENDENCY environment
# variable is NEVER used: that is what silently failed on job 26056, which then started while
# its training job 26055 was still running and evaluated a half-trained checkpoint.
#
# ── R2fix · why the V_A run is being repeated ────────────────────────────────
# Job 26051 had the right model, budget, geometry, rules and context count, but its driver
# passed no threshold, so the eval took `diffusion_timestep_threshold: 0.5` from the shared
# yaml and wrote  .../H8_K20_T0.5_..._msglr22/6 . Table 6.8 is the operating point only,
# K = 20 and eta = 0.2 (PENDING_20260922 §23), and its three flow rows are keyed _T0.2_.
# Author, 23-09: "so R2 is wrong! it is dead. so we need resubmit it!"
# T is a plan-path key and the tag is a second separation, so 26051 is NOT overwritten:
#       26051   H8_K20_T0.5_..._msglr22/6     kept, a valid eta 0.5 cell
#       R2fix   H8_K20_T0.2_..._msgR2fix/6    the Table 6.8 row
# K is a TRAINING key for this arm, so it is never patched and --flow-steps is never passed.
# Endpoint projection is undefined for the diffusion sampler; Table 6.8 prints a dash there.
# --epoch is not passed, so the checkpoint selection is the config default, identical to
# 26051: eta is then the ONLY difference between the two runs.
#
# ── R37 · the tightened threshold ladder of Table 6.6 ────────────────────────
# v3.67 withdrew every untightened cell, so Table 6.6 is blank. MeanFM, random rule, seed 6,
# ten contexts, on combined_5-tightened. Two of the five (K, eta) pairs already exist tightened
# in Table 6.7 (K10 eta0.4, K20 eta0.2). v3.68d struck the K2 endpoint pair: a two-step budget
# has no guiding step, so the table prints a dash there. That leaves a, b and c.
#
# 🔴 c (K=100, eta=0.5) IS NOT QUEUED — it cannot finish inside the 24 h cap.
#    From this ledger's own §14 measurement: 50 guiding steps, 15,218 ms PER CONTROL STEP.
#    An alignment cell is 400 steps x 10 contexts -> 15.218 x 400 x 10 = 60,872 s = 16.9 h for
#    ONE variant. The geo loop ALWAYS runs the plain geometry beside the tightened twin
#    (eval_mix_visual_aligning.py appends plain first, `-tightened` second; there is no
#    tightened-only switch), so one variant is 2 items = ~33.8 h. Over the cap before the
#    endpoint arm is counted. At eta=0.1 the same cell measured 1,195 ms/step -> 1.3 h/item.
#    Three ways out, all the author's call:
#      1. drop it — §14 already carries the eta0.5-vs-eta0.1 cost evidence at K=100 (12.7x the
#         cost for 6 mm of final distance), which is the argument §6.2.2 actually makes;
#      2. authorise skipping the plain twin (a change to the geo loop) — each variant then
#         fits one 24 h job at ~17 h;
#      3. fewer contexts for that pair only — breaks the ten-context protocol.
#    `WAVE="... R37c" ALLOW_OVERCAP=1` will queue it anyway. It will hit the wall.
#
# NOT HERE: R33 corridor v3, R39 pillars v2, R40 s-curve — they live in the 23-09 file and its
# own runbook. The yellow items R16, R35, R36 are queued in the runbook for the next parts.
#
# OWNERSHIP: submits and validates only. Never downloads, copies or deletes results.
# temp_bash/ is gitignored. The generated _rw23_* files are read AT JOB START — keep them
# until every job in the chain has ended.
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
P="_rw23"
WAVE="${WAVE:-R2fix R37a R37b}"
ANCHOR="${ANCHOR:-26112}"           # 'none' = start immediately
ALLOW_OVERCAP="${ALLOW_OVERCAP:-0}"
SERIAL="${SERIAL:-1}"               # 1 = every link waits for the previous one

SEED="${SEED:-6}"                   # alignment is seed 6 by policy (2026-09-16)
NCTX="${NCTX:-10}"                  # the thesis protocol; the shared yaml says 3
GEOS="${GEOS:-combined_5}"          # its -tightened twin is generated by the geo loop
RECORD="${RECORD:-none}"
R2FIX_TAG="${R2FIX_TAG:-R2fix}"
R2FIX_ETA="${R2FIX_ETA:-0.2}"
R2FIX_VARIANTS="${R2FIX_VARIANTS:-diffuser,dpcc-r,dpcc-c,dpcc-t}"
R2FIX_HOURS="${R2FIX_HOURS:-12}"
R37_TAG="${R37_TAG:-R37}"
R37_ENGINE="${R37_ENGINE:-mf}"
R37_PERSTEP="${R37_PERSTEP:-dpcc-r}"
R37_ENDPOINT="${R37_ENDPOINT:-hardflow_new-r}"   # request name; lands as hardflow_sls-r

say() { printf '%s\n' "$*"; }
hr()  { say "────────────────────────────────────────────────────────────────────────────"; }
want() { case " $WAVE " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ── pre-flight ───────────────────────────────────────────────────────────────
fail=0
for f in Slurm_Codes/submit.sh Slurm_Codes/submit_after.sh config/aligning-d3il-visual.py \
         config/visual_aligning_eval.yaml mix_visual_aligning_test/eval_mix_visual_aligning.py ; do
    [ -f "$f" ] || { say "[FAIL] missing $f"; fail=1; }
done
grep -q "custom_msg = _sanitize_msg(os.environ.get('FMPCC_RUN_MSG'" config/aligning-d3il-visual.py \
    || { say "[FAIL] no FMPCC_RUN_MSG hook in config/aligning-d3il-visual.py — the tags would be dropped"; fail=1; }
grep -q -- "--proj-threshold" mix_visual_aligning_test/eval_mix_visual_aligning.py \
    || { say "[FAIL] the eval has no --proj-threshold flag — eta cannot be set per job"; fail=1; }
grep -q -- "--flow-steps" mix_visual_aligning_test/eval_mix_visual_aligning.py \
    || { say "[FAIL] the eval has no --flow-steps flag — K cannot be set for the R37 jobs"; fail=1; }
grep -q "HFFM_VARIANTS" mix_visual_aligning_test/eval_mix_visual_aligning.py \
    || { say "[FAIL] the eval has no HFFM_VARIANTS hook — R37b's endpoint arm cannot be enabled"; fail=1; }
case "$R37_ENDPOINT" in hardflow*) ;; *) say "[FAIL] R37_ENDPOINT must start with 'hardflow' or the eval runs it as DPCC"; fail=1 ;; esac
K_BLK="$(grep -A 20 "^base\['mix_visual_aligning_diffusion'\]" config/aligning-d3il-visual.py \
         | grep -oP "'n_diffusion_steps':\s*\K[0-9]+" | head -1 || true)"
[ "$K_BLK" = "20" ] || { say "[FAIL] mix_visual_aligning_diffusion n_diffusion_steps = ${K_BLK:-<none>}, expected 20"; fail=1; }
[ "$fail" -eq 0 ] || { say "ABORT — fix the pre-flight before submitting."; exit 1; }
say "[ ok ] pre-flight passed"
YAML_T="$(grep -E '^diffusion_timestep_threshold:' config/visual_aligning_eval.yaml | awk '{print $2}')"
YAML_N="$(grep -E '^n_contexts:' config/visual_aligning_eval.yaml | awk '{print $2}')"
say "[ eta ] shared yaml says $YAML_T  ->  R2fix passes --proj-threshold $R2FIX_ETA  (26051 took the yaml value: the defect)"
say "[ ctx ] shared yaml says n_contexts $YAML_N  ->  every job injects $NCTX in memory; the yaml is never edited"
say "[ git ] $(git rev-parse --short HEAD 2>/dev/null || echo '-')  $(git status --short 2>/dev/null | wc -l | tr -d ' ') dirty path(s)"
say "[ disk ] $(df -h "$REPO" | awk 'NR==2 {print $4" free on "$6}')"

# ── one shared wrapper for all three jobs ────────────────────────────────────
# The shared yaml is read by the Gen6V4 and Gen7 evals too, and by anything already queued, so
# it is patched IN MEMORY rather than edited on disk.
cat > "$HERE/${P}_eval.py" <<'PY'
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
PY

# ── job generator ────────────────────────────────────────────────────────────
# gen NAME HOURS ENGINE K ETA VARIANTS TAG HF     (K empty -> plan block; HF empty -> no endpoint)
gen() {
    local name="$1" hours="$2" engine="$3" k="$4" eta="$5" variants="$6" tag="$7" hf="$8"
    local f="$HERE/${P}_${name}.sh"
    {
    cat <<SB
#!/bin/bash
#SBATCH --job-name=rw23_${name}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --gres=gpu:1
#SBATCH --time=${hours}:00:00
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
export RW_ENGINE=${engine}
export RW_SEED=${SEED}
export RW_NCTX=${NCTX}
export RW_GEOS=${GEOS}
export RW_VARIANTS=${variants}
export RW_ETA=${eta}
export RW_K=${k}
export RW_RECORD=${RECORD}
export FMPCC_RUN_MSG=${tag}
SB
    if [ -n "$hf" ]; then printf 'export HFFM_VARIANTS=%q\n' "$hf"
    else                  printf 'unset HFFM_VARIANTS || true    # no endpoint arm in this job\n'; fi
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
# K and eta are CLI flags in the wrapper. Kill the env fallbacks so this job's identity is
# provable from this file alone, whatever was exported in the submitting shell.
unset MIX_PROJ_T MIX_EPOCH MIX_BONE MIX_FILM_MODE
cd "$REPO"
echo "[ rw23 ] disk free on logs:"; df -h logs 2>/dev/null | tail -1 || true
python "Slurm_Codes/temp_bash/_rw23_eval.py"
echo "[ rw23 ] result dirs written by this run:"
find logs/aligning-d3il-visual -maxdepth 6 -type d -name "*_msg${FMPCC_RUN_MSG}*" 2>/dev/null | sort || true
echo "Evaluation completed successfully."
SB
    } > "$f"
    chmod +x "$f"
    echo "$f"
}

F_R2FIX="$(gen R2fix "$R2FIX_HOURS" diffusion ''  "$R2FIX_ETA" "$R2FIX_VARIANTS" "$R2FIX_TAG" '')"
F_R37A="$(gen  R37a  6              "$R37_ENGINE" 2   0.5 "$R37_PERSTEP" "$R37_TAG" '')"
F_R37B="$(gen  R37b  16             "$R37_ENGINE" 100 0.1 "$R37_PERSTEP" "$R37_TAG" "$R37_ENDPOINT")"
F_R37C="$(gen  R37c  24             "$R37_ENGINE" 100 0.5 "$R37_PERSTEP" "$R37_TAG" "$R37_ENDPOINT")"

if want R37c && [ "$ALLOW_OVERCAP" != "1" ]; then
    say "[SKIP] R37c is in WAVE but ALLOW_OVERCAP is not 1 — refusing to queue a job that cannot finish (~33.8 h vs a 24 h cap)."
    WAVE="${WAVE//R37c/}"
fi

hr
say "RED WAVE · 23-09      seed $SEED · $NCTX contexts · geometry $GEOS (+ its -tightened twin)"
hr
say "  R2fix  diffusion  K=20 (plan block)  eta=$R2FIX_ETA  $R2FIX_VARIANTS"
say "         ~4.5 h [${R2FIX_HOURS}h limit]  tag _msg$R2FIX_TAG   <- 26051 ran eta $YAML_T; that is the whole point"
say "  R37a   $R37_ENGINE  K=2    eta=0.5  $R37_PERSTEP                     ~0.5 h [6h]   tag _msg$R37_TAG"
say "  R37b   $R37_ENGINE  K=100  eta=0.1  $R37_PERSTEP + $R37_ENDPOINT   ~5.6 h [16h]  tag _msg$R37_TAG"
say "  R37c   $R37_ENGINE  K=100  eta=0.5  🔴 ~33.8 h per variant — over the 24 h cap, see the header"
hr
say "  submitting : $WAVE"
say "  anchor     : $ANCHOR $([ "$ANCHOR" = "none" ] && echo '(chain starts immediately)' || echo '(first link waits for it)')"
say "  chaining   : $([ "$SERIAL" = "1" ] && echo 'serial — each link afterok the previous, via submit_after.sh' || echo 'parallel')"
say "  job files  : $F_R2FIX"
say "               $F_R37A"
say "               $F_R37B"
hr

if [ "$MODE" != "submit" ]; then
    say "PLAN ONLY — nothing submitted. Run again with:"
    say "  ANCHOR=$ANCHOR bash $0 submit"
    exit 0
fi

if [ "$ANCHOR" != "none" ]; then
    if ! scontrol show job "$ANCHOR" >/dev/null 2>&1; then
        say "[FAIL] Slurm does not know job $ANCHOR any more (finished and purged, or wrong id)."
        say "       Start the chain immediately instead:  ANCHOR=none bash $0 submit"
        exit 1
    fi
    say "[ anchor ] $ANCHOR state: $(squeue -j "$ANCHOR" -h -o '%T' 2>/dev/null || echo '<left the queue>')"
fi

DEP=""; [ "$ANCHOR" != "none" ] && DEP="$ANCHOR"
IDS=()
submit_one() {   # $1 = label, $2 = job file
    local out
    if [ -n "$DEP" ]; then
        say "### $1  ⛓ afterok:$DEP"
        out="$(./Slurm_Codes/submit_after.sh "$DEP" "$2")"
    else
        say "### $1  (no dependency)"
        out="$(./Slurm_Codes/submit.sh "$2")"
    fi
    say "$out"
    local id; id="$(printf '%s\n' "$out" | grep -oP 'Job ID:\s*\K[0-9]+' | tail -1)"
    [ -n "$id" ] || { say "❌ no job id returned for $1 — stopping, later links NOT submitted"; exit 1; }
    IDS+=("$id:$1")
    [ "$SERIAL" = "1" ] && DEP="$id"
}
want R2fix && submit_one R2fix "$F_R2FIX"
want R37a  && submit_one R37a  "$F_R37A"
want R37b  && submit_one R37b  "$F_R37B"
want R37c  && [ "$ALLOW_OVERCAP" = "1" ] && submit_one R37c "$F_R37C"

hr
say "SUBMITTED:"
for j in "${IDS[@]}"; do say "  $j"; done
say ""
say "Verify EVERY link really carries its dependency — this is the check that job 26056 needed:"
say "  squeue -u \$USER -o \"%.8i %.26j %.10T %.22r %.26E\""
say "Each queued link must show reason Dependency and an afterok in the last column."
say "If a link's dependency column is EMPTY, cancel that link and say so."
say ""
say "In each log, the first 30 lines must show:"
say "  [ rw23 ] yaml diffusion_timestep_threshold $YAML_T -> <this job's eta>"
say "  [ rw23 ] identity: ... K=... eta=... tag=_msg<tag>"
say "  [ utils/setup ] Made savepath: ...H8_K<K>_..._T<eta>_..._msg<tag>/$SEED"
say ""
say "Record the ids in §7 of logs_in_develop/Writing/Working_Space/data_status/SLURM_RUNBOOK_20260922_all_lacking_runs.md"
say "No download action was performed. Keep $HERE/${P}_* until every job has ended."
