#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 2026-09-19 — UAV-pillars re-evaluated with the obstacles ENLARGED at test time
#
#   Runbook  : logs_in_develop/Writing/Working_Space/data_status/
#              SLURM_RUNBOOK_20260919_pillars_enlarged.md
#   Diagnosis: .../PENDING_20260918_pillars_geometry_redesign.md
#   Changelog: logs_in_develop/Gen15/U17/CHANGELOG_20260918_pillars_enlarged.md
#
#   bash Slurm_Codes/temp_bash/eval_20260919_u17_pillars_xl.sh              # PLAN (default): print, submit NOTHING
#   bash Slurm_Codes/temp_bash/eval_20260919_u17_pillars_xl.sh submit       # SUBMIT the groups in WAVE
#
#   WAVE="V"          bash ... submit    # 🔴 THE VERIFY CELL — run this FIRST, alone (default)
#   WAVE="A B C D"    bash ... submit    # the full wave, once V has passed
#   WAVE=all          bash ... submit    # A B C D  (V is never in `all`; E/X are opt-in)
#   WAVE="E"          bash ... submit    # opt-in: endpoint at K=2 under A=1.0, own tag
#   WAVE="X"          bash ... submit    # opt-in: the xxl rung. DO NOT RUN IN THIS WAVE.
#
#   SEEDS="6"  (default — seed policy 2026-09-16: UAV stays at seed 6)
#   UAV_NTRIALS=""  (default — empty means config/uav_projection.yaml `n_trials: 10`)
#
# EVALUATION ONLY. No training job, no new checkpoints. The models are the ones already
# trained; only the constraint radius the projector enforces (and scores against) changes.
#
# ── WHAT THIS WAVE IS ────────────────────────────────────────────────────────
# `pillars_hg` enforces |y| >= 0.6+0.12+0.31 = 1.03 while the demonstrated routes fly at
# |y| = 1.11 — the plan is feasible BEFORE the projector touches it, so every projected cell
# measured how little of an already-correct plan a method disturbs. `pillars_xl` (radius 0.35,
# keep-out 0.66) puts the demonstrated route 0.15 m INSIDE the obstacle and closes the straight
# centre lane, leaving a 0.93 m free band at |y| in [1.26, 2.19]. Same construction as
# D3IL-avoiding: constraint introduced at test time, demonstrations do not satisfy it.
#
# 🔴 THE PILLARS ARE ENLARGED VIRTUALLY. scene_pillars.xml keeps r = 0.12 and is NOT touched.
# The drone flies through the extra 0.23 m in MuJoCo; it is scored as a constraint violation.
# `phys_safe` (MuJoCo contact truth) is radius-independent and stays a separate column.
#
# 🔴 EXPECT A FEASIBILITY WARNING AT JOB START AND DO NOT "FIX" IT.
#   `WARNING pillars homotopy=...: expert route violates the PLANNING constraint set ...`
# is now the POINT of the geometry. `_warn_expert_route_infeasibility` is print-only and never
# blocks a run (eval_mix_uav.py:913).
#
# ── TAGS ─────────────────────────────────────────────────────────────────────
#   u7xl     the wave. Must NOT collide with u7hg (the control condition, old geometry).
#   u7xlchk  the group-V verify cell — its own tag so a throwaway check can never pool
#            with the wave it is checking.
#   u7xla1   group E only: endpoint at K=2 needs A=1.0 to have one genuine guided step, and
#            A=1.0 rows are NOT interchangeable with the A=0.5 rows at K=5.
#   u7xxl    group X only.
# The geometry also lands in its own folder (`geo_tag_suffix: '_xl'`), so `_hg` and `_xl`
# results can never be pooled even by accident.
#
# ── DEGENERACY (HFK1c), and why the variant lists are split the way they are ──
# HardFlow guidance lives in ACTIVE NON-TERMINAL ODE steps. At K=1 the only step IS the
# terminal step; at K=2 the shipped A=0.5 floors step 0 out. eval_mix_uav.py DROPS the
# hardflow_* variants at those K and writes HF_DEGENERATE_SKIPPED.txt. So groups A and B carry
# per-step variants only — the endpoint arm is group C (K=5, A=0.5) and, opt-in, group E
# (K=2, A=1.0). The eval also REFUSES a HardFlow-only subset, which is why group C carries the
# `dpcc-t` pair as its non-HardFlow companion.
#
# ── WALL CLOCK, and why K=5 is three jobs and not one ────────────────────────
# The `pillars_hg` K=5 jobs (25318/25321) hit the 24 h cap with 5 of 17 variants done:
# measured `proj_ms` for `dpcc-c` is 63 ms at K=2 against 1751 ms at K=5, a 28x step. The
# enlarged constraint makes the solver work harder, not less — the plan is now infeasible, so
# SLSQP actually has to move it. So K=5 is split into DISJOINT variant subsets (B: 5 per-step,
# C: 6 endpoint+dpcc-t), one job each, at UAV_EVAL_HOURS=24. Disjoint matters: two concurrent
# jobs sharing a variant name would race on the same results folder.
#
# ── THE ELEVEN CONFIGURATIONS (the set the scene already uses) ────────────────
#   diffuser | dpcc-{r,c,t} plain and -tightened | hardflow_new{,-r,-c,-t}
# `*-geo_free` rows are not part of the thesis and are not requested here.
#
# OWNERSHIP: this script submits and validates. It never downloads, copies or deletes results.
# Slurm_Codes/temp_bash/ is GITIGNORED — copy this file to the remote by hand (scp), it will
# not arrive with a `git pull`.
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

WAVE="${WAVE:-V}"
[ "$WAVE" = "all" ] && WAVE="A B C D"
SEEDS="${SEEDS:-6}"
UAV_NTRIALS="${UAV_NTRIALS:-}"        # empty -> config/uav_projection.yaml (n_trials: 10)
RECORD="${RECORD:-none}"

want() { case " $WAVE " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ── pre-flight ───────────────────────────────────────────────────────────────
fail=0
for f in Slurm_Codes/sbatch/uav_mix/eval_k_sweep.sh \
         Slurm_Codes/sbatch/uav_mix/eval_mix_uav.sh ; do
    [ -f "$f" ] || { echo "[FAIL] missing entrypoint $f"; fail=1; }
done

# the new geometry must exist, and the OLD one must still be there (it is the control condition)
for g in pillars_xl pillars_hg; do
    grep -q "name: ${g}\b" config/uav_projection.yaml || { echo "[FAIL] geo '${g}' missing from config/uav_projection.yaml"; fail=1; }
done
want X && { grep -q "name: pillars_xxl\b" config/uav_projection.yaml || { echo "[FAIL] geo 'pillars_xxl' missing"; fail=1; }; }

# 🔴 the two invariants the whole experiment rests on, checked mechanically:
#   1. the enlargement is in the ENTRY's radius, never in the tightening knob
grep -qE "^enlarge_constraints: *0\.025\b" config/uav_projection.yaml || {
    echo "[FAIL] enlarge_constraints is not 0.025 — the enlargement must live in the geo entry's"
    echo "       radius, NOT in the tightening knob (it is a reported variable of the thesis)."; fail=1; }
#   2. the physical scene is untouched — the demonstrations must stay valid.
#      MJCF cylinders carry their radius in `size="<radius> <half-height>"`; all six must be 0.12.
PILLAR_XML=d3il/environments/d3il/models/mj/robot/quadrotor/scenes/scene_pillars.xml
if [ ! -f "$PILLAR_XML" ]; then
    echo "[FAIL] $PILLAR_XML not found — cannot prove the physical pillars are untouched."; fail=1
elif [ "$(grep -c 'name="pillar_[AB][123]".*size="0\.12 ' "$PILLAR_XML")" -ne 6 ]; then
    echo "[FAIL] scene_pillars.xml no longer has six r=0.12 cylinders. The MJCF pillars MUST stay"
    echo "       at 0.12: enlarging them invalidates the demonstrations and forces a retrain."
    echo "       The enlargement is VIRTUAL and lives in config/uav_projection.yaml only."; fail=1
fi
#   3. a scene's two geo entries must never be active in the same job (Fix_6 multi-match)
grep -qE '^active_geo_variants:.*pillars_xl' config/uav_projection.yaml && {
    echo "[FAIL] pillars_xl is in active_geo_variants. Leave that list alone — every job here"
    echo "       selects its geometry with UAV_MIX_GEO_VARIANTS (U11)."; fail=1; }
#   4. the scorer reads the ENTRY's radii (if this ever changes, every row reads collision-free)
grep -q "obstacle_constraints', \[\])  if 'obstacles'" mix_uav_test/eval_mix_uav.py || {
    echo "[FAIL] _exec_constraint_violations no longer reads config['obstacle_constraints'] —"
    echo "       the violation scorer may not be using the enlarged radius. STOP and check."; fail=1; }

[ "$fail" -eq 0 ] || { echo "ABORT — fix the pre-flight before submitting."; exit 1; }
echo "[ ok ] pre-flight passed"

FREE_KIB="$(df -Pk "$REPO" | awk 'NR==2 {print $4}')"
echo "[ disk ] $(df -h "$REPO" | awk 'NR==2 {print $4" free on "$6}')"
if [ -n "$FREE_KIB" ] && [ "$FREE_KIB" -lt $((2 * 1024 * 1024)) ]; then
    echo "[WARN] under 2 GiB free. Every job here is EVALUATION (no checkpoints written),"
    echo "       but rollout npz/plots still land on disk. Watch it."
fi

N=0
run() {  # $1 = label, $2.. = command
    local label="$1"; shift
    N=$((N + 1))
    printf '  %-3s %s\n' "$N" "$label"
    [ "$MODE" = "plan" ] && return 0
    "$@"
}

# Knobs every UAV job shares. UNSET kills anything inherited from the caller's shell, so a
# job's behaviour is provable from the driver alone (the U6 failure mode).
UAV_UNSET=( -u UAV_MIX_BONE_AF -u UAV_MIX_AF_ALPHA_END -u UAV_MIX_EPOCH -u UAV_MIX_CONTROLLER
            -u UAV_MIX_HF_OFF -u FMPCC_HF_ALLOW_DEGENERATE -u FMPCC_HF_MIN_GENUINE
            -u HFFM_ACT_THRESHOLD -u UAV_MIX_TRAJ_GIF -u UAV_MIX_VARIANTS -u UAV_MIX_GEO_VARIANTS )
# af arm: U-Net bone (parameter-matched to fm/mf at 4.0 M), alpha floored so the arm is really
# alpha-Flow and not a MeanFlow model, and 'latest' because 'best' would discard the model the
# floor produced (eval_k_sweep.sh, U6).
af_env() { case "$1" in af) echo "UAV_MIX_BONE_AF=unet UAV_MIX_AF_ALPHA_END=0.2 UAV_MIX_EPOCH=latest" ;; *) echo "" ;; esac; }

uav_job() {  # $1=engine $2=geo $3="K list" $4=variants(csv) $5=tag $6=ntrials $7..=extra env
    local e="$1" geo="$2" ks="$3" v="$4" tag="$5" n="$6"; shift 6
    # shellcheck disable=SC2046
    run "${e} pillars/${geo} K=[${ks}] tag=${tag} n=${n:-<yaml>} $*: ${v}" \
        env "${UAV_UNSET[@]}" UAV_EVAL_HOURS=24 FMPCC_SAFE_EPS_MODE=scaled \
            FMPCC_UAV_EVAL_TAG="$tag" UAV_MIX_GEO_VARIANTS="$geo" UAV_MIX_VARIANTS="$v" \
            $(af_env "$e") "$@" \
        ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/eval_k_sweep.sh \
            "$e" pillars "$SEEDS" "$ks" "$n" fm_only "$RECORD"
}

# ── variant sets ─────────────────────────────────────────────────────────────
# the eleven configurations, split into DISJOINT halves so two concurrent jobs at the same K
# can never write the same variant folder
P_PERSTEP="diffuser,dpcc-r,dpcc-r-tightened,dpcc-c,dpcc-c-tightened,dpcc-t,dpcc-t-tightened"
P_PS_A="diffuser,dpcc-r,dpcc-r-tightened,dpcc-c,dpcc-c-tightened"     # K=5 half 1 (5 cells)
P_PS_B="dpcc-t,dpcc-t-tightened,hardflow_new,hardflow_new-r,hardflow_new-c,hardflow_new-t"
                                                                      # K=5 half 2 (6 cells);
                                                                      # dpcc-t is also the
                                                                      # non-HardFlow companion
                                                                      # the eval requires
P_ENDPOINT="dpcc-t,hardflow_new,hardflow_new-r,hardflow_new-c,hardflow_new-t"   # group E only

echo
echo "MODE=$MODE   WAVE=$WAVE   SEEDS='$SEEDS'   RECORD=$RECORD"
echo

# ── V · THE VERIFY CELL — one job, run it FIRST and read it before the wave ──
if want V; then
    echo "### V · verify the enlarged radius actually reaches BOTH the projector and the scorer"
    echo "        ONE cell: mf, pillars_xl, seed ${SEEDS}, K=5, variant 'diffuser' (unprojected)."
    echo "        Tag u7xlchk — a throwaway, it must never pool with the wave."
    echo
    echo "        READ TWO NUMBERS IN results.json, and submit NOTHING until both hold:"
    echo "          1. S&C must drop WELL BELOW 0.90 (what mf/diffuser reads at pillars_hg)."
    echo "             Still 0.90 -> the enlarged radius is not reaching the projector."
    echo "          2. n_violations must be > 0."
    echo "             Still 0 -> the executed-violation check is scoring against the physical"
    echo "             0.12 pillars and EVERY row of the wave would read collision-free."
    echo "        By hand: the plan must keep |y| >= 0.6+0.35+0.31 = 1.26; the demonstrated"
    echo "        channels are at |y| = 1.11, i.e. 0.15 m inside the obstacle; free space to 2.19."
    echo "        The 'expert route violates the PLANNING constraint set' warning is EXPECTED."
    uav_job mf pillars_xl "5" "diffuser" u7xlchk "$UAV_NTRIALS"
    echo
fi

# ── A · per-step ladder at the low budgets ───────────────────────────────────
if want A; then
    echo "### A · per-step projection, K=1 and K=2, fm/mf/af — tag u7xl"
    echo "        (K=1 closes the two holes the old geometry never had: mf and fm at K=1.)"
    echo "        HardFlow is degenerate at K=1/2 under A=0.5 and is dropped by the eval —"
    echo "        that is why this group is per-step only. Endpoint at K=2 is group E."
    for e in fm mf af; do
        uav_job "$e" pillars_xl "1 2" "$P_PERSTEP" u7xl "$UAV_NTRIALS"
    done
    echo
fi

# ── B/C · K=5, split by variant subset so neither job walls at 24 h ──────────
if want B; then
    echo "### B · K=5, per-step half 1 (5 cells), fm/mf/af — tag u7xl"
    for e in fm mf af; do
        uav_job "$e" pillars_xl "5" "$P_PS_A" u7xl "$UAV_NTRIALS"
    done
    echo
fi

if want C; then
    echo "### C · K=5, endpoint + dpcc-t half (6 cells), fm/mf/af — tag u7xl"
    echo "        Disjoint from group B, so both may run concurrently at the same K."
    for e in fm mf af; do
        uav_job "$e" pillars_xl "5" "$P_PS_B" u7xl "$UAV_NTRIALS"
    done
    echo
fi

# ── D · the diffusion baseline ───────────────────────────────────────────────
if want D; then
    echo "### D · diffusion baseline, the full per-step set — tag u7xl"
    echo "        K is a TRAINING property for DPCC diffusion (the checkpoint is K20), so no K"
    echo "        list: the plan block's K=20 runs, and it is the baseline's only budget."
    echo "        Endpoint projection is unavailable to this arm by construction —"
    echo "        engine_registry sets supports_hardflow=False for ddpm (it needs a velocity"
    echo "        field). This group also closes the dpcc-r / dpcc-r-tightened gap the baseline"
    echo "        had on the old geometry."
    run "diffusion pillars/pillars_xl K=[plan block 20] tag=u7xl n=${UAV_NTRIALS:-<yaml>}: ${P_PERSTEP}" \
        env "${UAV_UNSET[@]}" UAV_EVAL_HOURS=24 FMPCC_SAFE_EPS_MODE=scaled \
            FMPCC_UAV_EVAL_TAG=u7xl UAV_MIX_GEO_VARIANTS=pillars_xl UAV_MIX_VARIANTS="$P_PERSTEP" \
        ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/eval_mix_uav.sh \
            diffusion pillars "$SEEDS" "$UAV_NTRIALS" fm_only "$RECORD" ""
    echo
fi

# ── E · OPT-IN — endpoint at K=2, which needs A=1.0 ──────────────────────────
if want E; then
    echo "### E · OPT-IN — endpoint projection at K=2 under A=1.0, fm/mf/af — tag u7xla1"
    echo "        At K=2 the shipped A=0.5 floors step 0 out; A=1.0 leaves ONE genuine guided"
    echo "        step. Rows from A=1.0 must be REPORTED as A=1.0 rows — they are not"
    echo "        interchangeable with the A=0.5 rows of group C, hence the separate tag."
    echo "        This is the 18-Sep group D re-run on the new geometry."
    for e in fm mf af; do
        uav_job "$e" pillars_xl "2" "$P_ENDPOINT" u7xla1 "$UAV_NTRIALS" HFFM_ACT_THRESHOLD=1.0
    done
    echo
fi

# ── X · OPT-IN — the second rung. NOT PART OF THIS WAVE ──────────────────────
if want X; then
    echo "### X · ⚠️  pillars_xxl (radius 0.55) — DO NOT RUN IN THE 19-09 WAVE."
    echo "        Run xl first and read its unprojected (diffuser) row. xxl exists only in case"
    echo "        xl turns out too easy. Free band shrinks to 0.73 m at |y| in [1.46, 2.19]."
    if [ "${XXL_OK:-0}" != "1" ]; then
        echo "[SKIP] group X needs XXL_OK=1 as well. Nothing submitted."
    else
        for e in fm mf af; do
            uav_job "$e" pillars_xxl "5" "$P_PS_A" u7xxl "$UAV_NTRIALS"
        done
    fi
    echo
fi

echo "──────────────────────────────────────────────────────────────"
if [ "$MODE" = "plan" ]; then
    echo "PLAN ONLY — $N driver jobs would be submitted. Nothing was sent to Slurm."
    echo "Run again with:  WAVE=\"$WAVE\" bash $0 submit"
else
    echo "SUBMITTED $N driver jobs. Each eval_k_sweep.sh driver fans out to ONE child job per K"
    echo "(group A is 2 children per driver; B, C, E are 1; D is a direct eval job)."
    echo
    echo "🔴 Copy the printed job IDs into the run map of"
    echo "   logs_in_develop/Writing/Working_Space/data_status/SLURM_RUNBOOK_20260919_pillars_enlarged.md"
fi
echo
echo "WHEN THE WAVE LANDS — what 'done' looks like (runbook §4):"
echo "  · every model-budget cell exists, for geometry pillars_xl, tag u7xl, seed ${SEEDS};"
echo "  · the UNPROJECTED (diffuser) rows show REAL FAILURE. If they do not, stop and raise the"
echo "    radius (pillars_xxl) rather than reporting the result — that is the whole point;"
echo "  · n_violations is non-zero wherever S&C is below 1;"
echo "  · the diffusion baseline has dpcc-r and dpcc-r-tightened this time."
echo "Then: DA_in_Paper/analysis/pillars_grid.py with GEO_PREFIX = 'pillars_xl', and"
echo "v3/withheld/20260918_uav_pillars_section.tex restored with every number recomputed."
echo "No download action was performed."
