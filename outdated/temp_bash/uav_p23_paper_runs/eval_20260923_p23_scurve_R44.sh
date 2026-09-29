#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# R44 — UAV-s-curve, Chapter 6: the raw generative grid FIRST (Phase A). Projection (B) and the controller
# comparison (C) are submitted only after the author has read Phase A and named the model and the budget.
#   spec     logs_in_develop/Writing/Working_Space/data_status/PENDING_20260923_uav_scurve_R44_raw_first.md
#   runbook  logs_in_develop/Writing/Working_Space/data_status/SLURM_RUNBOOK_20260923_uav_scurve_R44.md
#
#   bash Slurm_Codes/temp_bash/eval_20260923_p23_scurve_R44.sh            # PLAN phase A (default) — submits NOTHING
#   bash Slurm_Codes/temp_bash/eval_20260923_p23_scurve_R44.sh submit     # SUBMIT phase A: 10 GPU jobs, one per cell
#   bash Slurm_Codes/temp_bash/eval_20260923_p23_scurve_R44.sh status     # per cell: queue, log checks, results preview
#   bash Slurm_Codes/temp_bash/eval_20260923_p23_scurve_R44.sh export     # results + job logs -> export_tmp/R44_<TAG>_<stamp>.tar.gz
#
#   CELLS="A1 A3 A6 A7" bash … submit   a subset (CELLS=required = those four, the cells the table lacks)
#   FORCE=1 bash … submit               re-fly cells whose results.json already exist under the marker (OVERWRITES them)
#   PHASE=B SC_ENGINE=<mf|af|fm|diffusion> SC_K=<1|2|20> bash … <mode>                  only after the author's pick
#   PHASE=C SC_ENGINE=… SC_K=… SC_RULE=dpcc-<r|c|t>-tightened bash … <mode>              only after Phase B
#
# THE MARKER — one unique tag per phase, carried three ways, so nothing is pooled or lost:
#   results folder  logs/UAV_MIX/uav-s_curve/plans/mix_uav_<e>/<train>/E<e>_K<k>_mpc4_<ctrl>_T0.5[_EPlatest]_<TAG>/6/…
#   job name        <TAG>_<cell>_<e>_K<k>  -> squeue, and the log Slurm_Codes/logs/<date>/<time>_<TAG>_<cell>_<e>_K<k>_<id>.log
#   ledger          Slurm_Codes/logs/<date>/R44_<TAG>_jobids.tsv  (one line per submitted job)
#   TAG: A p23scgrid · B p23scproj · C p23scmjpc — never an old tag (u7hg, u18sc, u6unet_ae02 are what the table reads today).
#   `submit` skips a cell already in squeue and a cell whose results.json exist, so running it twice is safe.
#
# HOW A CELL IS SUBMITTED — the per-K sbatch call of Slurm_Codes/sbatch/uav_mix/eval_k_sweep.sh, made here directly so
# the job carries the marker as its name (the sweep names every child `uav_mix_eval`, like the corridor-v3 jobs already
# queued): sbatch --parsable --job-name=<marker> --time=24:00:00 (UAV standing rule), log in Slurm_Codes/logs/<date>/ with
# submit.sh's <time>_%x_%j.log convention, then Slurm_Codes/sbatch/uav_mix/eval_mix_uav.sh <e> s_curve 6 10 fm_only none <K>.
# Job script, GPU/EGL isolation block, conda-env selection and eval are the tracked ones, unchanged.
#
# FIXED ENV on every job; every other knob the eval reads is UNSET, so a stray export in this shell cannot leak in:
#   FMPCC_UAV_EVAL_TAG=<TAG> UAV_MIX_GEO_VARIANTS=s_curve_hg UAV_MIX_VARIANTS=<the cell's variants>
#   FMPCC_SAFE_EPS_MODE=scaled FMPCC_SAFE_EPS_FRAC=1e-3 — what every s-curve cell ran with (jobs 25422/25424 u7hg,
#     25441-25443 u6unet_ae02, 25612 diffusion tightened, 25908-25910 u18sc). NOT the corridor's 1.0.
#   af: UAV_MIX_BONE_AF=unet UAV_MIX_AF_ALPHA_END=0.2 UAV_MIX_EPOCH=latest (folder token _EPlatest); mf / fm / diffusion
#     keep the default checkpoint `best`, as u7hg did.
#   controller: config default pid_stopgo in A and B (UAV_MIX_CONTROLLER unset); C sets UAV_MIX_CONTROLLER=mjpc, which
#     makes eval_mix_uav.sh activate the FMPCC_mjx conda env.
#   diffusion gets no K argument: its K is the training budget (20 steps); the plan block labels the folder K20.
#
# PHASE A (spec §1) — variant `diffuser` only, ten flights of the one route, seed 6, record none. Fast cells first:
#   A1 mf K1 · A2 mf K2 · A4 af K1 · A5 af K2 · A7 fm K1 · A8 fm K2 · A3 mf K20 · A6 af K20 · A9 fm K20 · A10 diffusion K20
#   Default: all ten (one tag for the whole of tab:uav-scurve; ~2 GPU-h in total). CELLS=required: A1 A3 A6 A7.
# PHASE B (spec §3) — tag p23scproj, tightened set, `-tightened` is always the last token.
#   Endpoint (HardFlow) rows need a velocity field (not diffusion) and a guiding step (K >= 3; in this grid K = 20).
#   The eval refuses a job holding HardFlow rows and no dpcc-* row, so each endpoint rule rides with its per-step twin:
#     flow model K20:   B0 diffuser · Br dpcc-r-tightened+hardflow_new-r-tightened · Bc (…-c…) · Bt (…-t…)
#                       ⚠ a pair is ~10-20 h at K20 (per-step 7-11 h + endpoint 3-9 h, spec §2) — inside 24 h, not by much
#     flow model K1/2:  B1 diffuser,dpcc-r-tightened,dpcc-c-tightened,dpcc-t-tightened   (one job, ~1.5 h; no guiding step)
#     diffusion K20:    B0 diffuser · Br · Bc · Bt, one per-step rule per job (no endpoint arm; up to 24 h each)
# PHASE C (spec §4) — tag p23scmjpc, UAV_MIX_CONTROLLER=mjpc: C0 diffuser · C1 SC_RULE (Phase B's per-step rule with the
#   most crossings). The cascaded-geometric rows of that table are the matching A and B cells; nothing else is re-run.
#
# Slurm_Codes/temp_bash/ is gitignored: `git add -f` this file (as the other p23 drivers) or copy it to the cluster.
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
cd "$REPO"

MODE="${1:-plan}"
case "$MODE" in plan|submit|status|export) ;; *) echo "[FAIL] mode must be plan | submit | status | export (got '$MODE')"; exit 1 ;; esac
PHASE="${PHASE:-A}"
case "$PHASE" in A|B|C) ;; *) echo "[FAIL] PHASE must be A | B | C (got '$PHASE')"; exit 1 ;; esac
FORCE="${FORCE:-0}"

SCENE=s_curve; GEO=s_curve_hg; SEED=6; NTRIALS=10; RECORD=none
PLANS=logs/UAV_MIX/uav-s_curve/plans
EVAL_SH=Slurm_Codes/sbatch/uav_mix/eval_mix_uav.sh
SAFE_EPS_MODE=scaled; SAFE_EPS_FRAC=1e-3

case "$PHASE" in A) DEF_TAG=p23scgrid ;; B) DEF_TAG=p23scproj ;; C) DEF_TAG=p23scmjpc ;; esac
TAG="${TAG:-$DEF_TAG}"
case "$TAG" in ""|*[!A-Za-z0-9._-]*) echo "[FAIL] TAG='$TAG': letters, digits, '.', '_', '-' only (the eval rewrites anything else)"; exit 1 ;; esac
case "$TAG" in
    u7hg|u18sc|u6unet_ae02|u19mjpc|p23sc|p23cv3t|p23cv3ah|p23uavpv2live)
        echo "[FAIL] TAG='$TAG' is an existing tag; R44 writes under its own marker, never into an old one"; exit 1 ;;
esac
case "$TAG" in p23sc?*) ;; *) echo "[WARN] TAG='$TAG' does not start with p23sc (the R44 DA reads p23sc*)" ;; esac

# ── cells ─────────────────────────────────────────────────────────────────────
CELL_IDS=(); declare -A C_ENG C_K C_VAR C_CTRL
add_cell() { CELL_IDS+=("$1"); C_ENG[$1]="$2"; C_K[$1]="$3"; C_VAR[$1]="$4"; C_CTRL[$1]="$5"; }
PS_R=dpcc-r-tightened;         PS_C=dpcc-c-tightened;         PS_T=dpcc-t-tightened
EP_R=hardflow_new-r-tightened; EP_C=hardflow_new-c-tightened; EP_T=hardflow_new-t-tightened

if [ "$PHASE" = A ]; then
    add_cell A1  mf        1  diffuser pid_stopgo
    add_cell A2  mf        2  diffuser pid_stopgo
    add_cell A4  af        1  diffuser pid_stopgo
    add_cell A5  af        2  diffuser pid_stopgo
    add_cell A7  fm        1  diffuser pid_stopgo
    add_cell A8  fm        2  diffuser pid_stopgo
    add_cell A3  mf        20 diffuser pid_stopgo
    add_cell A6  af        20 diffuser pid_stopgo
    add_cell A9  fm        20 diffuser pid_stopgo
    add_cell A10 diffusion 20 diffuser pid_stopgo
else
    E="${SC_ENGINE:-}"; K="${SC_K:-}"
    if [ -z "$E" ] || [ -z "$K" ]; then
        echo "[GATE] Phase $PHASE runs only on the model and budget the author picked from Phase A (spec §2)."
        echo "       Set SC_ENGINE=<mf|af|fm|diffusion> SC_K=<1|2|20>$([ "$PHASE" = C ] && echo ' SC_RULE=dpcc-<r|c|t>-tightened')."
        exit 1
    fi
    case "$E" in mf|af|fm|diffusion) ;; *) echo "[FAIL] SC_ENGINE='$E' must be mf | af | fm | diffusion"; exit 1 ;; esac
    case "$K" in 1|2|20) ;; *) echo "[FAIL] SC_K='$K': the R44 grid is K in {1, 2, 20} (no K = 5 or 10)"; exit 1 ;; esac
    if [ "$E" = diffusion ] && [ "$K" != 20 ]; then echo "[FAIL] diffusion runs at its training budget K = 20 only"; exit 1; fi
    if [ "$PHASE" = B ]; then
        if [ "$E" = diffusion ]; then
            add_cell B0 "$E" "$K" diffuser pid_stopgo
            add_cell Br "$E" "$K" "$PS_R" pid_stopgo
            add_cell Bc "$E" "$K" "$PS_C" pid_stopgo
            add_cell Bt "$E" "$K" "$PS_T" pid_stopgo
        elif [ "$K" -ge 3 ]; then
            add_cell B0 "$E" "$K" diffuser pid_stopgo
            add_cell Br "$E" "$K" "${PS_R},${EP_R}" pid_stopgo
            add_cell Bc "$E" "$K" "${PS_C},${EP_C}" pid_stopgo
            add_cell Bt "$E" "$K" "${PS_T},${EP_T}" pid_stopgo
        else
            add_cell B1 "$E" "$K" "diffuser,${PS_R},${PS_C},${PS_T}" pid_stopgo
        fi
    else
        R="${SC_RULE:-}"
        case "$R" in
            "$PS_R"|"$PS_C"|"$PS_T") ;;
            *) echo "[GATE] SC_RULE='$R' must be $PS_R | $PS_C | $PS_T (Phase B's per-step rule with the most crossings)"; exit 1 ;;
        esac
        add_cell C0 "$E" "$K" diffuser mjpc
        add_cell C1 "$E" "$K" "$R" mjpc
    fi
fi

CELLS="${CELLS:-all}"
if [ "$CELLS" = required ]; then
    [ "$PHASE" = A ] || { echo "[FAIL] CELLS=required is a Phase A shortcut"; exit 1; }
    CELLS="A1 A3 A6 A7"
fi
SEL=()
if [ "$CELLS" = all ]; then
    SEL=("${CELL_IDS[@]}")
else
    for c in $CELLS; do
        [ -n "${C_ENG[$c]+x}" ] || { echo "[FAIL] CELLS names '$c'; phase $PHASE has: ${CELL_IDS[*]}"; exit 1; }
    done
    for c in "${CELL_IDS[@]}"; do case " $CELLS " in *" $c "*) SEL+=("$c") ;; esac; done
fi

# ── helpers ───────────────────────────────────────────────────────────────────
k_arg()    { if [ "$1" = diffusion ]; then echo ""; else echo "$2"; fi; }            # diffusion: plan block (K20)
ep_tok()   { if [ "$1" = af ]; then echo "_EPlatest"; else echo ""; fi; }
eval_dir() { echo "E${1}_K${2}_mpc4_${3}_T0.5$(ep_tok "$1")_${TAG}"; }               # engine K controller
job_name() { echo "${TAG}_${1}_${2}_K${3}"; }                                        # cell engine K
vdir()     { case "$1" in hardflow_new*) echo "hardflow_sls${1#hardflow_new}" ;; *) echo "$1" ;; esac; }   # slsqp label
pylist()   { local out="" x; for x in ${1//,/ }; do out="${out:+$out, }'$x'"; done; echo "[$out]"; }
train_id() {
    case "$1" in
        mf)        echo "H8_Dmodels.mf_diffusion.MeanFlowODE_9D_dp0.5_bbunet" ;;
        af)        echo "H8_Dmodels.af_diffusion.AlphaFlowODE_9D_as1_ae0.2_bbunet" ;;
        fm)        echo "H8_Dmodels.diffusion.FlowMatchingODE_9D" ;;
        diffusion) echo "H8_Dmodels.ddpm_diffusion.GaussianDiffusion_9D_K20" ;;
    esac
}
results_json() {   # engine K controller variant -> results.json path(s) under the marker
    compgen -G "${PLANS}/mix_uav_${1}/*/$(eval_dir "$1" "$2" "$3")/${SEED}/${GEO}_*/$(vdir "$4")/results.json" || true
}
queued() {         # job name -> "<id> <state> <time>" if it is in squeue
    command -v squeue >/dev/null 2>&1 || return 0
    squeue -h -u "${USER:-$(id -un)}" -n "$1" -o "%i %T %M" 2>/dev/null | head -1 || true
}
cell_line() {
    local c="$1"
    printf '  %-4s %-9s K=%-3s %-54s job %s\n' "$c" "${C_ENG[$c]}" "${C_K[$c]}" "${C_VAR[$c]}" \
        "$(job_name "$c" "${C_ENG[$c]}" "${C_K[$c]}")"
}

echo "[ ok ] repo $REPO   git $(git rev-parse --short HEAD 2>/dev/null || echo '?')   mode=$MODE phase=$PHASE tag=$TAG cells=[${SEL[*]}]"

# ═══ export ═══════════════════════════════════════════════════════════════════
if [ "$MODE" = export ]; then
    STAMP=$(date +%Y%m%d_%H%M%S); OUT="export_tmp/R44_${TAG}_${STAMP}.tar.gz"; mkdir -p export_tmp
    LIST="$(mktemp)"
    { find "$PLANS" -mindepth 3 -maxdepth 3 -type d -name "E*_${TAG}" 2>/dev/null || true; } | sort >> "$LIST"
    N_RES=$(wc -l < "$LIST")
    { find Slurm_Codes/logs -maxdepth 2 -type f \( -name "*_${TAG}_*.log" -o -name "R44_${TAG}_jobids.tsv" \) 2>/dev/null || true; } \
        | sort >> "$LIST"
    { find Data_Analysis/analysis_results -maxdepth 2 -type f -name run_config.csv -path "*batch_uav_*" 2>/dev/null || true; } \
        | while read -r f; do if grep -q "_${TAG}" "$f"; then dirname "$f"; fi; done >> "$LIST" || true
    echo "[ export ] marker ${TAG}: ${N_RES} result folder(s), $(($(wc -l < "$LIST") - N_RES)) log/ledger/DA item(s):"
    sed 's/^/   /' "$LIST"
    if [ "$N_RES" -eq 0 ]; then echo "[ export ] nothing carries the marker '${TAG}' yet — nothing written"; rm -f "$LIST"; exit 1; fi
    tar -czf "$OUT" -T "$LIST"; rm -f "$LIST"
    echo "[ export ] wrote $OUT ($(du -h "$OUT" | cut -f1)): $(tar -tzf "$OUT" | grep -c '/results\.json$') results.json," \
         "$(tar -tzf "$OUT" | grep -c '\.log$') job log(s)"
    echo "[ export ] laptop:  scp <cluster>:~/FMPCC/FM-PCC/$OUT temp/<dd-mm>/   then   tar -xzf $(basename "$OUT")   (tell Claude the folder)"
    exit 0
fi

# ═══ status ═══════════════════════════════════════════════════════════════════
if [ "$MODE" = status ]; then
    HAVE_PY=0; command -v python3 >/dev/null 2>&1 && HAVE_PY=1
    preview() {
        if [ "$HAVE_PY" != 1 ]; then grep -o '"n_trials": *[0-9]*' "$1" | head -1 | sed 's/^/      /'; return 0; fi
        python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); R = d.get('rollouts') or []; s = d.get('summary') or {}
n = len(R)
if not n:
    print('      (results.json has no rollouts)'); sys.exit(0)
g = lambda r, a, b, dflt=None: (r.get(a) or {}).get(b, dflt)
succ = sum(bool(g(r, 'success', 'relaxed')) for r in R)
sc   = sum(bool(g(r, 'success', 'relaxed_and_constraints')) for r in R)
ab   = sum(bool(g(r, 'divergence', 'aborted')) for r in R)
dist = sum(float(g(r, 'goal', 'dist', float('nan'))) for r in R) / n
ms   = sum(float(g(r, 'timing', 'total_ms_mean', float('nan'))) for r in R) / n
trip = (s.get('projection_health') or {}).get('n_tripped_trials', '?')
warn = '' if n == 10 else f'   <-- n={n}, expected 10'
print(f'      n={n}  success={succ}/{n}  S&C={sc}/{n}  distance={dist:.3f} m  aborted={ab}/{n}  '
      f'ms/step={ms:.1f}  cb_tripped={trip}{warn}')
PY
    }
    N_DONE=0; N_RUN=0; N_NONE=0; N_BAD=0
    for c in "${SEL[@]}"; do
        e="${C_ENG[$c]}"; k="${C_K[$c]}"; v="${C_VAR[$c]}"; ctrl="${C_CTRL[$c]}"; name="$(job_name "$c" "$e" "$k")"
        echo; echo "── $c  $e K=$k  [$v]  job $name"
        q="$(queued "$name")"; [ -n "$q" ] && echo "   squeue: $q"
        log="$( { find Slurm_Codes/logs -maxdepth 2 -type f -name "*_${name}_[0-9]*.log" 2>/dev/null || true; } | sort | tail -1)"
        bad=0
        if [ -n "$log" ]; then
            echo "   log: $log"
            lc()  { if grep -qE -- "$2" "$log"; then echo "     ok  $1"; else echo "     XX  $1"; bad=1; fi; }
            lcF() { if grep -qF -- "$2" "$log"; then echo "     ok  $1"; else echo "     XX  $1"; bad=1; fi; }
            kexp="$k"; [ "$e" = diffusion ] && kexp="<plan block>"
            lcF "tag ${TAG}, SAFE_EPS ${SAFE_EPS_MODE}/${SAFE_EPS_FRAC}" "SAFE_EPS_MODE=${SAFE_EPS_MODE}  SAFE_EPS_FRAC=${SAFE_EPS_FRAC}  EVAL_TAG=${TAG}"
            lc  "engine ${e}, scene ${SCENE}, seed ${SEED}, n ${NTRIALS}, K ${kexp}" \
                "^ENGINE: ${e} +SCENE: ${SCENE} +SEEDS: ${SEED} +N_TRIALS: ${NTRIALS} +K: ${kexp}\$"
            lcF "geometry ${GEO} only" "[ U11 ] geo variants = ${GEO}"
            lcF "variants exactly $(pylist "$v")" "variants=$(pylist "$v")"
            lcF "controller ${ctrl}" "controller='${ctrl}' -> conda env"
            if [ "$e" = af ]; then
                lcF "CI-MeanFM U-Net" "[ U6 ] af bone      = unet"
                lcF "alpha_end 0.2"   "[ U6 ] af_alpha_end = 0.2"
                lcF "checkpoint latest" "[ U6 ] checkpoint   = latest"
            else
                lcF "checkpoint best (as u7hg)" "[ U6 ] checkpoint   = best"
            fi
            ck="$(grep -m1 -o 'checkpoint = state[^)]*)' "$log" || true)"
            echo "     ..  ${ck:-checkpoint line not printed yet}   (u7hg/u18sc: mf best 95000 · fm best 91000 · diffusion best 91000 · af latest 100000)"
            case "$v" in *hardflow*)
                if grep -qE "\[hardflow\]\[BLOCKED\]|DEGENERATE" "$log"; then echo "     XX  endpoint arm BLOCKED/DEGENERATE: not a HardFlow row"; bad=1
                else echo "     ok  endpoint arm ran (no BLOCKED / DEGENERATE)"; fi ;;
            esac
            if grep -qF "Job completed successfully" "$log"; then echo "     ok  job completed"
            elif grep -qE "DUE TO TIME LIMIT|CANCELLED|Traceback|\[ ERROR \]" "$log"; then echo "     XX  job died: $(grep -m1 -E 'DUE TO TIME LIMIT|CANCELLED|Traceback|\[ ERROR \]' "$log")"; bad=1
            else echo "     ..  still running (last: $(grep -E 'trial [0-9]+/[0-9]+ done' "$log" | tail -1 | sed 's/^\[ eval \] //'))"; fi
        else
            echo "   log: none yet"
        fi
        n_ok=0; n_v=0
        for vv in ${v//,/ }; do
            n_v=$((n_v + 1))
            rj="$(results_json "$e" "$k" "$ctrl" "$vv" | head -1)"
            if [ -z "$rj" ]; then echo "   $(vdir "$vv"): no results.json yet"; continue; fi
            echo "   $(vdir "$vv"): $rj"; preview "$rj"
            if grep -qE '"n_trials": *10[,}[:space:]]' "$rj"; then n_ok=$((n_ok + 1)); fi
        done
        if [ "$bad" -eq 1 ]; then N_BAD=$((N_BAD + 1))
        elif [ "$n_ok" -eq "$n_v" ]; then N_DONE=$((N_DONE + 1))
        elif [ -n "$q$log" ]; then N_RUN=$((N_RUN + 1))
        else N_NONE=$((N_NONE + 1)); fi
    done
    echo; echo "summary (${TAG}): ${N_DONE} complete · ${N_RUN} queued/running · ${N_BAD} with a failed check · ${N_NONE} not submitted"
    [ "$N_DONE" -eq "${#SEL[@]}" ] && echo "all ${#SEL[@]} cell(s) complete — next:  bash $0 export"
    exit 0
fi

# ═══ plan / submit: pre-flight ════════════════════════════════════════════════
fail=0
for f in "$EVAL_SH" mix_uav_test/eval_mix_uav.py config/uav_mix.py config/uav_projection.yaml; do
    [ -f "$f" ] || { echo "[FAIL] $f missing"; fail=1; }
done
grep -qE "^\s*- name: ${GEO}\s*$" config/uav_projection.yaml \
    || { echo "[FAIL] geometry '${GEO}' missing from config/uav_projection.yaml"; fail=1; }
grep -qE "^diffusion_timestep_threshold: 0.5\b" config/uav_projection.yaml \
    || { echo "[FAIL] diffusion_timestep_threshold is not 0.5 (folder token T0.5; nine guiding steps at K20)"; fail=1; }
CTRL_DEFAULT="$(grep -m1 "'controller':" config/uav_mix.py | sed -E "s/.*'controller':[[:space:]]*'([^']*)'.*/\1/")"
[ "$CTRL_DEFAULT" = pid_stopgo ] \
    || { echo "[FAIL] config/uav_mix.py default controller is '$CTRL_DEFAULT'; R44 A/B fly pid_stopgo"; fail=1; }
grep -q "'flow_steps_v3': 20," config/uav_mix.py \
    || { echo "[FAIL] plan-block K is not 20 (it labels the diffusion folder K20)"; fail=1; }
for h in UAV_MIX_VARIANTS UAV_MIX_GEO_VARIANTS FMPCC_UAV_EVAL_TAG UAV_MIX_CONTROLLER; do
    grep -q "$h" mix_uav_test/eval_mix_uav.py || { echo "[FAIL] eval_mix_uav.py does not read $h"; fail=1; }
done
grep -q 'MUJOCO_EGL_DEVICE_ID="$ALLOCATED_GPU"' "$EVAL_SH" || { echo "[FAIL] $EVAL_SH lost its GPU/EGL isolation block"; fail=1; }
if [ "$PHASE" = B ]; then
    grep -q "hardflow_guard" mix_uav_test/eval_mix_uav.py || { echo "[FAIL] eval_mix_uav.py lacks the HardFlow degeneracy guard"; fail=1; }
    for v in "'hardflow_new-r'" "'hardflow_new-c'" "'hardflow_new-t'"; do
        grep -q "$v" config/uav_mix.py || { echo "[FAIL] config/uav_mix.py does not register $v"; fail=1; }
    done
fi
if [ "$PHASE" = C ] && [ ! -d "$HOME/miniconda3/envs/FMPCC_mjx" ]; then
    if [ "$MODE" = submit ]; then echo "[FAIL] conda env FMPCC_mjx not in ~/miniconda3/envs (UAV_MIX_CONTROLLER=mjpc needs it)"; fail=1
    else echo "[WARN] conda env FMPCC_mjx not found here; Phase C needs it on the cluster"; fi
fi
if [ "$MODE" = submit ] && ! command -v sbatch >/dev/null 2>&1; then echo "[FAIL] no sbatch on this machine"; fail=1; fi
[ "$fail" -eq 0 ] || { echo "ABORT — pull first / fix the above."; exit 1; }
echo "[ ok ] pre-flight passed"

echo; echo "checkpoints (seed ${SEED}):"
declare -A HAVE
ENGS=""
for c in "${SEL[@]}"; do case " $ENGS " in *" ${C_ENG[$c]} "*) ;; *) ENGS="$ENGS ${C_ENG[$c]}" ;; esac; done
for e in $ENGS; do
    exact="logs/UAV_MIX/uav-s_curve/mix_uav_${e}/$(train_id "$e")/${SEED}"
    if [ -d "$exact" ]; then HAVE[$e]=1; echo "  [ ok ] $e  $exact"; continue; fi
    pat="logs/UAV_MIX/uav-s_curve/mix_uav_${e}/*/${SEED}"; [ "$e" = af ] && pat="logs/UAV_MIX/uav-s_curve/mix_uav_af/*ae0.2*bbunet*/${SEED}"
    alt="$(compgen -G "$pat" | head -3 | tr '\n' ' ' || true)"
    if [ -n "$alt" ]; then HAVE[$e]=1; echo "  [warn] $e: $exact absent; found ${alt}— the eval resolves its own path, read the job log's load line"
    else HAVE[$e]=0; echo "  [MISS] $e: nothing under logs/UAV_MIX/uav-s_curve/mix_uav_${e}/*/${SEED} — its cells are SKIPPED"; fi
done

N_EXIST=$( { find "$PLANS" -mindepth 3 -maxdepth 3 -type d -name "E*_${TAG}" 2>/dev/null || true; } | wc -l)
echo; echo "marker '${TAG}': ${N_EXIST} result folder(s) already carry it$([ "$N_EXIST" -gt 0 ] && echo ' — cells with results.json are skipped unless FORCE=1')"

UNSET=( -u UAV_MIX_BONE_AF -u UAV_MIX_AF_ALPHA_END -u UAV_MIX_EPOCH -u UAV_MIX_CONTROLLER -u UAV_MIX_HF_OFF
        -u UAV_MIX_FLOW_STEPS -u UAV_MIX_TRAJ_GIF -u UAV_MIX_GIF_RES -u UAV_EVAL_HOURS
        -u FMPCC_HF_ALLOW_DEGENERATE -u FMPCC_HF_MIN_GENUINE -u HFFM_ACT_THRESHOLD -u FMPCC_HF_NLP_BACKEND
        -u FMPCC_UAV_DIVERGENCE_ABORT -u FMPCC_UAV_DIV_SPEED_MS -u FMPCC_UAV_DIV_SLACK_M -u FMPCC_UAV_DIV_MAP_Z_M
        -u FMPCC_UAV_DIV_MAP_XY_M -u FMPCC_PROJ_SOLVE_BACKSTOP_S -u FMPCC_PROJ_SLOW_MS -u FMPCC_PROJ_CB_WINDOW
        -u FMPCC_PROJ_CB_TRIP_FRAC -u FMPCC_PROJ_CB_COOLDOWN -u FMPCC_GEO_SLACK_PROBE_M -u FMPCC_TQDM
        -u SBATCH_DEPENDENCY )
BASE_ENV=( FMPCC_UAV_EVAL_TAG="$TAG" UAV_MIX_GEO_VARIANTS="$GEO"
           FMPCC_SAFE_EPS_MODE="$SAFE_EPS_MODE" FMPCC_SAFE_EPS_FRAC="$SAFE_EPS_FRAC" )

submit_cell() {   # cell -> prints the job id
    local c="$1" e="${C_ENG[$1]}" k="${C_K[$1]}" v="${C_VAR[$1]}" ctrl="${C_CTRL[$1]}"
    local name; name="$(job_name "$c" "$e" "$k")"
    local extra=()
    [ "$e" = af ] && extra+=( UAV_MIX_BONE_AF=unet UAV_MIX_AF_ALPHA_END=0.2 UAV_MIX_EPOCH=latest )
    [ "$ctrl" = mjpc ] && extra+=( UAV_MIX_CONTROLLER=mjpc )
    local DATE TIME LOG_DIR ID
    DATE=$(date +%Y-%m-%d); TIME=$(date +%H_%M_%S); LOG_DIR="Slurm_Codes/logs/$DATE"; mkdir -p "$LOG_DIR"
    ID=$(env "${UNSET[@]}" "${BASE_ENV[@]}" UAV_MIX_VARIANTS="$v" ${extra[@]+"${extra[@]}"} \
         sbatch --parsable --job-name="$name" --time=24:00:00 \
             --output="$LOG_DIR/${TIME}_%x_%j.log" --error="$LOG_DIR/${TIME}_%x_%j.log" \
             --export=ALL,SUBMIT_TIME="$TIME",SUBMIT_DATE="$DATE" \
             "$EVAL_SH" "$e" "$SCENE" "$SEED" "$NTRIALS" fm_only "$RECORD" "$(k_arg "$e" "$k")") \
        || { echo "       sbatch FAILED for $name"; return 1; }
    ID="${ID%%;*}"
    printf '%s\t%s\t%s\t%s\tK%s\t%s\t%s\t%s\n' "$ID" "$TAG" "$c" "$e" "$k" "$v" "$name" "$(date '+%F %T')" \
        >> "$LOG_DIR/R44_${TAG}_jobids.tsv"
    echo "       -> job ${ID}   log $LOG_DIR/${TIME}_${name}_${ID}.log"
}

echo; echo "cells (phase ${PHASE}, ${MODE}):"
N_SUB=0; N_SKIP=0
for c in "${SEL[@]}"; do
    e="${C_ENG[$c]}"; k="${C_K[$c]}"; v="${C_VAR[$c]}"; ctrl="${C_CTRL[$c]}"
    cell_line "$c"
    echo "       -> ${PLANS}/mix_uav_${e}/$(train_id "$e")/$(eval_dir "$e" "$k" "$ctrl")/${SEED}/${GEO}_…/{$(for vv in ${v//,/ }; do printf '%s ' "$(vdir "$vv")"; done | sed 's/ $//')}"
    if [ "${HAVE[$e]:-0}" != 1 ]; then echo "       SKIP: no checkpoint for $e here"; N_SKIP=$((N_SKIP + 1)); continue; fi
    q="$(queued "$(job_name "$c" "$e" "$k")")"
    if [ -n "$q" ]; then echo "       SKIP: already in squeue ($q)"; N_SKIP=$((N_SKIP + 1)); continue; fi
    n_have=0; n_v=0
    for vv in ${v//,/ }; do n_v=$((n_v + 1)); [ -n "$(results_json "$e" "$k" "$ctrl" "$vv")" ] && n_have=$((n_have + 1)); done
    if [ "$n_have" -gt 0 ] && [ "$FORCE" != 1 ]; then
        echo "       SKIP: ${n_have}/${n_v} results.json already under ${TAG} (FORCE=1 re-flies the cell and overwrites them)"
        N_SKIP=$((N_SKIP + 1)); continue
    fi
    N_SUB=$((N_SUB + 1))
    [ "$MODE" = submit ] && submit_cell "$c"
done

echo
if [ "$MODE" = plan ]; then
    echo "PLAN only — ${N_SUB} job(s) would be submitted, ${N_SKIP} skipped. Nothing was submitted."
    echo "Run:  $([ "$PHASE" != A ] && echo "PHASE=$PHASE SC_ENGINE=${SC_ENGINE:-} SC_K=${SC_K:-}$([ "$PHASE" = C ] && echo " SC_RULE=${SC_RULE:-}") ")bash $0 submit"
    exit 0
fi
cat <<NOTE
Submitted ${N_SUB} job(s) under the marker ${TAG} (${N_SKIP} skipped). Ledger: Slurm_Codes/logs/$(date +%Y-%m-%d)/R44_${TAG}_jobids.tsv
  squeue -u \$USER -o "%.9i %.36j %.9T %.10M %R" | grep ${TAG}
  $([ "$PHASE" != A ] && echo "PHASE=$PHASE SC_ENGINE=${SC_ENGINE:-} SC_K=${SC_K:-}$([ "$PHASE" = C ] && echo " SC_RULE=${SC_RULE:-}") ")bash $0 status     # log checks + results preview per cell
  $([ "$PHASE" != A ] && echo "PHASE=$PHASE SC_ENGINE=${SC_ENGINE:-} SC_K=${SC_K:-}$([ "$PHASE" = C ] && echo " SC_RULE=${SC_RULE:-}") ")bash $0 export     # when every cell is complete: one tar.gz for the laptop
Record the job ids in SLURM_RUNBOOK_20260923_uav_scurve_R44.md §6.
NOTE
