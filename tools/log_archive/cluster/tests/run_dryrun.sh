#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# run_dryrun.sh — the WHOLE log-archive pipeline, offline, on a small fake logs/ (make_fixture.sh).
# No cluster, no Google Drive, no conda: the "cluster" is a temp copy of this repo's tools, "Drive" is a folder
# (stubs/rclone), zstd is a gzip stand-in if none is installed, Slurm jobs run inline with bash, and the laptop
# script runs with CLUSTER=local. Every step is asserted; the table at the end is the verdict.
#   bash Slurm_Codes/sbatch/log_archive/tests/run_dryrun.sh          (KEEP=1 keeps the temp folder)
# Writes only into a temp dir (mktemp). Safe to run anywhere, including the cluster login node (seconds, ~20 MB).
# ─────────────────────────────────────────────────────────────────────────────
set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_REPO="$(cd "$HERE/../../../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/logarch_dryrun.XXXXXX")" || exit 1
FIX="$T/repo"
bash "$HERE/make_fixture.sh" "$SRC_REPO" "$FIX" > /dev/null || { echo "fixture failed"; exit 1; }
mkdir -p "$T/bin" "$T/drive"
cp "$HERE/stubs/rclone" "$T/bin/"
command -v zstd > /dev/null 2>&1 || cp "$HERE/stubs/zstd" "$T/bin/"
chmod +x "$T"/bin/*
export PATH="$T/bin:$PATH" FAKE_DRIVE="$T/drive" REPO="$FIX" CONDA_DIR=/nonexistent MIN_FREE_GB=0 TMP_MIN_GB=0 \
       CLUSTER=local RREPO="$FIX" LOCAL_ROOT="$T/local" POLL_S=1 TMPDIR="$T/tmp" LOGARCH_SPEED_MB=8 LOGARCH_KIT_MB=8
mkdir -p "$TMPDIR"
unset SLURM_JOB_ID SLURM_CPUS_PER_TASK SLURM_TMPDIR CUDA_VISIBLE_DEVICES ONLY_UNITS SKIP_UNITS FORCE_UNITS STAGE_MODE LOGARCH_STOP_AFTER
J="$FIX/Slurm_Codes/sbatch/log_archive"; LS="$FIX/Slurm_Codes/download_remote_logs/logarch_local.sh"
D="$T/drive/gdrive/FMPCC_logs_backup"; X="$FIX/export_tmp/log_archive"
N=0; FAILS=0; ROWS=()
check() {   # check <name> <command…> — run, log to $T/logs/<n>_<name>.log, record PASS/FAIL
    local name="$1"; shift; N=$((N + 1)); mkdir -p "$T/logs"
    local lf; lf="$T/logs/$(printf '%02d' "$N")_$name.log"
    if "$@" > "$lf" 2>&1; then ROWS+=("PASS  $name"); else ROWS+=("FAIL  $name  → $lf"); FAILS=$((FAILS + 1)); fi
}
tsv_get() { awk -F'\t' -v p="$2" -v c="$3" 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next } index($7, p) { print $h[c]; exit }' "$1"; }
count() { find "$1" -name "$2" 2>/dev/null | wc -l; }
tsv_path() { awk -F'\t' -v p="$2" -v c="$3" 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next } $7 == p { print $h[c]; exit }' "$1"; }
export -f tsv_get tsv_path count

# ── cluster side ──────────────────────────────────────────────────────────────
check selftest_init_job           bash "$J/logarch_selftest.sh"
check selftest_report_all_pass    bash -c "grep -q '| T3_synthetic | PASS' $X/_selftest/*/SELFTEST_REPORT.md && grep -q '| T5_real_roundtrip | PASS' $X/_selftest/*/SELFTEST_REPORT.md && grep -q '| T7_gdrive | PASS' $X/_selftest/*/SELFTEST_REPORT.md"
check laptop_download_selftest    bash "$LS" selftest
check raw_B_staged                env STAGE_MODE=tmp bash "$J/logarch_pack_gdrive.sh" dry_b
check raw_B_every_archive_on_drive bash -c "[ \$(ls $D/dry_b/raw/archives | wc -l) -eq \$(ls $X/dry_b/meta/receipts | grep -c '\\.gdrive\$') ] && [ \$(ls $D/dry_b/raw/archives | wc -l) -gt 10 ]"
check raw_B_no_changes            grep -q 'No changes' "$X/dry_b/meta/CHANGES.md"
check raw_B_resume_is_noop        bash -c "bash $J/logarch_pack_gdrive.sh dry_b | grep -q '0 archive(s) uploaded'"
check raw_B_stream_mode           env STAGE_MODE=stream bash "$J/logarch_pack_gdrive.sh" dry_s
check raw_stream_equals_staged    bash -c "cd $D/dry_b/raw/archives && for f in *.tar.zst; do cmp -s \"\$f\" \"$D/dry_s/raw/archives/\$f\" || exit 1; done"
check raw_autocontinue_pause      bash -c "LOGARCH_STOP_AFTER=3 bash $J/logarch_pack_gdrive.sh dry_c && [ \"\$(cat $X/dry_c/meta/ROUND_RESULT)\" = continued ] && [ \$(ls $D/dry_c/raw/archives | wc -l) -eq 3 ]"
check raw_autocontinue_finish     bash -c "bash $J/logarch_pack_gdrive.sh dry_c && [ \"\$(cat $X/dry_c/meta/ROUND_RESULT)\" = all ] && [ \$(ls $D/dry_c/raw/archives | wc -l) -eq \$(ls $D/dry_b/raw/archives | wc -l) ]"
check raw_failure_isolated        bash -c "chmod 000 '$FIX/logs/solver_bench/25121/bench.csv'; RETRY_WAIT=0 bash $J/logarch_pack_gdrive.sh dry_f; rc=\$?; chmod 644 '$FIX/logs/solver_bench/25121/bench.csv'; [ \$rc -eq 1 ] && [ \"\$(cat $X/dry_f/meta/ROUND_RESULT)\" = partial ] && [ \$(ls $D/dry_f/raw/archives | wc -l) -eq \$((\$(ls $D/dry_b/raw/archives | wc -l) - 1)) ]"
check raw_failure_resubmit_heals  bash -c "bash $J/logarch_pack_gdrive.sh dry_f && [ \"\$(cat $X/dry_f/meta/ROUND_RESULT)\" = all ] && [ \$(ls $D/dry_f/raw/archives | wc -l) -eq \$(ls $D/dry_b/raw/archives | wc -l) ]"
check route_A_rolling_download    env PACK_ENV="STAGE_BUDGET_BYTES=4000000" bash "$LS" pull-rolling dry_a
check route_A_all_local_verified  bash -c "[ \$(ls $T/local/dry_a/raw/archives | wc -l) -eq \$(ls $T/local/dry_a/raw/.verified | wc -l) ] && [ \$(find $X/dry_a/archives -name '*.tar.zst' | wc -l) -eq 0 ] && cd $T/local/dry_a/raw/archives && sha256sum -c --quiet ../meta/SHA256SUMS"
check route_A_upload_to_drive     bash "$LS" upload dry_a

# ── triage + curated layer (container side) ──────────────────────────────────
check fetch_meta_from_drive       bash "$LS" fetch-meta dry_b
check triage_scan                 bash "$LS" triage dry_b
TR="$T/local/dry_b/triage/TRIAGE.tsv"
check label_thesis_by_path        bash -c "[ \"\$(tsv_get $TR Efm_K3_mpc4_pid_stopgo_T0.5_u17cv2 label)\" = thesis ]"
check label_referenced_by_tag     bash -c "[ \"\$(tsv_get $TR T0.5_u7hg label)\" = referenced ]"
check empty_dir_joins_parent      bash -c "! grep -q \$'\\tlogs/hardflow/avoiding-v0/empty_dir\\t' $TR"
check label_referenced_devlog     bash -c "[ \"\$(tsv_path $TR logs/avoiding-d3il/diffusion/H8_K2_Dmodels.GaussianDiffusion_aw10 label)\" = referenced ]"
check label_unreferenced_eval     bash -c "[ \"\$(tsv_get $TR T0.5_oldtag9 label)\" = unreferenced ]"
check label_snapshot_excluded     bash -c "[ \"\$(tsv_get $TR 'alphaflow(Bf_U3)' label)\" = snapshot ] && [ \"\$(tsv_get $TR 'alphaflow(Bf_U3)' include)\" = no ]"
check label_abandoned_excluded    bash -c "[ \"\$(tsv_get $TR 'imeanflow(U9)' label)\" = abandoned ] && [ \"\$(tsv_get $TR 'avoiding-d3il-visual(1e4' label)\" = abandoned ] && [ \"\$(tsv_get $TR 'imeanflow(U9)' include)\" = no ]"
check eval_variant_is_one_run     bash -c "[ \"\$(tsv_get $TR msgdpccproto seeds)\" = '6 7' ] && [ \"\$(tsv_get $TR msgdpccproto kind)\" = run ]"
check training_run_drops_periodic bash -c "tsv_get $TR 'mix_uav_fm/H8_Dmodels.diffusion.FlowMatchingODE_9D' flags | grep -q periodic-ckpt-dropped"
check expert_renders_kept         bash -c "[ \"\$(tsv_get $TR expert_references dropped_bytes)\" = 0 ] && [ \"\$(tsv_get $TR expert_references curated_bytes)\" = 262144 ]"
check loose_groups_found          bash -c "[ \"\$(tsv_get $TR solver_bench kind)\" = loose ] && [ \"\$(tsv_get $TR 'logs/UAV_MIX' group)\" = Gen15_UAV_MixML ]"
check set_include_and_back        bash -c "bash $LS set dry_b --match 'avoiding-d3il/plans/flow_matching_v3_alphaflow(Bf_U3)*' --include yes && [ \"\$(tsv_get $TR 'alphaflow(Bf_U3)' include)\" = yes ] && bash $LS set dry_b --match '*alphaflow(Bf_U3)*' --include no && [ \$(wc -l < $T/local/dry_b/triage/EDITS.log) -eq 2 ]"
check plan_curate_upload          bash "$LS" plan-curate dry_b
check curate_refuses_tampered_plan bash -c "cp $D/dry_b/triage/CURATE_PLAN.tsv.gz $T/plan.bak && printf 'x' >> $D/dry_b/triage/CURATE_PLAN.tsv.gz && ! bash $J/logarch_curate.sh dry_b; rc=\$?; cp $T/plan.bak $D/dry_b/triage/CURATE_PLAN.tsv.gz; exit \$rc"
check curate_autocontinue_pause   bash -c "LOGARCH_STOP_AFTER=2 bash $J/logarch_curate.sh dry_b && [ \$(ls $X/dry_b/curate/receipts | wc -l) -eq 2 ]"
check curate_finish               bash "$J/logarch_curate.sh" dry_b
check curate_every_folder_done    bash -c "[ \$(ls $X/dry_b/curate/receipts | wc -l) -eq \$(gzip -dc $T/local/dry_b/triage/CURATE_PLAN.tsv.gz | grep -c \$'\\troot\\t') ]"
check curated_drops_render        bash -c "zstd -dc '$D/dry_b/curated/Gen15_UAV_MixML/UAV_MIX/uav-corridor/plans/mix_uav_fm/H8_Dmodels.diffusion.FlowMatchingODE_9D/Efm_K3_mpc4_pid_stopgo_T0.5_u17cv2/run_archive.tar.zst' | tar -tf - > $T/r.lst && grep -q '6/results.json\$' $T/r.lst && grep -q 'rollouts.npz\$' $T/r.lst && ! grep -q '\\.gif\$' $T/r.lst"
check curated_drops_periodic_ckpt bash -c "zstd -dc '$D/dry_b/curated/Gen15_UAV_MixML/UAV_MIX/uav-corridor/mix_uav_fm/H8_Dmodels.diffusion.FlowMatchingODE_9D/run_archive.tar.zst' | tar -tf - > $T/t.lst && grep -q 'state_best.pt' $T/t.lst && ! grep -q 'state_100000.pt' $T/t.lst"
check curated_key_file_plain      test -f "$D/dry_b/curated/Gen15_UAV_MixML/UAV_MIX/uav-corridor/plans/mix_uav_fm/H8_Dmodels.diffusion.FlowMatchingODE_9D/Efm_K3_mpc4_pid_stopgo_T0.5_u17cv2/6/results.json"
check snapshot_not_in_curated     bash -c "! find $D/dry_b/curated -path '*Bf_U3*' | grep -q ."
check publish_cards_and_catalog   bash -c "bash $LS publish dry_b && [ -f $D/dry_b/TRIAGE.md ] && [ -f $D/dry_b/INDEX_auto.md ] && [ -f $FIX/logs_in_develop/Log_Archive_Export/catalog_dry_b/TRIAGE.md ]"
check check_drive_full_restore    bash "$LS" check-drive dry_b 0

# ── organize v2: thesis folders → curated/ (renamed, complete), raw/ = everything else ─────
OB="$T/local/dry_o"; OM="$T/naming_map_dry_o.tsv"
organize_map() {   # a naming map for three runs of the fixture (what the real one does for 128 thesis folders)
    printf 'new_path\told_path\tsection\tmeaning\tinternal_tags\traw_bytes\tfiles\n' > "$OM"
    printf 'UAV-corridor/evaluations/FM_K3_thr0.5_geometric-ctrl_seed6\tlogs/UAV_MIX/uav-corridor/plans/mix_uav_fm/H8_Dmodels.diffusion.FlowMatchingODE_9D/Efm_K3_mpc4_pid_stopgo_T0.5_u17cv2\t6.3\tevaluation: FM, K = 3\tu17cv2\t0\t0\n' >> "$OM"
    printf 'UAV-corridor/models/FM_U-Net\tlogs/UAV_MIX/uav-corridor/mix_uav_fm/H8_Dmodels.diffusion.FlowMatchingODE_9D\t6.3\ttraining run: FM\t\t0\t0\n' >> "$OM"
    printf 'D3IL-avoiding/evaluations/Diffusion_K2_thr0.5_2ep_seeds6-7\tlogs/avoiding-d3il/plans/diffusion/H8_K2_Dmodels.GaussianDiffusion_aw10/H8_K2_T0.5_Dmodels.GaussianDiffusion_msgdpccproto\t6.1\tevaluation: Diffusion, K = 2\tmsgdpccproto\t0\t0\n' >> "$OM"
}
check org_raw_upload              bash "$J/logarch_pack_gdrive.sh" dry_o
check org_fetch_triage            bash -c "bash $LS fetch-meta dry_o && bash $LS triage dry_o"
organize_map
check org_plan                    env MAP="$OM" bash "$LS" organize-plan dry_o
check org_curate                  bash "$J/logarch_curate.sh" dry_o
check org_curated_renamed         bash -c "zstd -dc '$D/dry_o/curated/UAV-corridor/evaluations/FM_K3_thr0.5_geometric-ctrl_seed6/FM_K3_thr0.5_geometric-ctrl_seed6.tar.zst' | tar -tf - > $T/o.lst && grep -q '^FM_K3_thr0.5_geometric-ctrl_seed6/6/results.json\$' $T/o.lst && grep -q 'rollout_0.gif' $T/o.lst && ! grep -q '^logs/' $T/o.lst"
check org_raw_rebuild             bash "$J/logarch_raw_rebuild.sh" dry_o
check org_finalize_swap           env MAP="$OM" bash "$LS" finalize dry_o
check org_raw_has_no_thesis_files bash -c "for a in $D/dry_o/raw/archives/*.tar.zst; do zstd -dc \"\$a\" | tar -tf -; done > $T/raw.lst; ! grep -qE 'Efm_K3_mpc4_pid_stopgo_T0.5_u17cv2/|mix_uav_fm/H8_Dmodels.diffusion.FlowMatchingODE_9D/6|msgdpccproto/' $T/raw.lst && grep -q 'T0.5_oldtag9/6/results.json' $T/raw.lst"
check org_old_versions_gone       bash -c "[ ! -e $D/dry_o/raw_replaced ] && [ ! -e $D/dry_o/raw_rebuilt ] && [ -f $D/dry_o/raw/meta/ORGANIZED ]"
check org_publish_docs            bash -c "env MAP=$OM bash $LS publish-organized dry_o && for f in README.md NAMING.md RESTORE.md naming_map.tsv; do [ -f $D/dry_o/\$f ] || exit 1; done && [ -f $D/dry_o/curated/UAV-corridor/models/FM_U-Net/README.md ] && grep -q 'TEST' $D/dry_o/README.md"
check org_check_drive_all         env MAP="$OM" bash "$LS" check-drive dry_o 0

# ── logs/ changes after archiving ────────────────────────────────────────────
check change_detected             bash -c "echo more >> '$FIX/logs/UAV_MIX/uav-corridor/mix_uav_fm/H8_Dmodels.diffusion.FlowMatchingODE_9D/6/losses.json' && txt=\$(bash $J/logarch_changes.sh dry_b); [ \$? -eq 3 ] && grep -q 'UAV_MIX/uav-corridor' $X/dry_b/meta/CHANGES.md && grep -q 'FORCE_UNITS=' $X/dry_b/meta/CHANGES.md && cp $X/dry_b/meta/CHANGES.md $T/CHANGES_detected.md"
check force_repack_heals          bash -c "FORCE_UNITS='UAV_MIX/uav-corridor' bash $J/logarch_pack_gdrive.sh dry_b && grep -q 'No changes' $X/dry_b/meta/CHANGES.md"
check drive_test_mode             bash "$LS" drive-test

echo; echo "log-archive dry run — $(date '+%Y-%m-%d %H:%M')  ($T)"
printf '  %s\n' "${ROWS[@]}"
echo "  ─ $((N - FAILS))/$N passed"
if [ "${KEEP:-0}" != 1 ] && [ "$FAILS" -eq 0 ]; then rm -rf "${T:?}"; else echo "  kept: $T"; fi
[ "$FAILS" -eq 0 ]
