#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Attach a Slurm dependency job that restores `diffusion_timestep_threshold` to
# 0.5 automatically, so a forgotten manual restore cannot leak full projection
# into later runs.
#
#   usage:  bash .../restore_threshold_guard.sh            # auto-detect the running eval
#           bash .../restore_threshold_guard.sh <jobid>    # guard a specific job
#
# WHY A DEPENDENCY AND NOT A TIMER. The yaml is read when a job STARTS, so the
# restore must not fire before the eval has loaded it. `afterany:<id>` fires once
# the eval TERMINATES -- guaranteed after the config was read, whatever the exit
# status (completed, failed, cancelled or timed out).
#
# The guard is a trivial CPU-only job (no GPU, 1 CPU, 5 min).
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

YAML="$REPO/config/uav_projection.yaml"
KEY=diffusion_timestep_threshold
CUR=$(grep -E "^${KEY}:" "$YAML" | head -1 | awk '{print $2}')
echo "[ ok ] ${KEY} currently = ${CUR}"
[ "$CUR" = "0.5" ] && { echo "[ ok ] already 0.5 -- nothing to guard."; exit 0; }

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    # the eval child is the uav_mix_eval job; fall back to any job of ours
    TARGET=$(squeue -u "$USER" -h -o "%i %j" | awk '$2=="uav_mix_eval"{print $1}' | tail -1)
    [ -z "$TARGET" ] && TARGET=$(squeue -u "$USER" -h -o "%i" | tail -1)
fi
[ -z "$TARGET" ] && { echo "[FAIL] no job of yours in the queue. Restore by hand:"; \
                      echo "       bash Slurm_Codes/temp_bash/eval_20260912_u13_v32_fullproj.sh restore"; exit 1; }
echo "[ ok ] guarding job ${TARGET}:"
squeue -j "$TARGET" -o "%.10i %.14j %.10M %.12T" 2>/dev/null | sed 's/^/        /'

LOG="$REPO/Slurm_Codes/logs/$(date +%F)/threshold_restore_guard.log"
mkdir -p "$(dirname "$LOG")"
GID=$(sbatch --parsable \
        --dependency=afterany:"${TARGET}" \
        --job-name=thr_restore --time=00:05:00 --cpus-per-task=1 --mem=1G \
        --partition=gpu-1-student --output="$LOG" \
        --wrap="cd '$REPO' && sed -i -E 's|^${KEY}: *[0-9.]+|${KEY}: 0.5|' '$YAML' && \
                echo \"[thr_restore] \$(date -u) ${KEY} -> \$(grep -E '^${KEY}:' '$YAML')\"")
echo "[ ok ] guard job ${GID} queued -- fires when ${TARGET} terminates (any exit status)"
echo
echo "  verify afterwards:  grep ${KEY} config/uav_projection.yaml"
echo "  guard log:          ${LOG}"
echo "  cancel the guard:   scancel ${GID}"
