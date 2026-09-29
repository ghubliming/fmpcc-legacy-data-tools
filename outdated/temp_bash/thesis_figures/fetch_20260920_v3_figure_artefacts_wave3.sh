#!/bin/bash
# =============================================================================
# fetch_20260920_v3_figure_artefacts_wave3.sh
#
# Wave 3 of the figure-artefact stager. Covers every DOWNLOAD item in
#   logs_in_develop/Writing/Working_Space/data_status/PENDING_20260920_all_lacking_runs.md
# section 4 ("Transfers or logging changes, not model runs").
#
# Nothing here is a model run. Section 1/2/3 of that file (R2, R25, R26, R18,
# R7, R14, R9, R15, R16, R17, R27, R23) are evaluations or trainings and are
# NOT in this script -- they belong in a pipeline_*.sh, not a fetcher.
#
#   F6  D10d  fig:raw-plans, the diffusion baseline at its OWN budget K=20.
#             *** This is the one open \todofigure in the v3 draft. ***
#             One .png. Spec: REQUEST_20260916_cluster_fm_plan_panels.md,
#             "ADDITION 2026-09-20 (v3.48)".
#   F7  D10a  D3IL-avoiding executed end-effector paths -- the counterpart of
#             fig:uav-corridor-paths for the foundation benchmark.
#             Variant dpcc-t-tightened, seed 6, all three geometries.
#   F8  D10b  D3IL-aligning end-effector paths.  *** OFF BY DEFAULT ***
#             Already satisfied by the 09-19 drop -- see the note on F8 below.
#             Enable only to widen the geometry coverage.
#   F9  D8/D9 sacct compute accounting + run_provenance harvest. OFF BY DEFAULT.
#
# NOT fetchable, do not add cells for them:
#   D10c  aligning BOX paths. The aligning obs_all is (400, 6) =
#         [desired xyz, actual xyz] of the end effector -- verified on the
#         09-19 drop. The box pose is not logged at all, so this needs the
#         logging change and a re-evaluation, not a download.
#   D2    the angle convention has to be decided before the existing columns
#         mean anything; nothing to copy.
#
# Run folders resolved against temp/19-09/2026-09-19/logs_tree.txt
# (capture 2026-09-19 19:29, root /u/home/llim/FMPCC/FM-PCC/logs). That capture
# has max_depth=8, so it shows every run folder in this script but not the
# geometry leaves inside them; the geometry names come from the 09-19 drop.
#
# THIS SCRIPT SUBMITS NOTHING AND DELETES NOTHING. It reads logs/ and copies.
#
# Usage (from the repo root on the remote):
#   bash Slurm_Codes/temp_bash/fetch_20260920_v3_figure_artefacts_wave3.sh           # PLAN
#   bash Slurm_Codes/temp_bash/fetch_20260920_v3_figure_artefacts_wave3.sh stage     # copy
#   bash Slurm_Codes/temp_bash/fetch_20260920_v3_figure_artefacts_wave3.sh stage tar # copy + tar.gz
#
# Knobs:
#   REPO=...      repo root on the cluster        (default $HOME/FMPCC/FM-PCC)
#   STAGE=...     staging folder                  (default $REPO/export_tmp/v3_figs_20260920)
#   WAVE=...      subset of "F6 F7 F8 F9"         (default "F6 F7")
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
STAGE="${STAGE:-$REPO/export_tmp/v3_figs_20260920}"
WAVE="${WAVE:-F6 F7}"
KEEP_GIF="${KEEP_GIF:-0}"
KEEP_LOG="${KEEP_LOG:-0}"

MANIFEST="$STAGE/MANIFEST_20260920.txt"

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
#   <group>|<label>|<run subtree under logs/>|<variants>|<path filters>|<pick>
#
# Field 5, path filters: SPACE-SEPARATED substrings, ALL of which must appear in
# a leaf's path. Seed 6 is written '/6/' so it cannot match '/16/' or 'K6'.
#
# Field 6, pick -- NEW IN WAVE 3, and the reason this script does not weigh a
# gigabyte:
#   leaf   every artefact in the matched leaf folder (wave 1/2 behaviour). One
#          avoiding geometry leaf holds ~14 variants x (npz + png) ~ 25 MiB.
#   exact  ONLY <variant>.npz, <variant>.png and the leaf's results.json /
#          run_provenance*.json. ~1.8 MiB per leaf.
# F7 matches 24 leaves; at 'leaf' that would be ~600 MiB for three figures'
# worth of paths. 'exact' is what makes it ~40 MiB.
#
# A variant is matched by its EXACT basename, '<variant>.npz' first and
# '<variant>.png' as a fallback for cells whose artefact is only the dashboard
# image. Exact matching is what keeps 'dpcc-t' from swallowing
# 'dpcc-t-tightened'; a prefix glob would not.
# =============================================================================

# Model folders of the locked avoiding set (PENDING_20260919_avoiding_tables_locked.md §1).
FAM_MF='avoiding-d3il/plans/flow_matching_v3_meanflow/H8_Dflow_matcher_v3_meanflow.models.MeanFlowODE_aw10_objmeanflow_bbunet_tslogit_normal_dp0.5'
FAM_FM='avoiding-d3il/plans/flow_matching_v3_ode_selectable/H8_Dmodels.diffusion.FlowMatchingODE_a1.5_b1.0_aw10'
FAM_AF='avoiding-d3il/plans/flow_matching_v3_alphaflow/H8_Dflow_matcher_v3_alphaflow.models.AlphaFlowODE_aw10_bbunet_tslogit_normal_ai1.0_ae0.2_ag25.0_rf0.5'
FAM_DD='avoiding-d3il/plans/diffusion/H8_K20_Dmodels.GaussianDiffusion_aw10'

CELLS=()

# --- F6  D10d  fig:raw-plans, diffusion baseline at K=20 ---------------------
#     THE one open \todofigure in v3.48. Wanted: a single seed-6 both-hard
#     'diffuser' dashboard .png, cropped locally to (2312,574,2715,947) with
#     the (403,400) resize, exactly like the four 09-19 panels.
#
#     '/plans/diffusion/' IS THE BASELINE, the class name is not. A folder
#     named 'Dmodels.diffusion.GaussianDiffusion' under any flow_matching_v3_*
#     parent is the FLOW model under its pre-26-May class name. That misread
#     has already put a wrong row in Table 6.1 once
#     (PENDING_20260919_avoiding_tables_locked.md §2) and has caught two
#     readers of this repo. The subtree below is pinned, not globbed.
CELLS+=( "F6|raw-plans Diffusion K20 (the open todofigure)|$FAM_DD/H8_K20_T0.5_Dmodels.GaussianDiffusion_msg20trials|diffuser|both-hard /6/|exact" )

# --- F7  D10a  D3IL-avoiding executed paths ----------------------------------
#     One projected episode per geometry per model, drawn over the geometry it
#     was projected against. Variant dpcc-t-tightened: per-step rule on the
#     tightened set, which is the configuration tab:state-headline reports.
#
#     The executed path is obs_all in the variant's .npz -- verified on the
#     09-19 drop, shape (20,) object of (T, d) per episode. NOTE that the
#     UNPROJECTED 'diffuser.npz' of these same runs carries scalars ONLY; do
#     not expect a path out of it, and do not build the figure from it.
#
#     Geometry folder names are 'halfspace_<variant>', so the filter is
#     'halfspace_both-hard' and not 'both-hard' -- kept explicit here because
#     the F6 filter above is the looser spelling and the two must not be
#     confused when this file is next edited.
for GEO in halfspace_both-hard halfspace_top-left-hard halfspace_top-right-hard; do
  for K in 1 2; do
    CELLS+=( "F7|avoiding paths MeanFM K$K $GEO|$FAM_MF/H8_K${K}_Meuler_T0.5_A0.5_B1_Dflow_matcher_v3_meanflow.models.MeanFlowODE_msg20trials|dpcc-t-tightened|$GEO /6/|exact" )
    CELLS+=( "F7|avoiding paths FM K$K $GEO|$FAM_FM/H8_K${K}_Meuler_T0.5_Dmodels.diffusion.FlowMatchingODE_msg20trials|dpcc-t-tightened|$GEO /6/|exact" )
    CELLS+=( "F7|avoiding paths CI-MeanFM K$K $GEO|$FAM_AF/H8_K${K}_Meuler_T0.5_A0.5_B4_Dflow_matcher_v3_alphaflow.models.AlphaFlowODE_msgafon02_s6|dpcc-t-tightened|$GEO /6/|exact" )
  done
  CELLS+=( "F7|avoiding paths Diffusion K20 $GEO|$FAM_DD/H8_K20_T0.5_Dmodels.GaussianDiffusion_msg20trials|dpcc-t-tightened|$GEO /6/|exact" )
done

# --- F8  D10b  D3IL-aligning end-effector paths  -- OFF BY DEFAULT -----------
#     PENDING_20260920 lists D10b as open, but it is ALREADY SATISFIED: the
#     09-19 wave-2 drop carries dpcc-r_train_set / hardflow_sls-r_train_set /
#     diffuser_train_set at combined_5-tightened, seed 6, and their obs_all is
#     (10, 400, 6) = ten contexts x 400 steps x [desired xyz, actual xyz].
#     That is the end-effector path the figure needs. Re-fetching gains nothing.
#
#     This cell exists for ONE question: which OTHER geometries that run holds.
#     It carries no geometry filter, so it reports every geometry leaf under the
#     run, and at 'exact' pick it costs ~1.8 MiB each. Enable with
#     WAVE="F6 F7 F8" only if the builder turns out to want more than the
#     tightened set.
#
#     '_train_set' is part of the VARIANT NAME on disk, not a folder suffix:
#     this run was evaluated with --eval-on-train and
#     eval_mix_visual_aligning.py:3256 appends it before the artefact label is
#     resolved. Dropping it is what made the 09-18 fetch come back EMPTY.
CELLS+=( "F8|aligning paths, all geometries|aligning-d3il-visual/plans/mix_visual_aligning_mf/H8_Dmix_visual_aligning.models.visual_mf_diffusion.VisualMeanFlow_a1.5_b1.0_aw1_VTrue_steps1000_bs64_filmv1_Emf_tslogit_normal/H8_K20_Meuler_T0.2_Dmix_visual_aligning.models.visual_mf_diffusion.VisualMeanFlow_VTrue_mpc4_filmv1_Emf|dpcc-r_train_set hardflow_sls-r_train_set diffuser_train_set|/6/|exact" )

# =============================================================================
# Runner
# =============================================================================

echo "==============================================================================="
echo " fetch_20260920_v3_figure_artefacts_wave3   mode=$MODE   groups=[$WAVE]"
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
    echo "# wave 3: F6 raw-plans diffusion K20, F7 avoiding paths, F8 aligning (opt-in), F9 provenance (opt-in)"
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

# the files this cell takes out of one matched leaf -- see 'pick' above
emit_files() {
  local leaf="$1" v="$2" f
  if [[ "$pick" == "exact" ]]; then
    for f in "$leaf/$v.npz" "$leaf/$v.png" "$leaf/results.json"; do
      [[ -f "$f" ]] && printf '%s\n' "$f"
    done
    find "$leaf" -maxdepth 1 -type f -name 'run_provenance*.json' 2>/dev/null
  else
    find "$leaf" -maxdepth 1 -type f "${KEEP_EXPR[@]}" 2>/dev/null
  fi
}

for cell in "${CELLS[@]}"; do
  IFS='|' read -r grp label subtree variants pathfilter pick <<< "$cell"
  pathfilter="${pathfilter:-}"
  pick="${pick:-leaf}"
  want_group "$grp" || continue

  echo "-------------------------------------------------------------------------------"
  echo "[$grp] $label"
  echo "      $subtree"
  [[ -n "$pathfilter" ]] && echo "      path filters (all must match): $pathfilter    pick=$pick"

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
          [[ " $seen_leaves " == *" $leaf|$v "* ]] && continue
          leaf_wanted "$leaf" || continue
          seen_leaves="$seen_leaves $leaf|$v"
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
          done < <(emit_files "$leaf" "$v")
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

# --- F9  D8 / D9  compute accounting and provenance  -- OFF BY DEFAULT -------
#     D8 wants GPU-hours, D9 wants job ids / git revisions / checkpoint tags for
#     tab:corpora. Neither is a figure artefact, so this writes two text files
#     next to the staged logs instead of copying run folders.
#
#     CAVEAT, and it is the reason this is opt-in: slurmdbd keeps accounting for
#     a bounded window. The May and June jobs behind Chapters 5-6 are very
#     likely already purged, and sacct will simply not list them. What comes
#     back is a floor on total compute, not the total. Say so in the appendix
#     rather than reporting the number as complete.
if want_group F9; then
  echo "-------------------------------------------------------------------------------"
  echo "[F9] sacct compute accounting + run_provenance harvest"
  if [[ "$MODE" == "stage" ]]; then
    mkdir -p "$STAGE/provenance"
    echo "      writing $STAGE/provenance/sacct_all.tsv"
    sacct -u "$USER" -S 2026-01-01 -X --parsable2 \
      --format=JobID,JobName,State,Partition,AllocTRES,Elapsed,Start,End,ExitCode \
      > "$STAGE/provenance/sacct_all.tsv" 2>"$STAGE/provenance/sacct_stderr.txt" \
      || echo "      !! sacct failed - see provenance/sacct_stderr.txt"
    echo "      writing $STAGE/provenance/run_provenance_index.txt"
    find "$LOGS" -type f -name 'run_provenance*.json' -printf '%s\t%p\n' 2>/dev/null \
      | sort -k2 > "$STAGE/provenance/run_provenance_index.txt"
    wc -l < "$STAGE/provenance/run_provenance_index.txt" \
      | sed 's/^/      run_provenance files found: /'
  else
    echo "      PLAN: would run sacct -u $USER -S 2026-01-01 and index run_provenance*.json"
    echo "      sacct rows available right now:"
    sacct -u "$USER" -S 2026-01-01 -X -n --format=JobID 2>/dev/null | wc -l | sed 's/^/        /'
  fi
fi

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
  ARCHIVE="$REPO/export_tmp/v3_figs_20260920.tar.gz"
  echo
  echo "Packing $ARCHIVE ..."
  tar -czf "$ARCHIVE" -C "$(dirname "$STAGE")" "$(basename "$STAGE")"
  ls -lh "$ARCHIVE"
  echo
  echo "Pull it from the laptop with:"
  echo "  scp <user>@i6-gpu-1:$ARCHIVE ."
fi
