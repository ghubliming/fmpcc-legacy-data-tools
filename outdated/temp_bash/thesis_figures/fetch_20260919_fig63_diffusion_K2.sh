#!/bin/bash
# =============================================================================
# fetch_20260919_fig63_diffusion_K2.sh
#
# Stages what jobs 25965 (train) + 25966 (eval) produced: the LAST empty panel of
# fig:raw-plans (Fig 6.3), the diffusion baseline at K=2 — plus, as a by-product,
# the first diffusion K=2 evaluation that has ever existed in this project.
#
# Both jobs finished clean on 2026-09-19:
#   25965  16:24:32 -> 19:05:21 UTC (2 h 41 m)  state_best.pt written
#   25966  19:05:21 -> 19:22:11 UTC (17 m)      13 variants x 3 geometries, seed 6
#
# ⚠️ Supersedes the note in fetch_20260919_v3_figure_artefacts_wave2.sh, which says this
#    panel "is NOT here and is not fetchable ... the thesis leaves that cell empty."
#    That was right about the corpus of the day and is now out of date: the checkpoint did
#    not exist, so it was trained. It is a fetch now.
#
# THIS SCRIPT SUBMITS NOTHING AND DELETES NOTHING. It reads logs/ and copies.
#
# Usage (from the repo root on the cluster):
#   bash Slurm_Codes/temp_bash/fetch_20260919_fig63_diffusion_K2.sh            # PLAN
#   bash Slurm_Codes/temp_bash/fetch_20260919_fig63_diffusion_K2.sh stage      # copy
#   bash Slurm_Codes/temp_bash/fetch_20260919_fig63_diffusion_K2.sh stage tar  # copy + tar.gz
#
# Knobs:
#   REPO=...    repo root on the cluster  (default $HOME/FMPCC/FM-PCC)
#   STAGE=...   staging folder            (default $REPO/export_tmp/fig63_K2_20260919)
#   KEEP_GIF=1  also copy rollout .gif    (default off — they are the bulk of the tree)
#
# WAVE, not GROUPS: GROUPS is a bash built-in. See temp_bash/README.md.
# =============================================================================

set -u -o pipefail

MODE="${1:-plan}"
TARIT="${2:-}"

REPO="${REPO:-$HOME/FMPCC/FM-PCC}"
LOGS="$REPO/logs"
STAGE="${STAGE:-$REPO/export_tmp/fig63_K2_20260919}"
KEEP_GIF="${KEEP_GIF:-0}"
MANIFEST="$STAGE/MANIFEST_fig63_K2.txt"

RUN="avoiding-d3il/plans/diffusion/H8_K2_Dmodels.GaussianDiffusion_aw10/H8_K2_T0.5_Dmodels.GaussianDiffusion_msgplanpanel63"
CKPT="avoiding-d3il/diffusion/H8_K2_Dmodels.GaussianDiffusion_aw10"
SEED="${SEED:-6}"

[[ -d "$LOGS" ]] || { echo "FATAL: no logs tree at $LOGS  (set REPO=...)" >&2; exit 1; }

echo "==============================================================================="
echo " fetch_20260919_fig63_diffusion_K2    mode=$MODE"
echo " repo  : $REPO"
echo " run   : logs/$RUN"
echo " seed  : $SEED"
echo " stage : $STAGE"
echo "==============================================================================="
echo

# --- A · THE PANEL. The one file the figure needs. ---------------------------
#     Written by scripts/eval.py as the run proceeds: the plan fan with projection
#     switched off, 2 episodes, seed 6, geometry both-hard. Same layout and the same
#     3000x1000 size as the seven panels already vendored, so the crop box
#     (2312, 92, 2715, 492) in plotting/sources.py applies unchanged.
PANEL="$LOGS/$RUN/$SEED/results/halfspace_both-hard/diffuser.png"

# --- B · The other two geometries' dashboards, for the record ----------------
#     Not used by the figure. Cheap, and they are what makes the panel checkable.
PANEL_TR="$LOGS/$RUN/$SEED/results/halfspace_top-right-hard/diffuser.png"
PANEL_TL="$LOGS/$RUN/$SEED/results/halfspace_top-left-hard/diffuser.png"

# --- C · The whole seed-6 results tree, minus the heavy media ----------------
#     🔵 THE BY-PRODUCT, AND IT IS NOT SMALL: ledger row A4 said "diffusion at K=2 is
#     absent everywhere, at either protocol". It is not absent any more. 25966 ran the
#     full 13-variant x 3-geometry sweep at seed 6, 2 episodes, so a diffusion K=2 row
#     can enter tab:avoiding-dpcc-protocol — flagged SEED 6 ONLY, since the table's
#     other diffusion rows are five seeds. Stage the json/npz so the DA can read it.
RESULTS="$LOGS/$RUN/$SEED/results"

# --- D · Checkpoint provenance (config + seed manifest only, NOT the weights) -
#     state_best.pt is ~50 MB and belongs on the cluster. The configs are what a
#     later reader needs to prove the model was trained AT K=2, which is the whole
#     point of this panel.
CKPT_META=( "$LOGS/$CKPT/$SEED/diffusion_config.pkl" \
            "$LOGS/$CKPT/$SEED/model_config.pkl" \
            "$LOGS/$CKPT/$SEED/trainer_config.json" \
            "$LOGS/$CKPT/seeds_config.json" )

KEEP_PATTERNS=( '*.npz' 'results.json' '*_stats.json' 'constraint_metrics.json' \
                'run_provenance*.json' '*.png' )
[[ "$KEEP_GIF" == "1" ]] && KEEP_PATTERNS+=( '*.gif' )

hr() { echo "-------------------------------------------------------------------------------"; }
sz() { du -sh "$1" 2>/dev/null | cut -f1; }

# --- the check that matters ---------------------------------------------------
hr
if [[ -f "$PANEL" ]]; then
    DIMS=$(python -c "from PIL import Image;im=Image.open('$PANEL');print('%dx%d'%im.size)" 2>/dev/null || echo '?')
    echo "✅ PANEL   $(sz "$PANEL")  ${DIMS}  logs/$RUN/$SEED/results/halfspace_both-hard/diffuser.png"
    if [[ "$DIMS" != "3000x1000" && "$DIMS" != "?" ]]; then
        echo "   ⚠️  expected 3000x1000 (2 episodes). At another size the crop box is wrong —"
        echo "      open it and re-measure before vendoring."
    fi
else
    echo "❌ PANEL MISSING: $PANEL"
    echo "   25966's own tail listed it, so check REPO/SEED before believing this."
    exit 1
fi
for f in "$PANEL_TR" "$PANEL_TL"; do
    [[ -f "$f" ]] && echo "   also: ${f#"$LOGS"/}" || echo "   (absent: ${f#"$LOGS"/})"
done
echo "   results tree: $(sz "$RESULTS")   (13 variants x 3 geometries, seed $SEED)"
for f in "${CKPT_META[@]}"; do
    [[ -f "$f" ]] && echo "   ckpt meta: ${f#"$LOGS"/}" || echo "   ⚠️ ckpt meta absent: ${f#"$LOGS"/}"
done
hr

if [[ "$MODE" != "stage" ]]; then
    echo
    echo "PLAN only — nothing copied. Re-run with:  bash $0 stage [tar]"
    exit 0
fi

mkdir -p "$STAGE/panel" "$STAGE/results" "$STAGE/ckpt_meta"
{
  echo "# staged $(date -u +%Y-%m-%dT%H:%M:%SZ)  host $(hostname)"
  echo "# jobs 25965 (train K=2) + 25966 (eval K=2), seed $SEED"
  echo "# source root: $LOGS"
  echo
} > "$MANIFEST"

cp "$PANEL" "$STAGE/panel/fig8h_plans_diffusion_K2_seed6.png"
echo "panel/fig8h_plans_diffusion_K2_seed6.png  <-  $RUN/$SEED/results/halfspace_both-hard/diffuser.png" >> "$MANIFEST"
for f in "$PANEL_TR" "$PANEL_TL"; do
    [[ -f "$f" ]] || continue
    g=$(basename "$(dirname "$f")")
    cp "$f" "$STAGE/panel/diffuser_${g}.png"
    echo "panel/diffuser_${g}.png  <-  ${f#"$LOGS"/}" >> "$MANIFEST"
done

# results tree, filtered
KEEP_EXPR=( '(' ); first=1
for p in "${KEEP_PATTERNS[@]}"; do
    [[ $first -eq 1 ]] && first=0 || KEEP_EXPR+=( '-o' )
    KEEP_EXPR+=( -name "$p" )
done
KEEP_EXPR+=( ')' )
n=0
while IFS= read -r -d '' f; do
    rel="${f#"$RESULTS"/}"
    mkdir -p "$STAGE/results/$(dirname "$rel")"
    cp "$f" "$STAGE/results/$rel"
    echo "results/$rel" >> "$MANIFEST"
    n=$((n+1))
done < <(find "$RESULTS" -type f "${KEEP_EXPR[@]}" -print0)

for f in "${CKPT_META[@]}"; do
    [[ -f "$f" ]] || continue
    cp "$f" "$STAGE/ckpt_meta/$(basename "$f")"
    echo "ckpt_meta/$(basename "$f")  <-  ${f#"$LOGS"/}" >> "$MANIFEST"
done

hr
echo "staged: 1 panel + $n result files + $(ls -1 "$STAGE/ckpt_meta" | wc -l) config files"
echo "        $STAGE   ($(sz "$STAGE"))"

if [[ "$TARIT" == "tar" ]]; then
    TARBALL="$REPO/export_tmp/fig63_K2_20260919.tar.gz"
    tar -czf "$TARBALL" -C "$(dirname "$STAGE")" "$(basename "$STAGE")"
    echo "tarball: $TARBALL  ($(sz "$TARBALL"))"
fi
hr
echo
echo "Then, on the AI container:"
echo "  1. panel -> Data_Analysis/DA_Result_Curated_MD/Report_20260903_AF_UNet/fig8h_plans_diffusion_K2_seed6.png"
echo "  2. plotting/sources.py: move fig_raw_plans_diffusion_K2 from PLANNED to VENDORED,"
echo "     add it to VENDORED_CROP at (2312, 92, 2715, 492) — open it and confirm first"
echo "  3. python3.14 plotting/prep/crop_vendored.py && python3 plotting/make_figs.py \\"
echo "       && python3 plotting/export_to_draft.py v3"
echo "  4. tell v3 the caption sentence about the absent panel can go (the CLAIM stays:"
echo "     the budget was fixed at training, which is why this needed a training run)"
