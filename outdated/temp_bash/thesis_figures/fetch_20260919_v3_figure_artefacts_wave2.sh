#!/bin/bash
# =============================================================================
# fetch_20260919_v3_figure_artefacts_wave2.sh
#
# Wave 2 of the figure-artefact stager. Wave 1
# (fetch_20260918_v3_figure_artefacts.sh) brought F1-F3 down on 2026-09-18 and
# those figures are built. This script carries the two cells wave 1 did NOT
# deliver, with both of their causes now fixed:
#
#   F4  aligning box paths -- staged before the '_train_set' naming fix landed,
#       so it was absent from the 18-09 archive. The cell is correct here.
#   F5  fig:raw-plans (Fig 6.3) -- wave 1 looked for an FMPCC_RUN_MSG=planpanel
#       tag that DOES NOT EXIST and reported MISSING. It was right that nothing
#       was there and wrong about why: the panels were already produced by the
#       20-trials evaluations of August and sit under '*_msg20trials' (FM) and
#       '*_msgafon02_s6' (CI-MeanFM). Four of the five panels are a DOWNLOAD.
#       Source: REQUEST_20260916_cluster_fm_plan_panels.md, 'CORRECTION
#       2026-09-18 (v3.39)', restated in
#       data_status/PENDING_20260918_pillars_geometry_redesign.md section 6.
#
# The fifth raw-plans panel (diffusion K=2) is NOT here and is not fetchable:
# every GaussianDiffusion folder in the batch is K20, because a diffusion
# model's step count is fixed when its noise schedule is discretised at
# training time. The thesis leaves that cell empty.
#
#   Run folders resolved against Data_Analysis/analysis_results_checkpoint/
#   16_09_logs_tree.txt (capture of 2026-09-16, root /u/home/llim/FMPCC/FM-PCC/logs).
#
# THIS SCRIPT SUBMITS NOTHING AND DELETES NOTHING. It reads logs/ and copies.
#
# Usage (from the repo root on the remote):
#   bash Slurm_Codes/temp_bash/fetch_20260919_v3_figure_artefacts_wave2.sh           # PLAN
#   bash Slurm_Codes/temp_bash/fetch_20260919_v3_figure_artefacts_wave2.sh stage     # copy
#   bash Slurm_Codes/temp_bash/fetch_20260919_v3_figure_artefacts_wave2.sh stage tar # copy + tar.gz
#
# Knobs:
#   REPO=...      repo root on the cluster        (default $HOME/FMPCC/FM-PCC)
#   STAGE=...     staging folder                  (default $REPO/export_tmp/v3_figs_20260919)
#   WAVE=...      subset of "F4 F5"               (default both)
#   KEEP_GIF=1    also copy rollout .gif files    (default off - 35 GiB of the tree is .gif)
#   KEEP_LOG=1    also copy rollout_*.log files   (default off)
#
# WAVE, not GROUPS: GROUPS is a bash built-in and silently refuses assignment.
# See Slurm_Codes/temp_bash/README.md -- this trap has been hit here before.
# =============================================================================

set -u -o pipefail

MODE="${1:-plan}"
TARIT="${2:-}"

REPO="${REPO:-$HOME/FMPCC/FM-PCC}"
LOGS="$REPO/logs"
STAGE="${STAGE:-$REPO/export_tmp/v3_figs_20260919}"
WAVE="${WAVE:-F4 F5}"
KEEP_GIF="${KEEP_GIF:-0}"
KEEP_LOG="${KEEP_LOG:-0}"

MANIFEST="$STAGE/MANIFEST_20260919.txt"

if [[ ! -d "$LOGS" ]]; then
  echo "FATAL: no logs tree at $LOGS  (set REPO=...)" >&2
  exit 1
fi

KEEP_PATTERNS=( '*.npz' 'results.json' 'run_provenance*.json' '*.png' )
[[ "$KEEP_GIF" == "1" ]] && KEEP_PATTERNS+=( '*.gif' )
[[ "$KEEP_LOG" == "1" ]] && KEEP_PATTERNS+=( '*.log' )

# =============================================================================
# The cells to fetch.
#
#   <group>|<label>|<run subtree under logs/>|<variant basenames>[|<path filters>]
#
# The 5th field is a SPACE-SEPARATED list of substrings, ALL of which must
# appear in a leaf's path for it to be kept (wave 1 allowed only one). F5 needs
# two -- the geometry 'both-hard' and the seed '/6/' -- because those runs carry
# five seeds and three geometries and only one cell of that grid is the figure.
#
# A variant is matched by its EXACT basename, '<variant>.npz' first and
# '<variant>.png' as a fallback for cells whose artefact is only the dashboard
# image. Exact matching is what keeps 'hardflow_sls' from swallowing
# 'hardflow_sls-r'; a prefix glob would not.
# =============================================================================

CELLS=()

# --- F4  D3IL-aligning box paths over the ten contexts -----------------------
#     sec:res:aligning:projection. Geometry is a PARENT dir here
#     (results_train_set/<geo>/<variant>/), unlike the UAV scenes.
#     Every variant carries a '_train_set' suffix on disk: this run was
#     evaluated with --eval-on-train and eval_mix_visual_aligning.py:3256
#     appends '_train_set' to the VARIANT NAME itself, before the artefact
#     label is resolved. Confirmed by the 2026-09-18 EMPTY diagnostic.
CELLS+=( "F4|aligning MeanFM K20|aligning-d3il-visual/plans/mix_visual_aligning_mf/H8_Dmix_visual_aligning.models.visual_mf_diffusion.VisualMeanFlow_a1.5_b1.0_aw1_VTrue_steps1000_bs64_filmv1_Emf_tslogit_normal/H8_K20_Meuler_T0.2_Dmix_visual_aligning.models.visual_mf_diffusion.VisualMeanFlow_VTrue_mpc4_filmv1_Emf|dpcc-r_train_set hardflow_sls-r_train_set diffuser_train_set|combined_5-tightened" )

# --- F5  fig:raw-plans -- four panels that already exist ---------------------
#     Wanted file: the seed-6 both-hard 'diffuser' dashboard the eval writes as
#     it runs, at the same crop as the three panels already vendored.
#     NOTE the model folder is pinned to '..._aw10' and NOT globbed: an
#     '..._aw1' folder sits beside it in the same parent carrying an identically
#     named K1 run (6 files, a stub). A glob would match the stub.
for K in 1 2; do
  CELLS+=( "F5|raw-plans FM K$K|avoiding-d3il/plans/flow_matching_v3_ode_selectable/H8_Dmodels.diffusion.FlowMatchingODE_a1.5_b1.0_aw10/H8_K${K}_Meuler_T0.5_Dmodels.diffusion.FlowMatchingODE_msg20trials|diffuser|both-hard /6/" )
  CELLS+=( "F5|raw-plans CI-MeanFM K$K|avoiding-d3il/plans/*/H8_Dflow_matcher_v3_alphaflow.models.AlphaFlowODE_aw10_bbunet_tslogit_normal_ai1.0_ae0.2_ag25.0_rf0.5/H8_K${K}_Meuler_T0.5_A0.5_B4_Dflow_matcher_v3_alphaflow.models.AlphaFlowODE_msgafon02_s6|diffuser|both-hard /6/" )
done

# =============================================================================
# Runner
# =============================================================================

echo "==============================================================================="
echo " fetch_20260919_v3_figure_artefacts_wave2   mode=$MODE   groups=[$WAVE]"
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
    echo "# wave 2: F4 aligning paths, F5 raw-plan panels"
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

# every filter substring must be present in the leaf path
leaf_wanted() {
  local leaf="$1" pat
  for pat in $pathfilter; do
    [[ "$leaf" == *"$pat"* ]] || return 1
  done
  return 0
}

for cell in "${CELLS[@]}"; do
  IFS='|' read -r grp label subtree variants pathfilter <<< "$cell"
  pathfilter="${pathfilter:-}"
  want_group "$grp" || continue

  echo "-------------------------------------------------------------------------------"
  echo "[$grp] $label"
  echo "      $subtree"
  [[ -n "$pathfilter" ]] && echo "      path filters (all must match): $pathfilter"

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
  [[ ${#roots[@]} -gt 1 ]] && echo "      note: ${#roots[@]} run folders matched the glob"

  cell_files=0
  cell_bytes=0
  hits_seen=0          # artefacts matching a wanted name BEFORE the path filter
  seen_leaves=""       # guard against a leaf being counted twice (npz AND png)

  # npz first; fall back to png for cells whose artefact is only the dashboard
  for ext in npz png; do
    [[ $cell_files -gt 0 ]] && break
    for root in "${roots[@]}"; do
      for v in $variants; do
        while IFS= read -r hit; do
          leaf="$(dirname "$hit")"
          hits_seen=$((hits_seen + 1))
          [[ " $seen_leaves " == *" $leaf "* ]] && continue
          leaf_wanted "$leaf" || continue
          seen_leaves="$seen_leaves $leaf"
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
        done < <(find "$root" -type f -name "${v}.${ext}" 2>/dev/null)
      done
    done
    [[ $cell_files -eq 0 && $hits_seen -eq 0 && "$ext" == "npz" ]] \
      && echo "      (no ${variants// /,}.npz here - trying .png)"
  done

  if [[ $cell_files -eq 0 ]]; then
    if [[ $hits_seen -gt 0 ]]; then
      echo "      !! EMPTY - $hits_seen matching artefact(s) exist, but the path"
      echo "         filters [$pathfilter] rejected every one of them."
    else
      echo "      !! EMPTY - run folder exists but none of [$variants] is in it"
    fi
    # Say what IS there, so the cell can be corrected in one more PLAN rather
    # than a round of guessing. Both lists are what the run actually holds.
    echo "         -- artefact basenames present under this run:"
    find "${roots[@]}" -type f \( -name '*.npz' -o -name '*.png' \) \
      ! -name '*.partial.npz' -printf '%f\n' 2>/dev/null \
      | sort -u | head -25 | sed 's/^/            /'
    echo "         -- leaf folders holding them (path tail):"
    find "${roots[@]}" -type f \( -name '*.npz' -o -name '*.png' \) \
      ! -name '*.partial.npz' -printf '%h\n' 2>/dev/null \
      | sed 's#.*/\([^/]*/[^/]*/[^/]*\)$#\1#' | sort -u | head -25 | sed 's/^/            /'
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
  ARCHIVE="$REPO/export_tmp/v3_figs_20260919.tar.gz"
  echo
  echo "Packing $ARCHIVE ..."
  tar -czf "$ARCHIVE" -C "$(dirname "$STAGE")" "$(basename "$STAGE")"
  ls -lh "$ARCHIVE"
  echo
  echo "Pull it from the laptop with:"
  echo "  scp <user>@i6-gpu-1:$ARCHIVE ."
fi
