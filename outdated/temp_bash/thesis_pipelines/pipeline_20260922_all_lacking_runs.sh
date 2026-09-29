#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 2026-09-22 — the remaining thesis runs, most urgent first.
#   scope    logs_in_develop/Writing/Working_Space/data_status/PENDING_20260922_all_lacking_runs.md
#   runbook  logs_in_develop/Writing/Working_Space/data_status/SLURM_RUNBOOK_20260922_all_lacking_runs.md
#   replaces the never-run 2026-09-20 plan (its R25 / R18 / K20-repair phases are struck by the
#   author, v3.52–v3.55) and groups G/H/I of the 2026-09-18 driver.
#
#   bash Slurm_Codes/temp_bash/pipeline_20260922_all_lacking_runs.sh            # PLAN (default): print, submit NOTHING
#   bash Slurm_Codes/temp_bash/pipeline_20260922_all_lacking_runs.sh submit     # SUBMIT the groups in WAVE
#
#   WAVE="A"            bash ... submit     # just the 🔴 blocker
#   WAVE="A B C D E"    bash ... submit     # default
#   WAVE="F"            bash ... submit     # R16 (one aligning diffusion training + 3 evals)
#   WAVE="G" / "H"      bash ... submit     # opt-in extras
#
# GROUPS — in the order the ledger ranks them (§0 of the PENDING file)
#   A  R2   🔴 D3IL-aligning · diffusion K=20, seed 6, TEN contexts, combined_5 (+ tightened twin),
#           diffuser + dpcc-r/c/t. The tightened cells are the deliverable: they are the last thing
#           blocking the four-model pre/post-projection merge (tab:va-projection-models).
#           n_contexts is injected IN MEMORY (yaml still says 3); results tagged _msg<ALIGN_TAG>.
#   B  R26  🟡 D3IL-avoiding · diffusion K=2, five seeds, DPCC protocol (2 episodes).
#           B1 = FOUR trainings (seeds 7–10, one job each, K patched in memory, like job 25965);
#           B2 = ONE eval over seeds 6–10 from the yaml, tag _msgdpccproto, afterok ALL of B1.
#           The long pole of the wave — submit it early.
#   C  R30  🟢 UAV-corridor · diffusion baseline under plain dpcc-t-tightened, 12 flights, tag u17cv2.
#           Removes the bounds_free/pdes confound in tab:uav-corridor. New cell, nothing overwritten.
#   D  R31u 🟡 UAV-s-curve · UNPROJECTED matched grid: mf K1,3,5 · af K3 · fm K1,3,5 (7 cells,
#           10 flights, s_curve_hg, tag u7hg — the tag the grid already reads for these rows).
#   E  R31p 🟡 UAV-s-curve · PROJECTED post-correction grid: mf K3,5 · af K3 · fm K3,5 —
#           {diffuser, dpcc-t, hardflow_new, -r, -c, -t} × 10 flights, tag u18sc (one child per cell).
#   F  R16  🟡 D3IL-aligning at K=10: fm (T=0.4) · af (T=0.4, ae0.2, latest) · diffusion
#           (F3 = TRAIN at n_diffusion_steps=10, F4 = eval afterok F3). Ten contexts, tag _msg<ALIGN_TAG>.
#   G  R15  🟡 opt-in · UAV-s-curve MuJoCo-MPC controller at TEN flights (mf K10, mjpc), tag u19mjpc.
#           Needs the FMPCC_mjx conda env on the cluster (eval_mix_uav.sh switches on the controller).
#   H  R28  🟡 opt-in · D3IL-avoiding FM at K=5 and K=10, five seeds, 2 episodes, tag _msgdpccproto.
#           NOT OWED (nothing in the draft claims those cells) — cheap, so it is here as an option.
#
# NOT IN THIS DRIVER, and why (author decisions — do not re-derive)
#   · R23 UAV-pillars: 🔴 NO pillars compute (no K=3 rung, no diffusion remainder, no pillars_xxl)
#     until the four results.json named in SLURM_RUNBOOK_20260919_pillars_enlarged.md §3e are read.
#     53/54 projected cells read success=0.00; the leading hypothesis is a goal-radius/geometry
#     mismatch that would force a re-score or re-run anyway. Diffusion pillars projection is
#     CLOSED BY DECISION (2026-09-21): reported unprojected only.
#   · R25 / R18 / the K20 both-hard repair: struck by the author (v3.52, v3.55) — "extreme highly
#     cost"; §6.1 is reported at DPCC's own protocol and the 20-episode campaign is quarantined.
#   · R7 / R14: the K/threshold grid must be locked by the author before a driver is written.
#   · R9: needs an AUTHORISED code change first (remove the 0.5× prior scale, add a path token).
#   · D10c / D11 / D12: logging or rendering code changes, not runs.
#   · R27: diffusion has no velocity field → endpoint projection is a model limit, not a run.
#
# PROTOCOL GUARDS baked in
#   · config/projection_eval.yaml must say n_trials: 2 and seeds [6..10] for B2/H (read at job start).
#   · No tracked config is edited: every override is an in-memory patch inside a throwaway wrapper.
#   · Aligning jobs use --eval-on-train (training split), as every published alignment row does.
#   · UAV jobs: UAV_EVAL_HOURS=24 always; variant lists built as arrays; HardFlow never without a
#     dpcc-* companion; nothing at K<3 asks for HardFlow.
#   · Every generated job keeps the CUDA_DEVICE_ORDER / MUJOCO_EGL_DEVICE_ID isolation block.
#
# OWNERSHIP: this script submits and validates. It never downloads, copies or deletes results.
# Slurm_Codes/temp_bash/ is gitignored — copy this file to the remote by hand. The generated
# _lr22_* files are read AT JOB START: keep them until the whole wave has finished.
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

WAVE="${WAVE:-A B C D E}"
[ "$WAVE" = "all" ] && WAVE="A B C D E F"
want() { case " $WAVE " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

HERE="Slurm_Codes/temp_bash"
P="_lr22"                                  # prefix of every generated throwaway file

# ── knobs ────────────────────────────────────────────────────────────────────
ALIGN_SEED="${ALIGN_SEED:-6}"              # seed policy 2026-09-16: aligning stays at seed 6
ALIGN_NCTX="${ALIGN_NCTX:-10}"             # the thesis protocol; yaml says 3 (untracked cluster edit, see runbook)
ALIGN_TAG="${ALIGN_TAG:-lr22}"             # results dirs end in _msg<tag>; keeps the seed-6 corpus untouched
ALIGN_VARIANTS="${ALIGN_VARIANTS:-diffuser,dpcc-r,dpcc-c,dpcc-t}"   # tightened twin is auto-generated
ALIGN_GEOS="${ALIGN_GEOS:-combined_5}"
ALIGN_HOURS="${ALIGN_HOURS:-12}"
ALIGN_TRAIN_HOURS="${ALIGN_TRAIN_HOURS:-24}"
R16_K="${R16_K:-10}"
R16_T="${R16_T:-0.4}"                      # T·K = 4 solves, the same budget the existing mf K10 row used (T0.4)
R26_K="${R26_K:-2}"
R26_TRAIN_SEEDS="${R26_TRAIN_SEEDS:-7 8 9 10}"
R26_TAG="${R26_TAG:-dpccproto}"            # same namespace as the FM / CI-MeanFM protocol rows (jobs 25878/25880)
AVOID_TRAIN_HOURS="${AVOID_TRAIN_HOURS:-12}"   # author: 12–24 h window (job 25965 took 2 h 41 m)
AVOID_EVAL_HOURS="${AVOID_EVAL_HOURS:-12}"
UAV_SEEDS="${UAV_SEEDS:-6}"
SCURVE_NTRIALS="${SCURVE_NTRIALS:-10}"
CORRIDOR_NTRIALS="${CORRIDOR_NTRIALS:-12}"     # 12 = 4 per route, as the u17cv2 paper run
RECORD="${RECORD:-none}"
R30_TAG="${R30_TAG:-u17cv2}"
R31U_TAG="${R31U_TAG:-u7hg}"
R31P_TAG="${R31P_TAG:-u18sc}"
R31_PERSTEP="${R31_PERSTEP:-dpcc-t}"       # OPEN: u18sc used plain dpcc-t, the corridor uses dpcc-t-tightened. Grid follows u18sc.
R15_TAG="${R15_TAG:-u19mjpc}"
R28_KS="${R28_KS:-5 10}"
PANEL_WANDB="${PANEL_WANDB:-1}"

say() { printf '%s\n' "$*"; }
hr()  { say "────────────────────────────────────────────────────────────────────────────"; }

# ── pre-flight ───────────────────────────────────────────────────────────────
fail=0
need_file() { [ -f "$1" ] || { say "[FAIL] missing $1"; fail=1; }; }
need_file Slurm_Codes/submit.sh
need_file config/aligning-d3il-visual.py
need_file config/avoiding-d3il.py
need_file config/visual_aligning_eval.yaml
need_file config/projection_eval.yaml
need_file mix_visual_aligning_test/eval_mix_visual_aligning.py
need_file mix_visual_aligning_test/train_mix_visual_aligning.py
need_file scripts/train.py
need_file scripts/eval.py
need_file Slurm_Codes/sbatch/uav_mix/eval_k_sweep.sh
need_file Slurm_Codes/sbatch/uav_mix/eval_mix_uav.sh
need_file Slurm_Codes/sbatch/eval_fmv3_ode_job.sh

if want B || want H; then
    grep -Eq '^n_trials: *2([[:space:]]|$)' config/projection_eval.yaml || {
        say "[FAIL] config/projection_eval.yaml is not at n_trials: 2 — B2/H are the DPCC protocol (author, v3.55)"; fail=1; }
    grep -Eq '^seeds: *\[6, *7, *8, *9, *10\]' config/projection_eval.yaml || {
        say "[FAIL] config/projection_eval.yaml is not the five-seed protocol"; fail=1; }
    grep -qE "^\s*'diffuser'," config/projection_eval.yaml || { say "[FAIL] no 'diffuser' in projection_eval.yaml"; fail=1; }
fi
if want C || want D || want E || want G; then
    for g in s_curve_hg corridor_v2_slide; do
        grep -q "name: ${g}\b" config/uav_projection.yaml || { say "[FAIL] geo '${g}' missing from config/uav_projection.yaml"; fail=1; }
    done
    grep -qE "^diffusion_timestep_threshold: 0.5\b" config/uav_projection.yaml || { say "[FAIL] uav diffusion_timestep_threshold is not 0.5"; fail=1; }
    grep -q "def update_constraint_list" mix_uav/sampling/hardflow_projection.py || { say "[FAIL] hardflow_projection.py lacks update_constraint_list (switched-wall fix; E depends on it)"; fail=1; }
    grep -q "_TOGGLES = ('-pdes'" mix_uav_test/eval_mix_uav.py || { say "[FAIL] eval_mix_uav.py lacks the composed-toggle allow-list"; fail=1; }
fi
if want A || want F; then
    grep -q "custom_msg = _sanitize_msg(os.environ.get('FMPCC_RUN_MSG'" config/aligning-d3il-visual.py || {
        say "[FAIL] config/aligning-d3il-visual.py has no FMPCC_RUN_MSG hook — the aligning tag would be ignored"; fail=1; }
    grep -q "^n_contexts:" config/visual_aligning_eval.yaml || { say "[FAIL] visual_aligning_eval.yaml has no n_contexts key"; fail=1; }
fi
[ "$fail" -eq 0 ] || { say "ABORT — fix the pre-flight before submitting."; exit 1; }
say "[ ok ] pre-flight passed"
say "[ git ] $(git rev-parse --short HEAD 2>/dev/null || echo '-')  $(git status --short 2>/dev/null | wc -l | tr -d ' ') dirty path(s)"
say "[ disk ] $(df -h "$REPO" | awk 'NR==2 {print $4" free on "$6}')"
FREE_KIB="$(df -Pk "$REPO" | awk 'NR==2 {print $4}')"
if want B || want F; then
    if [ -n "$FREE_KIB" ] && [ "$FREE_KIB" -lt $((4 * 1024 * 1024)) ]; then
        say "[WARN] under 4 GiB free and this wave TRAINS (B1: four avoiding checkpoints; F3: one visual-aligning checkpoint)."
        [ "$MODE" = "submit" ] && [ "${FORCE_DISK:-0}" != "1" ] && { say "ABORT — set FORCE_DISK=1 to submit anyway."; exit 1; }
    fi
fi
YAML_NCTX="$(grep -E '^n_contexts:' config/visual_aligning_eval.yaml | awk '{print $2}')"
say "[ align ] config/visual_aligning_eval.yaml n_contexts = ${YAML_NCTX}  ->  every aligning job here injects ${ALIGN_NCTX} in memory"
say "[ pillars ] R23: NO pillars job in this driver — gate: read the four results.json of pillars runbook §3e first."

# ── throwaway python wrappers (written in PLAN mode too, so the plan is inspectable) ────────
cat > "$HERE/${P}_align_eval.py" <<'PY'
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
PY

cat > "$HERE/${P}_align_train.py" <<'PY'
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
PY

cat > "$HERE/${P}_avoid_train.py" <<'PY'
# THROWAWAY — written by pipeline_20260922_all_lacking_runs.sh. Gitignored. Read AT JOB START.
# scripts/train.py with the `diffusion` block's n_diffusion_steps overridden in memory
# (the job-25965 pattern). Checkpoint lands in diffusion/H8_K<K>_Dmodels.GaussianDiffusion_aw10/<seed>.
import importlib, os, sys, runpy
K   = int(os.environ['LR_K'])
mod = importlib.import_module('config.avoiding-d3il')
blk = mod.base['diffusion']
blk['n_diffusion_steps'] = K
print(f'[ lr22 ] TRAIN  n_diffusion_steps -> {K}   '
      f'(checkpoint: diffusion/H{blk["horizon"]}_K{K}_D{blk["diffusion"]}_aw{blk["action_weight"]})', flush=True)
sys.argv = ['scripts/train.py', '--seed', os.environ['LR_SEED']]
if os.environ.get('PANEL_WANDB', '1') == '1':
    sys.argv += ['--use-wandb', '--wandb-project', 'FMPCC-knoll']
runpy.run_path('scripts/train.py', run_name='__main__')
PY

cat > "$HERE/${P}_avoid_eval.py" <<'PY'
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
PY

# ── job-file generators ──────────────────────────────────────────────────────
_header() {  # $1=jobname $2=hours
cat <<SB
#!/bin/bash
#SBATCH --job-name=$1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --gres=gpu:1
#SBATCH --time=$2:00:00
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
SB
}

_preamble() {  # $1 = align | avoid
cat <<'SB'
FMPCC_ROOT="$HOME/FMPCC"; REPO="$FMPCC_ROOT/FM-PCC"
source "$HOME/miniconda3/etc/profile.d/conda.sh"; conda activate FMPCC
export FMPCC="$REPO"; export D3IL_ROOT="$FMPCC/d3il"
SB
if [ "$1" = "align" ]; then
cat <<'SB'
export D3IL_ENV_ROOT="$D3IL_ROOT/environments/d3il"
export PYTHONPATH="$FMPCC:$D3IL_ROOT:$D3IL_ENV_ROOT:$PYTHONPATH"
SB
else
cat <<'SB'
export GYM_AV="$D3IL_ROOT/environments/d3il/envs/gym_avoiding_env"
export PYTHONPATH="$FMPCC:$D3IL_ROOT:$GYM_AV:$PYTHONPATH"
SB
fi
cat <<'SB'
export MUJOCO_GL="egl"; export PYOPENGL_PLATFORM="egl"; export MPLBACKEND="agg"
export PYTHONUNBUFFERED=1
export CUDA_DEVICE_ORDER="PCI_BUS_ID"
export MUJOCO_EGL_DEVICE_ID="${CUDA_VISIBLE_DEVICES%%,*}"
echo "[ GPU-CHECK ] CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES  MUJOCO_EGL_DEVICE_ID=$MUJOCO_EGL_DEVICE_ID"
if [ "$MUJOCO_EGL_DEVICE_ID" != "${CUDA_VISIBLE_DEVICES%%,*}" ]; then
    echo "[ GPU-LEAK ] EGL device != CUDA device -- aborting"; exit 1
fi
if [ -f "$HOME/FMPCC/.wandb_api_key" ]; then
    export WANDB_API_KEY=$(cat $HOME/FMPCC/.wandb_api_key); export WANDB_MODE="online"
    [ -n "$SLURM_JOB_ID" ] && export WANDB_TAGS="slurm-$SLURM_JOB_ID"
fi
cd "$REPO"
echo "[ lr22 ] disk free on logs:"; df -h logs 2>/dev/null | tail -1 || true
SB
}

_exports() {  # KEY=VALUE ... -> export lines, values quoted
    local kv
    for kv in "$@"; do printf 'export %s=%q\n' "${kv%%=*}" "${kv#*=}"; done
}

# gen_align_eval NAME HOURS KEY=VAL...   (KEY=VAL are the LR_*/MIX_*/FMPCC_RUN_MSG exports)
gen_align_eval() {
    local name="$1" hours="$2"; shift 2
    local f="$HERE/${P}_${name}.sh"
    { _header "$name" "$hours"; _exports "$@"; _preamble align; cat <<'SB'
python "Slurm_Codes/temp_bash/_lr22_align_eval.py"
echo "[ lr22 ] result dirs carrying this tag:"
find logs/aligning-d3il-visual -maxdepth 6 -type d -name "*_msg${FMPCC_RUN_MSG}*" 2>/dev/null | sort | head -20 || true
echo "Evaluation completed successfully."
SB
    } > "$f"; chmod +x "$f"; echo "$f"
}

gen_align_train() {
    local name="$1" hours="$2"; shift 2
    local f="$HERE/${P}_${name}.sh"
    { _header "$name" "$hours"; _exports "$@"; _preamble align; cat <<'SB'
python "Slurm_Codes/temp_bash/_lr22_align_train.py"
echo "[ lr22 ] checkpoint dirs at K=${LR_DIFF_K}:"
find logs/aligning-d3il-visual -maxdepth 3 -type d -path "*mix_visual_aligning_diffusion*" -name "*_K${LR_DIFF_K}_*" 2>/dev/null | sort || true
echo "Training completed successfully."
SB
    } > "$f"; chmod +x "$f"; echo "$f"
}

gen_avoid_train() {
    local name="$1" hours="$2"; shift 2
    local f="$HERE/${P}_${name}.sh"
    { _header "$name" "$hours"; _exports "$@"; _preamble avoid; cat <<'SB'
CKPT="logs/avoiding-d3il/diffusion/H8_K${LR_K}_Dmodels.GaussianDiffusion_aw10/${LR_SEED}"
if [ -d "$CKPT" ] && ls "$CKPT"/state_*.pt >/dev/null 2>&1; then
    echo "[ lr22 ] ❌ $CKPT already holds checkpoints — refusing to retrain over it"; exit 2
fi
python "Slurm_Codes/temp_bash/_lr22_avoid_train.py"
echo "[ lr22 ] checkpoint dir: $CKPT"
ls -1 "$CKPT" 2>/dev/null | tail -5 || { echo "[ lr22 ] ❌ no checkpoint written"; exit 2; }
echo "Training completed successfully."
SB
    } > "$f"; chmod +x "$f"; echo "$f"
}

gen_avoid_eval() {
    local name="$1" hours="$2"; shift 2
    local f="$HERE/${P}_${name}.sh"
    { _header "$name" "$hours"; _exports "$@"; _preamble avoid; cat <<'SB'
NT=$(grep -E '^n_trials:' config/projection_eval.yaml | tr -d '\r' | awk '{print $2}')
[ "$NT" = "2" ] || { echo "[ lr22 ] ❌ projection_eval.yaml n_trials=$NT at job start — protocol is 2"; exit 2; }
# 🔴 HARDENED 2026-09-22, after job 26056. The old guard only asked whether ANY state_*.pt
# existed. Training writes one every n_steps_per_epoch (1000) up to n_train_steps (1e5), so a
# seed that started minutes ago already passes that test — which is how 26056 came to evaluate
# a half-trained seed 10. The guard now demands the FINAL step, calibrated against seed 6,
# whose checkpoint came from the completed job 25965. Anything short of it aborts the job.
BASE="logs/avoiding-d3il/diffusion/H8_K${LR_K}_Dmodels.GaussianDiffusion_aw10"
last_step() { ls -1 "$1"/state_*.pt 2>/dev/null | sed -E 's/.*state_([0-9]+)\.pt/\1/' | sort -n | tail -1; }
REF="$(last_step "$BASE/6")"
[ -n "$REF" ] || { echo "[ lr22 ] ❌ no seed-6 reference checkpoint under $BASE/6"; exit 2; }
echo "[ lr22 ] reference: seed 6 trained to step $REF (job 25965)"
for s in 6 7 8 9 10; do
    HAVE="$(last_step "$BASE/$s")"
    [ -n "$HAVE" ] || { echo "[ lr22 ] ❌ no K=${LR_K} checkpoint at all for seed $s"; exit 2; }
    if [ "$HAVE" -lt "$REF" ]; then
        echo "[ lr22 ] ❌ seed $s is INCOMPLETE: step $HAVE < reference $REF."
        echo "[ lr22 ]    Its training job has not finished. Refusing to evaluate a half-trained model."
        exit 2
    fi
    echo "[ lr22 ] seed $s: step $HAVE ✅"
done
python "Slurm_Codes/temp_bash/_lr22_avoid_eval.py"
echo "[ lr22 ] result folders:"
find logs/avoiding-d3il/plans/diffusion -maxdepth 3 -type d -path "*K${LR_K}_*" -name "*_msg${FMPCC_RUN_MSG}*" 2>/dev/null | sort || true
echo "Evaluation completed successfully."
SB
    } > "$f"; chmod +x "$f"; echo "$f"
}

# ── submission helpers ───────────────────────────────────────────────────────
N=0
LAST_ID=""
JOB_IDS=()
plan_line() { N=$((N + 1)); printf '  %-3s %s\n' "$N" "$1"; }
# submit_file LABEL FILE [DEPENDENCY]  — captures the job id into LAST_ID
#
# 🔴 FIXED 2026-09-22, after job 26056. This used to pass the dependency as the environment
# variable SBATCH_DEPENDENCY through submit.sh. IT DID NOT ATTACH: 26056 was queued with reason
# (QOSMaxCpuPerUserLimit), never (Dependency), and it STARTED while its training job 26055 was
# still running — which afterok makes impossible. The eval then loaded a half-trained seed-10
# checkpoint and had to be cancelled and re-run. The env-var form is not trustworthy here; the
# ONLY accepted form is the explicit `sbatch --dependency=` flag, which is what the proven
# 2026-09-17 driver used (pipeline_20260917_r8_dpccproto_all.sh:114). A dependent job therefore
# bypasses submit.sh and calls sbatch directly, reproducing submit.sh's date-organised log
# routing, and then VERIFIES with scontrol that the dependency is really on the job.
submit_file() {
    local label="$1" file="$2" dep="${3:-}"
    plan_line "$label"
    [ -n "$dep" ] && say "       ⛓ dependency: $dep"
    [ "$MODE" = "plan" ] && { LAST_ID="PLAN"; return 0; }
    local out
    if [ -n "$dep" ]; then
        local d t ldir
        d="$(date +%Y-%m-%d)"; t="$(date +%H_%M_%S)"; ldir="Slurm_Codes/logs/$d"; mkdir -p "$ldir"
        LAST_ID="$(sbatch --parsable \
            --job-name="$(basename "${file%.sh}")" \
            --output="$ldir/${t}_%x_%j.log" \
            --error="$ldir/${t}_%x_%j.log" \
            --export=ALL,SUBMIT_TIME="$t",SUBMIT_DATE="$d" \
            --dependency="$dep" \
            "$file")"
        [ -n "$LAST_ID" ] || { say "❌ sbatch returned no job id for $label — stopping"; exit 1; }
        say "✅ Submitted $LAST_ID  (log dir $ldir)"
        # PROVE the dependency landed. A job whose Dependency field is empty is a silent
        # ordering bug: it will run against an unfinished checkpoint, as 26056 did.
        local shown; shown="$(scontrol show job "$LAST_ID" 2>/dev/null | grep -oP 'Dependency=\K\S+' || true)"
        if [ -z "$shown" ] || [ "$shown" = "(null)" ]; then
            say "❌ job $LAST_ID has NO dependency attached (wanted $dep) — cancelling it now"
            scancel "$LAST_ID" || true
            exit 1
        fi
        say "   ⛓ verified on the job: Dependency=$shown"
    else
        out=$(env -u SBATCH_DEPENDENCY ./Slurm_Codes/submit.sh "$file")
        say "$out"
        LAST_ID=$(printf '%s\n' "$out" | grep -oP 'Job ID:\s*\K[0-9]+' | tail -1)
        [ -n "$LAST_ID" ] || { say "❌ could not read a job id for $label — stopping"; exit 1; }
    fi
    JOB_IDS+=("$LAST_ID:$label")
}
# run_env LABEL env-args... -- submit.sh args...   (stock entrypoints, no dependency)
run_env() {
    local label="$1"; shift
    plan_line "$label"
    [ "$MODE" = "plan" ] && return 0
    local out; out=$(env -u SBATCH_DEPENDENCY "$@"); say "$out"
    LAST_ID=$(printf '%s\n' "$out" | grep -oP 'Job ID:\s*\K[0-9]+' | tail -1)
    [ -n "$LAST_ID" ] && JOB_IDS+=("$LAST_ID:$label")
}

# UAV knobs — UNSET anything inherited so a job's behaviour is provable from this file alone
UAV_UNSET=( -u UAV_MIX_BONE_AF -u UAV_MIX_AF_ALPHA_END -u UAV_MIX_EPOCH -u UAV_MIX_CONTROLLER
            -u UAV_MIX_HF_OFF -u FMPCC_HF_ALLOW_DEGENERATE -u FMPCC_HF_MIN_GENUINE -u FMPCC_SAFE_EPS_FRAC
            -u HFFM_ACT_THRESHOLD -u UAV_MIX_TRAJ_GIF -u UAV_MIX_VARIANTS -u UAV_MIX_GEO_VARIANTS -u FMPCC_RUN_MSG )
af_env() { case "$1" in af) echo "UAV_MIX_BONE_AF=unet UAV_MIX_AF_ALPHA_END=0.2 UAV_MIX_EPOCH=latest" ;; *) echo "" ;; esac; }
join() { local IFS=,; echo "$*"; }
check_variants() {   # $1=label $2..=names — shape, no whitespace, HardFlow never alone
    local label="$1"; shift; local bad=0 hf=0 pcc=0 v
    for v in "$@"; do
        case "$v" in *[[:space:]]*) say "[FAIL] $label: whitespace in '$v'"; bad=1 ;; ""|*--*|*-) say "[FAIL] $label: malformed '$v'"; bad=1 ;; esac
        case "$v" in hardflow*) hf=1 ;; diffuser) ;; *) pcc=1 ;; esac
    done
    [ "$hf" -eq 1 ] && [ "$pcc" -eq 0 ] && { say "[FAIL] $label: HardFlow-only subset (the eval exits 2)"; bad=1; }
    [ "$bad" -eq 0 ] || { say "ABORT — not submitting."; exit 1; }
}
# uav_sweep ENGINE SCENE GEO "K list" VARIANTS_CSV TAG NTRIALS [extra env...]
uav_sweep() {
    local e="$1" sc="$2" geo="$3" ks="$4" v="$5" tag="$6" n="$7"; shift 7
    # shellcheck disable=SC2046
    run_env "${e} ${sc}/${geo} K=[${ks}] n=${n} tag=${tag} $*: ${v}" \
        env "${UAV_UNSET[@]}" UAV_EVAL_HOURS=24 FMPCC_SAFE_EPS_MODE=scaled \
            FMPCC_UAV_EVAL_TAG="$tag" UAV_MIX_GEO_VARIANTS="$geo" UAV_MIX_VARIANTS="$v" \
            $(af_env "$e") "$@" \
        ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/eval_k_sweep.sh \
            "$e" "$sc" "$UAV_SEEDS" "$ks" "$n" fm_only "$RECORD"
}

# ── variant sets (arrays: one name per line, never a long literal) ───────────
S_UNPROJ=( diffuser )
S_PROJ=( diffuser "$R31_PERSTEP" hardflow_new hardflow_new-r hardflow_new-c hardflow_new-t )
C_R30=( dpcc-t-tightened )
S_R15=( diffuser dpcc-r hardflow_new-r )
check_variants "R31 unprojected" "${S_UNPROJ[@]}"
check_variants "R31 projected"   "${S_PROJ[@]}"
check_variants "R30 corridor"    "${C_R30[@]}"
check_variants "R15 mjpc"        "${S_R15[@]}"

hr
say "MODE=$MODE   WAVE=$WAVE   align: seed=$ALIGN_SEED nctx=$ALIGN_NCTX tag=_msg$ALIGN_TAG   avoid: K=$R26_K tag=_msg$R26_TAG   uav: seeds=$UAV_SEEDS record=$RECORD"
hr

# ═════════════════════════════════════════════════════════════════════════════
if want A; then
    say "### A · R2 🔴 — D3IL-aligning diffusion K=20 baseline on the TIGHTENED set (combined_5 + twin), $ALIGN_NCTX contexts"
    f=$(gen_align_eval "A_r2_align_diffusion_K20" "$ALIGN_HOURS" \
            LR_ENGINE=diffusion "LR_SEEDS=$ALIGN_SEED" "LR_NCTX=$ALIGN_NCTX" "LR_VARIANTS=$ALIGN_VARIANTS" \
            "LR_GEOS=$ALIGN_GEOS" "LR_RECORD=$RECORD" "FMPCC_RUN_MSG=$ALIGN_TAG" \
            MIX_BONE_DIFFUSION=unet MIX_FILM_MODE_DIFFUSION=v1)
    submit_file "aligning diffusion K=20 (plan block) seed=$ALIGN_SEED nctx=$ALIGN_NCTX geos=$ALIGN_GEOS(+tightened) variants=$ALIGN_VARIANTS tag=_msg$ALIGN_TAG  [$f]" "$f"
    say
fi

if want B; then
    say "### B · R26 🟡 — D3IL-avoiding diffusion K=$R26_K: four trainings, then one five-seed DPCC-protocol eval"
    say "    (reopened by the author at v3.57; seed 6 exists from job 25965/25966; the row needs seeds 7–10)"
    DEP_IDS=""
    for s in $R26_TRAIN_SEEDS; do
        CK="logs/avoiding-d3il/diffusion/H8_K${R26_K}_Dmodels.GaussianDiffusion_aw10/${s}"
        if ls "$CK"/state_*.pt >/dev/null 2>&1; then
            plan_line "B1 seed $s: checkpoint already present at $CK — SKIP training"; continue
        fi
        f=$(gen_avoid_train "B1_r26_avoid_train_K${R26_K}_s${s}" "$AVOID_TRAIN_HOURS" \
                "LR_K=$R26_K" "LR_SEED=$s" "PANEL_WANDB=$PANEL_WANDB")
        submit_file "B1 avoiding diffusion TRAIN K=$R26_K seed=$s  [${AVOID_TRAIN_HOURS}h, 1 GPU]  [$f]" "$f"
        [ "$MODE" = "submit" ] && DEP_IDS="${DEP_IDS:+$DEP_IDS:}$LAST_ID"
    done
    f=$(gen_avoid_eval "B2_r26_avoid_eval_K${R26_K}_5seeds" "$AVOID_EVAL_HOURS" \
            "LR_K=$R26_K" "LR_SEED=" "FMPCC_RUN_MSG=$R26_TAG" FMPCC_MPC_BATCH=4)
    dep=""; [ -n "$DEP_IDS" ] && dep="afterok:$DEP_IDS"
    [ "$MODE" = "plan" ] && dep="afterok:<all B1 ids>"
    submit_file "B2 avoiding diffusion EVAL K=$R26_K seeds=6..10 (yaml) n_trials=2 geos=3 variants=<yaml list> tag=_msg$R26_TAG  [$f]" "$f" "$dep"
    say
fi

if want C; then
    say "### C · R30 🟢 — UAV-corridor diffusion baseline under plain dpcc-t-tightened, $CORRIDOR_NTRIALS flights, tag $R30_TAG"
    say "    (new cell: the baseline was only ever run as dpcc-t-bounds_free-pdes-tightened; nothing is overwritten)"
    run_env "diffusion corridor/corridor_v2_slide K=[plan block 20] n=$CORRIDOR_NTRIALS tag=$R30_TAG: $(join "${C_R30[@]}")" \
        env "${UAV_UNSET[@]}" UAV_EVAL_HOURS=24 FMPCC_SAFE_EPS_MODE=scaled FMPCC_SAFE_EPS_FRAC=1.0 \
            FMPCC_UAV_EVAL_TAG="$R30_TAG" UAV_MIX_GEO_VARIANTS=corridor_v2_slide UAV_MIX_VARIANTS="$(join "${C_R30[@]}")" \
        ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/eval_mix_uav.sh \
            diffusion corridor "$UAV_SEEDS" "$CORRIDOR_NTRIALS" fm_only "$RECORD" ""
    say
fi

if want D; then
    say "### D · R31 🟡 unprojected — UAV-s-curve matched grid: mf K1,3,5 · af K3 · fm K1,3,5 (7 children), tag $R31U_TAG"
    say "    (only the missing cells: mf K2/K10, af K1/K2/K5, fm K2/K20 already exist and are not re-run)"
    uav_sweep mf s_curve s_curve_hg "1 3 5" "$(join "${S_UNPROJ[@]}")" "$R31U_TAG" "$SCURVE_NTRIALS"
    uav_sweep af s_curve s_curve_hg "3"     "$(join "${S_UNPROJ[@]}")" "$R31U_TAG" "$SCURVE_NTRIALS"
    uav_sweep fm s_curve s_curve_hg "1 3 5" "$(join "${S_UNPROJ[@]}")" "$R31U_TAG" "$SCURVE_NTRIALS"
    say
fi

if want E; then
    say "### E · R31 🟡 projected — UAV-s-curve post-correction grid: mf K3,5 · af K3 · fm K3,5 (5 children, one per cell), tag $R31P_TAG"
    say "    per-step arm = $R31_PERSTEP (follows u18sc; set R31_PERSTEP=dpcc-t-tightened to mirror the corridor instead)"
    uav_sweep mf s_curve s_curve_hg "3 5" "$(join "${S_PROJ[@]}")" "$R31P_TAG" "$SCURVE_NTRIALS"
    uav_sweep af s_curve s_curve_hg "3"   "$(join "${S_PROJ[@]}")" "$R31P_TAG" "$SCURVE_NTRIALS"
    uav_sweep fm s_curve s_curve_hg "3 5" "$(join "${S_PROJ[@]}")" "$R31P_TAG" "$SCURVE_NTRIALS"
    say
fi

if want F; then
    say "### F · R16 🟡 — D3IL-aligning at K=$R16_K: fm, af (evals) and diffusion (train + eval), $ALIGN_NCTX contexts, tag _msg$ALIGN_TAG"
    f=$(gen_align_eval "F1_r16_align_fm_K${R16_K}" "$ALIGN_HOURS" \
            LR_ENGINE=fm "LR_SEEDS=$ALIGN_SEED" "LR_NCTX=$ALIGN_NCTX" "LR_VARIANTS=$ALIGN_VARIANTS" "LR_GEOS=$ALIGN_GEOS" \
            "LR_RECORD=$RECORD" "LR_K=$R16_K" "LR_T=$R16_T" "FMPCC_RUN_MSG=$ALIGN_TAG" MIX_BONE_FM=unet MIX_FILM_MODE_FM=v1)
    submit_file "F1 aligning fm K=$R16_K T=$R16_T  [$f]" "$f"
    f=$(gen_align_eval "F2_r16_align_af_K${R16_K}" "$ALIGN_HOURS" \
            LR_ENGINE=af "LR_SEEDS=$ALIGN_SEED" "LR_NCTX=$ALIGN_NCTX" "LR_VARIANTS=$ALIGN_VARIANTS" "LR_GEOS=$ALIGN_GEOS" \
            "LR_RECORD=$RECORD" "LR_K=$R16_K" "LR_T=$R16_T" LR_EPOCH=latest "FMPCC_RUN_MSG=$ALIGN_TAG" \
            MIX_AF_ALPHA_END=0.2 MIX_EPOCH=latest MIX_BONE_AF=unet MIX_FILM_MODE_AF=v1)
    submit_file "F2 aligning af  K=$R16_K T=$R16_T alpha_end=0.2 epoch=latest  [$f]" "$f"
    f=$(gen_align_train "F3_r16_align_train_diffusion_K${R16_K}" "$ALIGN_TRAIN_HOURS" \
            "LR_DIFF_K=$R16_K" "LR_SEEDS=$ALIGN_SEED" "PANEL_WANDB=$PANEL_WANDB" MIX_BONE_DIFFUSION=unet MIX_FILM_MODE_DIFFUSION=v1)
    submit_file "F3 aligning diffusion TRAIN n_diffusion_steps=$R16_K seed=$ALIGN_SEED  [${ALIGN_TRAIN_HOURS}h]  [$f]" "$f"
    dep="afterok:$LAST_ID"; [ "$MODE" = "plan" ] && dep="afterok:<F3 id>"
    f=$(gen_align_eval "F4_r16_align_diffusion_K${R16_K}" "$ALIGN_HOURS" \
            LR_ENGINE=diffusion "LR_SEEDS=$ALIGN_SEED" "LR_NCTX=$ALIGN_NCTX" "LR_VARIANTS=$ALIGN_VARIANTS" "LR_GEOS=$ALIGN_GEOS" \
            "LR_RECORD=$RECORD" "LR_DIFF_K=$R16_K" "FMPCC_RUN_MSG=$ALIGN_TAG" MIX_BONE_DIFFUSION=unet MIX_FILM_MODE_DIFFUSION=v1)
    submit_file "F4 aligning diffusion EVAL n_diffusion_steps=$R16_K (needs the F3 checkpoint)  [$f]" "$f" "$dep"
    say
fi

if want G; then
    say "### G · R15 🟡 opt-in — UAV-s-curve MuJoCo-MPC controller at $SCURVE_NTRIALS flights (mf K10), tag $R15_TAG"
    say "    🔴 needs the FMPCC_mjx conda env on the node; eval_mix_uav.sh switches env on UAV_MIX_CONTROLLER=mjpc"
    uav_sweep mf s_curve s_curve_hg "10" "$(join "${S_R15[@]}")" "$R15_TAG" "$SCURVE_NTRIALS" UAV_MIX_CONTROLLER=mjpc
    say
fi

if want H; then
    say "### H · R28 🟡 opt-in (NOT OWED) — D3IL-avoiding FM at K=[$R28_KS], seeds 6..10 (yaml), n_trials=2, tag _msg$R26_TAG"
    run_env "fmv3 ode-selectable K=[$R28_KS] seeds=<yaml 6..10> n_trials=2 tag=_msg$R26_TAG (one job, K loop inside)" \
        env -u AF_BONE -u AF_ALPHA_END -u AF_EPOCH -u AF_SEEDS -u AF_NTRIALS \
            FMV3_FLOW_STEPS="$R28_KS" FMPCC_RUN_MSG="$R26_TAG" \
        ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/eval_fmv3_ode_job.sh
    say
fi

hr
if [ "$MODE" = "plan" ]; then
    say "PLAN ONLY — $N line(s) above would be submitted. Nothing was sent to Slurm."
    say "Generated job files (inspect them):"; ls -1 "$HERE"/${P}_*.sh 2>/dev/null | sed 's/^/  /' || true
    say "Run again with:  WAVE=\"$WAVE\" bash $0 submit"
else
    say "SUBMITTED $N line(s). Job ids:"
    for j in "${JOB_IDS[@]}"; do say "  $j"; done
    say "Note: each eval_k_sweep.sh driver fans out to ONE child job per K."
    say "Copy the ids into §7 of"
    say "  logs_in_develop/Writing/Working_Space/data_status/SLURM_RUNBOOK_20260922_all_lacking_runs.md"
fi
say "No download action was performed. Keep the ${P}_* files until every job has ended."
