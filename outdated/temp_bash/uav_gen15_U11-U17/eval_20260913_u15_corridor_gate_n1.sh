#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# U15 (rev2) — injection: corridor SLIDE halfspace with FMPCC_SAFE_EPS_FRAC=1.0
#
#   usage:  bash Slurm_Codes/temp_bash/eval_20260913_u15_corridor_gate_n1.sh
#
# rev2 (after job 25728): `corridor_gate_n1` is now a slide from the top wall — flush at
# (0.0, 0.45), descending 6.8 deg to (2.0, 0.212) — instead of U14's rising spike. Delete the
# remote `corridor_hggn_...` results of 25728 before re-running: same folder name.
# The env change vs U14 is still only FMPCC_SAFE_EPS_FRAC=1.0 (default 1e-3).
#
# rev2 also makes the eval write, per variant, into the result folder:
#   <variant>.png       now draws the halfspaces, the drone-centre limit, the drone body width
#                       and the scorer's violating steps (red)
#   diagnostics/rollout_<i>.gif   the MuJoCo overhead GIF (record=gif, 320 px), with the enforced
#                                 halfspaces painted in: orange wall + red drone-centre limit
#   (the matplotlib <variant>_traj.gif is OFF — UAV_MIX_TRAJ_GIF unset)
#
# SMALL ON PURPOSE (target < 5 min):
#   variants  diffuser (control) | dpcc-t-bounds_free (least-constrained PCC) | hardflow_new (HF)
#   K = 3     HardFlow runs no real math at K <= 2 (A=0.5), so K=3 is the smallest honest K
#   trials=2  homotopies[i % 3] -> trial 0 = L (never blocked, control), trial 1 = C (blocked x 1.16..2.0)
#
# PASS
#   1  diffuser             stays in its channel (U15 rev1 drifted 6-7 cm) — the setting is safe
#   2  dpcc-t-bounds_free   C slides under the drone-centre limit (y <= -0.10 by x = 2.0), collision_free
#   3  hardflow_new         same on C, and does not flip (rev1: both trials inverted)
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

GEO=corridor_gate_n1
VARIANTS=diffuser,dpcc-t-bounds_free,hardflow_new
KS="3"
NTRIALS=2
FRAC=1.0

grep -q "name: ${GEO}\b" config/uav_projection.yaml \
    || { echo "[FAIL] '${GEO}' not in config/uav_projection.yaml -- pull U15 first."; exit 1; }
grep -qE "^diffusion_timestep_threshold: 0.5\b" config/uav_projection.yaml \
    || { echo "[FAIL] diffusion_timestep_threshold is not 0.5 -- U14 ran at 0.5; restore it first."; exit 1; }
echo "[ ok ] geo       = ${GEO}"
echo "[ ok ] variants  = ${VARIANTS}"
echo "[ ok ] K = ${KS}   n_trials = ${NTRIALS}   FMPCC_SAFE_EPS_FRAC = ${FRAC}"
echo

# env -u clears anything this run must NOT inherit; the assignments override the rest.
env -u UAV_MIX_BONE_AF -u UAV_MIX_AF_ALPHA_END -u UAV_MIX_EPOCH \
    -u UAV_MIX_CONTROLLER -u UAV_MIX_HF_OFF -u FMPCC_HF_ALLOW_DEGENERATE -u UAV_MIX_TRAJ_GIF \
    UAV_EVAL_HOURS=24 \
    FMPCC_SAFE_EPS_MODE=scaled \
    FMPCC_SAFE_EPS_FRAC="${FRAC}" \
    FMPCC_UAV_EVAL_TAG=u7hg \
    UAV_MIX_GEO_VARIANTS="${GEO}" \
    UAV_MIX_VARIANTS="${VARIANTS}" \
    UAV_MIX_GIF_RES=320 \
    ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/uav_mix/eval_k_sweep.sh mf corridor "6" "${KS}" "${NTRIALS}" "fm_only" "gif"

cat <<'NOTE'

Submitted. When the CHILD log appears, confirm the setting actually reached it:

  grep -hE "fix_16|FIX_16|Fix_16 (DEGENERATE|projector)|geo variants for|E9 geo|n_trials=" \
      Slurm_Codes/logs/$(date +%F)/*uav_mix_eval*.log

  expect:  SAFE_EPS_FRAC=1.0
           Fix_16 DEGENERATE actions[1] ... eps=2.188e-02        <- NOT 2.2e-05
           action_bounds=auto -> lb=[ 1.24e-04 ≈-2.19e-02 ≈-2.19e-02] ...
           geo variants for 'corridor': ['corridor_gate_n1']   ... hs=3, obs=4
           n_trials=2
           results path containing  corridor_hggn_

  If eps still reads 2.2e-05 the env did not reach the job -- the result is void, stop there.

Then download the whole `corridor_hggn_...` result folder into temp/<ddmm>/ -- each variant folder
now holds <variant>.png (geometry + drone width) and diagnostics/rollout_<i>.gif (MuJoCo). Also grab the CHILD log:
it is the only place the eps line proves the setting reached the job.
NOTE
