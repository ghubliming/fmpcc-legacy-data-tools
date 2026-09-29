#!/bin/bash
# =============================================================================
# fetch_20260918_v3_figure_artefacts.sh
#
# Stage the artefacts the v3 thesis draft is still missing FIGURES for, into one
# small folder on the cluster, so they can be downloaded in a single archive.
#
#   Source ledger : logs_in_develop/Writing/Working_Space/data_status/
#                     PENDING_20260916_missing_data_and_analyses.md   (rows R5, D10)
#   Requests      : Data_Analysis/DA_in_Paper/plotting/
#                     REQUEST_20260917_trajectory_figures.md          -> groups F1..F4
#                     REQUEST_20260916_cluster_fm_plan_panels.md      -> group  F5
#   Run folders   : resolved against Data_Analysis/analysis_results_checkpoint/
#                     16_09_logs_tree.txt (capture of 2026-09-16, root
#                     /u/home/llim/FMPCC/FM-PCC/logs)
#
# THIS SCRIPT SUBMITS NOTHING AND DELETES NOTHING. It only reads logs/ and
# copies matched files into $STAGE. Run it on the login node of i6-gpu-1.
#
# Usage (from the repo root on the remote):
#   bash Slurm_Codes/temp_bash/fetch_20260918_v3_figure_artefacts.sh          # PLAN
#   bash Slurm_Codes/temp_bash/fetch_20260918_v3_figure_artefacts.sh stage    # copy
#   bash Slurm_Codes/temp_bash/fetch_20260918_v3_figure_artefacts.sh stage tar # copy + tar.gz
#
# Knobs:
#   REPO=...      repo root on the cluster        (default $HOME/FMPCC/FM-PCC)
#   STAGE=...     staging folder                  (default $REPO/export_tmp/v3_figs_20260918)
#   WAVE=...    subset of "F1 F2 F3 F4 F5"      (default all)
#   KEEP_GIF=1    also copy rollout .gif files    (default off - 35 GiB of the tree is .gif)
#   KEEP_LOG=1    also copy rollout_*.log files   (default off)
# =============================================================================

set -u -o pipefail

MODE="${1:-plan}"
TARIT="${2:-}"

REPO="${REPO:-$HOME/FMPCC/FM-PCC}"
LOGS="$REPO/logs"
STAGE="${STAGE:-$REPO/export_tmp/v3_figs_20260918}"
WAVE="${WAVE:-F1 F2 F3 F4 F5}"
KEEP_GIF="${KEEP_GIF:-0}"
KEEP_LOG="${KEEP_LOG:-0}"

MANIFEST="$STAGE/MANIFEST_20260918.txt"

if [[ ! -d "$LOGS" ]]; then
  echo "FATAL: no logs tree at $LOGS  (set REPO=...)" >&2
  exit 1
fi

# --- what counts as a wanted sibling file -----------------------------------
KEEP_PATTERNS=( '*.npz' 'results.json' 'run_provenance*.json' '*.png' )
[[ "$KEEP_GIF" == "1" ]] && KEEP_PATTERNS+=( '*.gif' )
[[ "$KEEP_LOG" == "1" ]] && KEEP_PATTERNS+=( '*.log' )

# =============================================================================
# The cells to fetch.
#
# Each CELL line is:
#   <group>|<label>|<run subtree under logs/>|<npz basenames, space separated>[|<path substring filter>]
#
# The optional 5th field keeps only leaves whose path contains that substring -
# used to pin a geometry when a run carries several.
#
# The npz basename IS the projection-variant name, and it sits in a leaf folder
# named "<variant>" or "<variant>_<geometry>", next to results.json and the
# variant .png. Matching the npz by exact name is therefore geometry-agnostic
# and never confuses e.g. hardflow_sls with hardflow_sls-r.
# =============================================================================

CELLS=()

# --- F1  fig:uav-scurve-paths -- s-curve under two controllers ---------------
#     companion of tab:uav-controller; 3 flights (mjpc) + 10 (pid_stopgo)
CELLS+=( "F1|s-curve MeanFM K10 mjpc|UAV_MIX/uav-s_curve/plans/mix_uav_mf/H8_Dmodels.mf_diffusion.MeanFlowODE_9D_dp0.5_bbunet/Emf_K10_mpc4_mjpc_T0.5_u7hg|diffuser" )
CELLS+=( "F1|s-curve MeanFM K10 pid_stopgo|UAV_MIX/uav-s_curve/plans/mix_uav_mf/H8_Dmodels.mf_diffusion.MeanFlowODE_9D_dp0.5_bbunet/Emf_K10_mpc4_pid_stopgo_T0.5_u7hg|diffuser" )

# --- F2  UAV-pillars flown paths, one panel per model ------------------------
#     tab:uav-pillars-best: hardflow_sls-r (MeanFM), hardflow_sls (FM),
#     dpcc-t-tightened (CI-MeanFM + diffusion); diffuser kept as the unprojected reference
CELLS+=( "F2|pillars MeanFM K5|UAV_MIX/uav-pillars/plans/mix_uav_mf/H8_Dmodels.mf_diffusion.MeanFlowODE_9D_dp0.5_bbunet/Emf_K5_mpc4_pid_stopgo_T0.5_u7hg|hardflow_sls-r dpcc-t-tightened diffuser" )
CELLS+=( "F2|pillars FM K5|UAV_MIX/uav-pillars/plans/mix_uav_fm/H8_Dmodels.diffusion.FlowMatchingODE_9D/Efm_K5_mpc4_pid_stopgo_T0.5_u7hg|hardflow_sls dpcc-t-tightened diffuser" )
CELLS+=( "F2|pillars CI-MeanFM K5|UAV_MIX/uav-pillars/plans/mix_uav_af/H8_Dmodels.af_diffusion.AlphaFlowODE_9D_as1_ae0.2_bbunet/Eaf_K5_mpc4_pid_stopgo_T0.5_EPlatest_u7hg|dpcc-t-tightened diffuser" )
#     the diffusion reference run - folder name resolved by glob, see RESOLVE below
CELLS+=( "F2|pillars diffusion K20|UAV_MIX/uav-pillars/plans/mix_uav_diffusion/H8_Dmodels.ddpm_diffusion.GaussianDiffusion_9D_K20/Ediffusion_K20_mpc4_pid_stopgo_T0.5*|dpcc-t-tightened diffuser" )

# --- F3  UAV-corridor flown paths through the slide --------------------------
#     tag u17cv2, variant dpcc-t-bounds_free-pdes-tightened, K1/K3/K5 per model
#     + the diffusion baseline at K20. 12 flights per cell (routes L/C/R x 4).
for K in 1 3 5; do
  CELLS+=( "F3|corridor MeanFM K$K|UAV_MIX/uav-corridor/plans/mix_uav_mf/H8_Dmodels.mf_diffusion.MeanFlowODE_9D_dp0.5_bbunet/Emf_K${K}_mpc4_pid_stopgo_T0.5_u17cv2|dpcc-t-bounds_free-pdes-tightened diffuser" )
  CELLS+=( "F3|corridor FM K$K|UAV_MIX/uav-corridor/plans/mix_uav_fm/H8_Dmodels.diffusion.FlowMatchingODE_9D/Efm_K${K}_mpc4_pid_stopgo_T0.5_u17cv2|dpcc-t-bounds_free-pdes-tightened diffuser" )
  CELLS+=( "F3|corridor CI-MeanFM K$K|UAV_MIX/uav-corridor/plans/mix_uav_af/H8_Dmodels.af_diffusion.AlphaFlowODE_9D_as1_ae0.2_bbunet/Eaf_K${K}_mpc4_pid_stopgo_T0.5_EPlatest_u17cv2|dpcc-t-bounds_free-pdes-tightened diffuser" )
done
CELLS+=( "F3|corridor diffusion K20|UAV_MIX/uav-corridor/plans/mix_uav_diffusion/H8_Dmodels.ddpm_diffusion.GaussianDiffusion_9D_K20/Ediffusion_K20_mpc4_pid_stopgo_T0.5_u17cv2|dpcc-t-bounds_free-pdes-tightened diffuser" )

# --- F4  D3IL-aligning box paths over the ten contexts -----------------------
#     tab:va-projection, geometry combined_5-tightened, variants dpcc-r and hardflow_sls-r.
#     ⚠️ On disk every variant carries a '_train_set' suffix: this run was evaluated with
#     --eval-on-train, and eval_mix_visual_aligning.py:3256 appends '_train_set' to the
#     VARIANT NAME itself (not just the results root) before the artefact label is resolved.
#     So the leaf is combined_5-tightened/dpcc-r_train_set/dpcc-r_train_set.npz. Confirmed
#     by the 2026-09-19 PLAN. Geometry stays a parent dir here, unlike the UAV scenes.
CELLS+=( "F4|aligning MeanFM K20|aligning-d3il-visual/plans/mix_visual_aligning_mf/H8_Dmix_visual_aligning.models.visual_mf_diffusion.VisualMeanFlow_a1.5_b1.0_aw1_VTrue_steps1000_bs64_filmv1_Emf_tslogit_normal/H8_K20_Meuler_T0.2_Dmix_visual_aligning.models.visual_mf_diffusion.VisualMeanFlow_VTrue_mpc4_filmv1_Emf|dpcc-r_train_set hardflow_sls-r_train_set diffuser_train_set|combined_5-tightened" )

# --- F5  fig:raw-plans -- the five missing plan-matrix panels ----------------
#     REQUEST_20260916 says these do NOT exist yet and need a cluster eval
#     (FMPCC_RUN_MSG=planpanel). Listed here so the fetch confirms presence or
#     absence rather than leaving it to memory; expect "MISSING" until that
#     eval has run. Wanted file is the seed-6 both-hard diffuser.png dashboard.
CELLS+=( "F5|plan panels FM planpanel|avoiding-d3il/plans/*/H8_Dmodels.diffusion.FlowMatchingODE_a1.5_b1.0_aw10/*planpanel*|diffuser" )

# =============================================================================
# Runner
# =============================================================================

echo "==============================================================================="
echo " fetch_20260918_v3_figure_artefacts   mode=$MODE   groups=[$WAVE]"
echo " repo   : $REPO"
echo " logs   : $LOGS"
echo " stage  : $STAGE"
echo " extras : KEEP_GIF=$KEEP_GIF  KEEP_LOG=$KEEP_LOG"
echo "==============================================================================="
echo

if [[ "$MODE" == "stage" ]]; then
  mkdir -p "$STAGE"
  : > "$MANIFEST"
  {
    echo "# staged $(date -u +%Y-%m-%dT%H:%M:%SZ)  host $(hostname)"
    echo "# source root: $LOGS"
    echo
  } >> "$MANIFEST"
fi

total_files=0
total_bytes=0
missing_cells=0
found_cells=0

want_group() {
  [[ " $WAVE " == *" $1 "* ]]
}

# build the find -name expression for the wanted sibling files
build_keep_expr() {
  KEEP_EXPR=( '(' )
  local first=1 p
  for p in "${KEEP_PATTERNS[@]}"; do
    if [[ $first -eq 1 ]]; then first=0; else KEEP_EXPR+=( '-o' ); fi
    KEEP_EXPR+=( -name "$p" )
  done
  KEEP_EXPR+=( ')' )
}
build_keep_expr

for cell in "${CELLS[@]}"; do
  IFS='|' read -r grp label subtree variants pathfilter <<< "$cell"
  pathfilter="${pathfilter:-}"
  want_group "$grp" || continue

  echo "-------------------------------------------------------------------------------"
  echo "[$grp] $label"
  echo "      $subtree"
  [[ -n "$pathfilter" ]] && echo "      geometry filter: *${pathfilter}*"

  # RESOLVE: the subtree may carry a glob; expand it against the real tree
  roots=()
  for r in $LOGS/$subtree; do
    [[ -d "$r" ]] && roots+=( "$r" )
  done

  if [[ ${#roots[@]} -eq 0 ]]; then
    echo "      !! MISSING - no such run folder on this cluster"
    missing_cells=$((missing_cells + 1))
    [[ "$MODE" == "stage" ]] && echo "MISSING  [$grp] $label  ($subtree)" >> "$MANIFEST"
    continue
  fi

  cell_files=0
  cell_bytes=0
  npz_seen=0          # npz that matched a wanted name BEFORE the path filter

  for root in "${roots[@]}"; do
    for v in $variants; do
      # every leaf folder that holds <variant>.npz, at any depth (seed / geometry
      # / results_train_set nesting differs per scene)
      while IFS= read -r npz; do
        leaf="$(dirname "$npz")"
        npz_seen=$((npz_seen + 1))
        if [[ -n "$pathfilter" && "$leaf" != *"$pathfilter"* ]]; then continue; fi
        while IFS= read -r f; do
          sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
          rel="${f#$LOGS/}"
          cell_files=$((cell_files + 1))
          cell_bytes=$((cell_bytes + sz))
          if [[ "$MODE" == "stage" ]]; then
            mkdir -p "$STAGE/logs/$(dirname "$rel")"
            cp -n "$f" "$STAGE/logs/$rel" 2>/dev/null
            printf '%-4s %10d  %s\n' "$grp" "$sz" "$rel" >> "$MANIFEST"
          fi
        done < <(find "$leaf" -maxdepth 1 -type f "${KEEP_EXPR[@]}" 2>/dev/null)
      done < <(find "$root" -type f -name "${v}.npz" 2>/dev/null)
    done
  done

  if [[ $cell_files -eq 0 ]]; then
    if [[ $npz_seen -gt 0 ]]; then
      echo "      !! EMPTY - $npz_seen matching .npz exist, but the path filter"
      echo "         '*${pathfilter}*' rejected every one of them."
    else
      echo "      !! EMPTY - run folder exists but none of [$variants] has an .npz"
    fi
    # Say what IS there, so the cell can be corrected in one more PLAN rather
    # than a round of guessing. Both lists are what the run actually holds.
    echo "         -- npz basenames present under this run:"
    find "${roots[@]}" -type f -name '*.npz' ! -name '*.partial.npz' -printf '%f\n' 2>/dev/null \
      | sort -u | head -25 | sed 's/^/            /'
    echo "         -- leaf folders holding those npz (path tail):"
    find "${roots[@]}" -type f -name '*.npz' ! -name '*.partial.npz' -printf '%h\n' 2>/dev/null \
      | sed 's#.*/\([^/]*/[^/]*\)$#\1#' | sort -u | head -25 | sed 's/^/            /'
    missing_cells=$((missing_cells + 1))
    [[ "$MODE" == "stage" ]] && echo "EMPTY    [$grp] $label  ($subtree)" >> "$MANIFEST"
  else
    printf '      OK  %4d files  %8.1f MiB   variants: %s\n' \
      "$cell_files" "$(echo "$cell_bytes" | awk '{print $1/1048576}')" "$variants"
    found_cells=$((found_cells + 1))
  fi

  total_files=$((total_files + cell_files))
  total_bytes=$((total_bytes + cell_bytes))
done

echo "-------------------------------------------------------------------------------"
printf 'TOTAL  %d cells found, %d missing/empty   %d files   %.1f MiB\n' \
  "$found_cells" "$missing_cells" "$total_files" \
  "$(echo "$total_bytes" | awk '{print $1/1048576}')"
echo

if [[ "$MODE" != "stage" ]]; then
  echo "PLAN only - nothing copied. Re-run with 'stage' to populate:"
  echo "  $STAGE"
  exit 0
fi

echo "Staged into : $STAGE"
echo "Manifest    : $MANIFEST"
du -sh "$STAGE" 2>/dev/null

if [[ "$TARIT" == "tar" ]]; then
  ARCHIVE="$REPO/export_tmp/v3_figs_20260918.tar.gz"
  echo
  echo "Packing $ARCHIVE ..."
  tar -czf "$ARCHIVE" -C "$(dirname "$STAGE")" "$(basename "$STAGE")"
  ls -lh "$ARCHIVE"
  echo
  echo "Pull it from the laptop with:"
  echo "  scp <user>@i6-gpu-1:$ARCHIVE ."
fi
