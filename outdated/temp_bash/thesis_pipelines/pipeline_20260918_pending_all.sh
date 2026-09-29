#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 2026-09-18 — the PENDING wave: every confirmed-missing run of
#   logs_in_develop/Writing/Working_Space/data_status/PENDING_20260918_verified_data_audit.md
# that is runnable today, minus what the 2026-09-17 wave (jobs 25878/25879/25880)
# already owns (audit rows A1, A2 = ledger R8/R19/R6).
#
#   bash Slurm_Codes/temp_bash/pipeline_20260918_pending_all.sh            # PLAN (default): print every job, submit NOTHING
#   bash Slurm_Codes/temp_bash/pipeline_20260918_pending_all.sh submit     # SUBMIT the groups in WAVE
#
#   WAVE="A C D E F"  bash ... submit      # pick groups (default: A C D E F — the UAV block)
#   WAVE=all          bash ... submit      # A..H  (G/H also need ALIGN_OK=1)
#   SEEDS="6"           (default; seed policy 2026-09-16: UAV + aligning stay at seed 6)
#
# WAVE
#   A  R20  UAV-corridor · endpoint projection with random (-r) and cumulative-cost (-c)
#           selection, at K=3 and K=5, for fm / mf / af.  tag u17cv2 (pools with the paper run)
#   B  R20  UAV-corridor · endpoint at K=1.            🚫 NOT SUBMITTED — see "Degeneracy" below
#   C  R13  UAV-pillars  · fm and mf at K=1, per-step variants.        tag u7hg
#   D  R21  UAV-pillars  · endpoint projection at K=2 for fm / mf / af, run at A=1.0.
#           tag u7hga1 (its OWN tag: A differs from the K=5 rows, which are A=0.5)
#   E  R12  UAV-pillars  · diffusion baseline, the two per-step cells it lacks
#           (dpcc-r, dpcc-r-tightened).                                tag u7hg
#   F  R10  UAV-s-curve  · endpoint rows re-run after the switched-wall fix
#           (fm K20, mf K10, af K5).                                   tag u18sc
#   G  R2   D3IL-aligning · diffusion baseline re-run so the tightened geometry
#           (combined_5-tightened) is generated.          needs ALIGN_OK=1
#   H  R16  D3IL-aligning · budget ladder: fm K2, fm K10, af K10.      needs ALIGN_OK=1
#   I  R18  D3IL-avoiding · diffusion at the extended protocol (5 seeds x 20 episodes),
#           K=1 and K=10.   🚫 PHASE B — see "Phase B" below; never in the same wave as A–H.
#
# NOT RUNNABLE, and why (do not re-derive this next week)
#   · R22 endpoint projection for the DIFFUSION baseline on ANY quadrotor scene.
#     mix_uav/models/engine_registry.py sets supports_hardflow=False for the ddpm engine and
#     eval_mix_uav.py:631 DROPS every hardflow_* variant for it: endpoint projection needs a
#     velocity field, which the diffusion arm does not expose. This is a MODEL limit, not a
#     missing run. Only R22's per-step half is runnable — that is group E.
#   · A4 diffusion at K=2 on D3IL-avoiding. K is a TRAINING property for DPCC diffusion
#     (the checkpoint is literally H8_K2_...), and no K=2 checkpoint exists. It needs a
#     training job first; cluster disk was 7.9 GB free on 2026-09-17. Author decision.
#   · B3 / R3 aligning on held-out and on 50-60 contexts. n_contexts is read from
#     config/visual_aligning_eval.yaml ONLY (no env override, eval_mix_visual_aligning.py:2920),
#     so it needs a tracked config edit, not a driver knob.
#
# Degeneracy (HFK1c) — why B is not submitted and why D runs at A=1.0
#   HardFlow guidance lives in ACTIVE NON-TERMINAL ODE steps. At K=1 the only step IS the
#   terminal step, so there is no non-degenerate setting at ANY activation threshold: a K=1
#   "endpoint" row is sample-then-project, not HardFlow, and eval_mix_uav.py blocks it.
#   At K=2 the shipped A=0.5 floors step 0 out, but A=1.0 leaves 1 genuine guided step — so D
#   passes HFFM_ACT_THRESHOLD=1.0 and carries its own tag. Rows from A=1.0 must be reported as
#   A=1.0 rows; they are NOT interchangeable with the A=0.5 K=5 rows.
#   Override at your own risk: ALLOW_DEGENERATE_PROBE=1 adds group B, tagged u18cv2deg, with
#   FMPCC_HF_ALLOW_DEGENERATE=1. Those rows may never carry a HardFlow claim.
#
# Phase B (group I) — why it is not in the same wave
#   The extended protocol is `n_trials: 20` in config/projection_eval.yaml, which is read by
#   scripts/eval.py at JOB START, from the working tree, with no env override. The 2026-09-17
#   wave still has a queued job (25880, afterok:25879) that needs `n_trials: 2`, so flipping
#   the file now would silently corrupt it. Submit I only when 25878/25879/25880 are gone AND
#   the file says 20, then put it back to 2. The driver refuses otherwise.
#
# OWNERSHIP: this script submits and validates. It never downloads, copies or deletes results.
# Slurm_Codes/temp_bash/ is gitignored — copy this file to the remote by hand.
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

WAVE="${WAVE:-A C D E F}"
[ "$WAVE" = "all" ] && WAVE="A C D E F G H"
[ "${ALLOW_DEGENERATE_PROBE:-0}" = "1" ] && WAVE="$WAVE B"
SEEDS="${SEEDS:-6}"
UAV_NTRIALS="${UAV_NTRIALS:-}"        # empty -> config/uav_projection.yaml (n_trials: 10)
CORRIDOR_NTRIALS="${CORRIDOR_NTRIALS:-12}"   # 12 = 4 per route (L, C, R), as the u17cv2 paper run
RECORD="${RECORD:-none}"

want() { case " $WAVE " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ── pre-flight ───────────────────────────────────────────────────────────────
fail=0
for f in Slurm_Codes/sbatch/uav_mix/eval_k_sweep.sh \
         Slurm_Codes/sbatch/uav_mix/eval_mix_uav.sh \
         Slurm_Codes/sbatch/mix_visual_aligning/eval_mix_visual_aligning.sh \
         Slurm_Codes/sbatch/eval_dpcc_job.sh ; do
    [ -f "$f" ] || { echo "[FAIL] missing entrypoint $f"; fail=1; }
done
grep -q "_TOGGLES = ('-pdes'" mix_uav_test/eval_mix_uav.py || { echo "[FAIL] eval_mix_uav.py lacks the U16 composed-toggle allow-list"; fail=1; }
grep -q "def update_constraint_list" mix_uav/sampling/hardflow_projection.py || { echo "[FAIL] hardflow_projection.py lacks update_constraint_list (U16 fix 2 — the switched-wall fix group F depends on)"; fail=1; }
grep -q "HFFM_ACT_THRESHOLD" mix_uav_test/eval_mix_uav.py || { echo "[FAIL] eval_mix_uav.py has no HFFM_ACT_THRESHOLD override (group D needs A=1.0)"; fail=1; }
for g in corridor_v2_slide pillars_hg s_curve_hg; do
    grep -q "name: ${g}\b" config/uav_projection.yaml || { echo "[FAIL] geo '${g}' missing from config/uav_projection.yaml"; fail=1; }
done
grep -qE "^diffusion_timestep_threshold: 0.5\b" config/uav_projection.yaml || { echo "[FAIL] uav diffusion_timestep_threshold is not 0.5"; fail=1; }
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
af_env() { case "$1" in af) echo "UAV_MIX_BONE_AF=unet UAV_MIX_AF_ALPHA_END=0.2 UAV_MIX_EPOCH=latest" ;; *) echo "" ;; esac; }

uav_job() {  # $1=engine $2=scene $3=geo $4="K list" $5=variants(csv) $6=tag $7=ntrials $8..=extra env
    local e="$1" sc="$2" geo="$3" ks="$4" v="$5" tag="$6" n="$7"; shift 7
    # shellcheck disable=SC2046
    run "${e} ${sc}/${geo} K=[${ks}] tag=${tag} n=${n:-<yaml>} $*: ${v}" \
        env "${UAV_UNSET[@]}" UAV_EVAL_HOURS=24 FMPCC_SAFE_EPS_MODE=scaled \
            FMPCC_UAV_EVAL_TAG="$tag" UAV_MIX_GEO_VARIANTS="$geo" UAV_MIX_VARIANTS="$v" \
            $(af_env "$e") "$@" \
        ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/eval_k_sweep.sh \
            "$e" "$sc" "$SEEDS" "$ks" "$n" fm_only "$RECORD"
}

# ── variant sets ─────────────────────────────────────────────────────────────
# corridor (u17cv2 paper names: geometry on the setpoint, DPCC margin, action cap off)
C_HF_R=hardflow_new-r-bounds_free-pdes-tightened
C_HF_C=hardflow_new-c-bounds_free-pdes-tightened
# The eval refuses a HardFlow-only subset (it needs a non-HardFlow row at the same K to compare
# against). `dpcc-c-bounds_free-pdes` is chosen because it does NOT exist in the u17cv2 tree:
# any of the four published keys would re-run and OVERWRITE a paper cell. This adds one new,
# legitimate cell (untightened companion of the published dpcc-c) instead.
C_GUARD=dpcc-c-bounds_free-pdes
# pillars / s_curve (u7hg "honest geometry" names)
P_PERSTEP="diffuser,dpcc-r,dpcc-r-tightened,dpcc-c,dpcc-c-tightened,dpcc-t,dpcc-t-tightened,dpcc-r-geo_free,dpcc-c-geo_free,dpcc-t-geo_free"
P_ENDPOINT="dpcc-t,hardflow_new,hardflow_new-r,hardflow_new-c,hardflow_new-t"
P_DIFF_GAP="dpcc-r,dpcc-r-tightened"
S_ENDPOINT="diffuser,dpcc-t,hardflow_new,hardflow_new-r,hardflow_new-c,hardflow_new-t"

echo
echo "MODE=$MODE   WAVE=$WAVE   SEEDS='$SEEDS'   RECORD=$RECORD"
echo

if want A; then
    echo "### A · R20 — corridor endpoint -r / -c at K=3,5 (fm, mf, af), tag u17cv2"
    for e in fm mf af; do
        uav_job "$e" corridor corridor_v2_slide "3 5" "${C_GUARD},${C_HF_R},${C_HF_C}" \
                u17cv2 "$CORRIDOR_NTRIALS" FMPCC_SAFE_EPS_FRAC=1.0
    done
    echo
fi

if want B; then
    echo "### B · R20 — corridor endpoint at K=1 · DEGENERATE PROBE (opt-in), tag u18cv2deg"
    echo "        rows are sample-then-project, NOT HardFlow. Never label them HardFlow."
    for e in fm mf af; do
        uav_job "$e" corridor corridor_v2_slide "1" "${C_GUARD},${C_HF_R},${C_HF_C}" \
                u18cv2deg "$CORRIDOR_NTRIALS" FMPCC_SAFE_EPS_FRAC=1.0 FMPCC_HF_ALLOW_DEGENERATE=1
    done
    echo
fi

if want C; then
    echo "### C · R13 — pillars budget floor: fm and mf at K=1, per-step variants, tag u7hg"
    for e in fm mf; do
        uav_job "$e" pillars pillars_hg "1" "$P_PERSTEP" u7hg "$UAV_NTRIALS"
    done
    echo
fi

if want D; then
    echo "### D · R21 — pillars endpoint at K=2, A=1.0 (1 genuine guided step), tag u7hga1"
    for e in fm mf af; do
        uav_job "$e" pillars pillars_hg "2" "$P_ENDPOINT" u7hga1 "$UAV_NTRIALS" HFFM_ACT_THRESHOLD=1.0
    done
    echo
fi

if want E; then
    echo "### E · R12 — pillars diffusion baseline: the two per-step cells it lacks, tag u7hg"
    echo "        (K is a training property for diffusion: no K list, the plan block's K=20 runs)"
    run "diffusion pillars/pillars_hg K=[plan block 20] tag=u7hg: ${P_DIFF_GAP}" \
        env "${UAV_UNSET[@]}" UAV_EVAL_HOURS=24 FMPCC_SAFE_EPS_MODE=scaled \
            FMPCC_UAV_EVAL_TAG=u7hg UAV_MIX_GEO_VARIANTS=pillars_hg UAV_MIX_VARIANTS="$P_DIFF_GAP" \
        ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/eval_mix_uav.sh \
            diffusion pillars "$SEEDS" "$UAV_NTRIALS" fm_only "$RECORD" ""
    echo
fi

if want F; then
    echo "### F · R10 — s-curve endpoint rows re-run after the switched-wall fix, tag u18sc"
    uav_job fm s_curve s_curve_hg "20" "$S_ENDPOINT" u18sc "$UAV_NTRIALS"
    uav_job mf s_curve s_curve_hg "10" "$S_ENDPOINT" u18sc "$UAV_NTRIALS"
    uav_job af s_curve s_curve_hg "5"  "$S_ENDPOINT" u18sc "$UAV_NTRIALS"
    echo
fi

# ── D3IL-aligning ────────────────────────────────────────────────────────────
# 🔴 config/visual_aligning_eval.yaml says `n_contexts: 3` (unchanged since 2026-08-04), while
# the published alignment rows are TEN contexts. A run submitted now therefore produces rows
# that are NOT comparable with the ones in the draft unless that value is what the published
# runs used. Confirm the number first, then acknowledge with ALIGN_OK=1.
if want G || want H; then
    NCTX="$(grep -E '^n_contexts:' config/visual_aligning_eval.yaml | awk '{print $2}')"
    echo "### aligning pre-flight: config/visual_aligning_eval.yaml n_contexts = ${NCTX}"
    if [ "${ALIGN_OK:-0}" != "1" ]; then
        echo "[SKIP] groups G/H need ALIGN_OK=1 — confirm n_contexts matches the published runs first."
        WAVE="$(echo "$WAVE" | sed 's/[GH]//g')"
    fi
fi

if want G; then
    echo "### G · R2 — aligning diffusion baseline re-run so combined_5-tightened is generated"
    run "aligning diffusion seed=${SEEDS} (plan-block K, T0.5); tightened sibling auto-generated" \
        env -u MIX_PROJ_T -u MIX_EPOCH -u MIX_BONE -u MIX_FILM_MODE \
        ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/mix_visual_aligning/eval_mix_visual_aligning.sh \
            diffusion "$SEEDS" none
    echo
fi

if want H; then
    echo "### H · R16 — aligning budget ladder (T chosen so T*K matches the mf ladder: ~4 solves)"
    run "aligning fm  K=2  T=0.5" \
        env -u MIX_EPOCH -u MIX_BONE -u MIX_FILM_MODE MIX_PROJ_T=0.5 \
        ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/mix_visual_aligning/eval_mix_visual_aligning.sh \
            fm "$SEEDS" none 2
    run "aligning fm  K=10 T=0.4" \
        env -u MIX_EPOCH -u MIX_BONE -u MIX_FILM_MODE MIX_PROJ_T=0.4 \
        ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/mix_visual_aligning/eval_mix_visual_aligning.sh \
            fm "$SEEDS" none 10
    run "aligning af  K=10 T=0.4  (alpha_end 0.2, latest checkpoint)" \
        env -u MIX_BONE -u MIX_FILM_MODE MIX_PROJ_T=0.4 MIX_EPOCH=latest MIX_AF_ALPHA_END=0.2 \
        ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/mix_visual_aligning/eval_mix_visual_aligning.sh \
            af "$SEEDS" none 10
    echo
fi

# ── PHASE B · group I — D3IL-avoiding at the extended protocol ───────────────
if want I; then
    echo "### I · R18 — diffusion baseline at 5 seeds x 20 episodes, K=1 and K=10"
    bad=0
    grep -Eq '^n_trials: *20([[:space:]]|$)' config/projection_eval.yaml || {
        echo "[FAIL] config/projection_eval.yaml is not at n_trials: 20 — phase B is the EXTENDED protocol."; bad=1; }
    grep -Eq '^seeds: *\[6, *7, *8, *9, *10\]' config/projection_eval.yaml || {
        echo "[FAIL] config/projection_eval.yaml is not the five-seed protocol."; bad=1; }
    if squeue -u "$USER" -h -o '%i' 2>/dev/null | grep -qE '^(25878|25879|25880)$'; then
        echo "[FAIL] a 2026-09-17 job (25878/25879/25880) is still queued or running. It reads"
        echo "       n_trials from this same file at job start — finish that wave first."; bad=1
    fi
    for K in 1 10; do
        compgen -G "logs/avoiding-d3il/diffusion/H8_K${K}_Dmodels.GaussianDiffusion_aw10*" >/dev/null || {
            echo "[FAIL] no trained diffusion checkpoint for K=${K} (it is a TRAINING property)"; bad=1; }
    done
    [ "$bad" -eq 0 ] || { echo "ABORT — phase B pre-flight failed; nothing submitted for group I."; exit 1; }
    for K in 1 10; do
        run "avoiding diffusion K=${K} · 5 seeds x 20 episodes · tag _msg20trials" \
            env FMPCC_RUN_MSG=20trials \
            ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/eval_dpcc_job.sh --n_diffusion_steps "$K"
    done
    echo "  ⚠ put config/projection_eval.yaml back to n_trials: 2 once these two jobs have STARTED."
    echo
fi

echo "──────────────────────────────────────────────────────────────"
if [ "$MODE" = "plan" ]; then
    echo "PLAN ONLY — $N jobs would be submitted. Nothing was sent to Slurm."
    echo "Run again with:  bash $0 submit"
else
    echo "SUBMITTED $N driver jobs. Note: each eval_k_sweep.sh job fans out to ONE child job per K."
    echo "Copy the printed job IDs into the run map of"
    echo "  logs_in_develop/Writing/Working_Space/data_status/SLURM_RUNBOOK_20260918_pending_runs.md"
fi
echo "No download action was performed."
