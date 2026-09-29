#!/usr/bin/env bash
# make_fixture.sh <source repo> <target dir> — a small fake FM-PCC checkout for the dry run:
# the log-archive tools copied from <source repo>, plus a ~20 MB logs/ that mirrors the real layout (split trees,
# training runs with seed folders, eval variants with all_seeds/ + plots/, UAV eval cells with tags, before-fix
# snapshots, abandoned lines, loose files, renders, periodic checkpoints, a symlink, an empty dir, odd names) and a
# fake thesis/dev-log corpus that cites some of the runs. Nothing outside <target dir> is written.
set -o pipefail
SRC="${1:?source repo}"; FIX="${2:?target dir}"
mkdir -p "$FIX/Slurm_Codes/sbatch" "$FIX/Slurm_Codes/download_remote_logs" "$FIX/logs_in_develop/Gen15" \
         "$FIX/Data_Analysis/DA_in_Paper/analysis" "$FIX/logs_in_develop/Writing/Working_Space/data_status" || exit 1
cp -r "$SRC/Slurm_Codes/sbatch/log_archive" "$FIX/Slurm_Codes/sbatch/"
cp "$SRC/Slurm_Codes/download_remote_logs/logarch_local.sh" "$FIX/Slurm_Codes/download_remote_logs/"
L="$FIX/logs"
rnd() { mkdir -p "$(dirname "$1")"; head -c "$2" /dev/urandom > "$1"; }
txt() { mkdir -p "$(dirname "$1")"; seq 1 "$2" | sed 's/^/value /' > "$1"; }
train_run() {   # $1 model dir: seeds_config + seed 6 with configs, losses, best + periodic checkpoint, config snapshot
    txt "$1/seeds_config.json" 5
    for f in dataset_config.json trainer_config.json model_config.json losses.json; do txt "$1/6/$f" 30; done
    rnd "$1/6/losses.pkl" 20K; rnd "$1/6/state_best.pt" 2M; rnd "$1/6/state_100000.pt" 2M
    txt "$1/6/config_snapshot_uav/uav.py" 40
}
# split tree UAV_MIX: loose file, a training run, three eval cells (thesis-cited, dev-log tag, uncited)
txt "$L/UAV_MIX/README.txt" 10
train_run "$L/UAV_MIX/uav-corridor/mix_uav_fm/H8_Dmodels.diffusion.FlowMatchingODE_9D"
for tag in u17cv2 oldtag9; do
    E="$L/UAV_MIX/uav-corridor/plans/mix_uav_fm/H8_Dmodels.diffusion.FlowMatchingODE_9D/Efm_K3_mpc4_pid_stopgo_T0.5_$tag/6"
    txt "$E/results.json" 200
    for i in $(seq 0 19); do txt "$E/diagnostics/rollout_${i}_stats.json" 8; done
    rnd "$E/diagnostics/rollout_0.gif" 1M; rnd "$E/rollouts.npz" 1M
done
E="$L/UAV_MIX/uav-s_curve/plans/mix_uav_mf/H8_Dmodels.mf_diffusion.MeanFlowODE_9D_dp0.5_bbunet/Emf_K10_mpc4_mjpc_T0.5_u7hg/6"
txt "$E/results.json" 100; rnd "$E/diagnostics/rollout_0.gif" 512K
# split tree avoiding-d3il: DPCC training run, an eval variant (2 seeds + all_seeds + plots), a Bf_ snapshot, an abandoned line
train_run "$L/avoiding-d3il/diffusion/H8_K2_Dmodels.GaussianDiffusion_aw10"
V="$L/avoiding-d3il/plans/diffusion/H8_K2_Dmodels.GaussianDiffusion_aw10/H8_K2_T0.5_Dmodels.GaussianDiffusion_msgdpccproto"
for s in 6 7; do txt "$V/$s/config_snapshot_avoiding-d3il/avoiding-d3il.py" 50; rnd "$V/$s/results/ep_0.pkl" 300K; txt "$V/$s/results/metrics.json" 40; done
txt "$V/all_seeds/summary.csv" 30; rnd "$V/plots/success.png" 100K
S="$L/avoiding-d3il/plans/flow_matching_v3_alphaflow(Bf_U3)/H8_Dflow_matcher_v3_alphaflow.models.AlphaFlowODE_aw10/E1"
txt "$S/6/config_snapshot_avoiding-d3il/avoiding-d3il.py" 20; rnd "$S/6/results/ep_0.pkl" 200K
A="$L/avoiding-d3il/plans/flow_matching_v3_imeanflow(U9)/H8_Dflow_matcher_v3_imeanflow.models.iMF_aw10/E1"
txt "$A/6/config_snapshot_avoiding-d3il/avoiding-d3il.py" 20; rnd "$A/6/results/ep_0.pkl" 200K
# whole units: abandoned visual avoiding, loose-only folders, odd names, expert renders that must stay
train_run "$L/avoiding-d3il-visual(1e4_EMA_changed)/fm_visual_avoiding/H8_Dfm_visual_avoiding.models.VisualFM"
txt "$L/solver_bench/25121/bench.csv" 20
mkdir -p "$L/hardflow/avoiding-v0/empty_dir"
txt "$L/hardflow/avoiding-v0/run 1/metrics (final).json" 30
ln -s "run 1/metrics (final).json" "$L/hardflow/avoiding-v0/latest.json"
rnd "$L/uav_expert_data/corridor/expert_references/demo.gif" 256K; rnd "$L/uav_expert_data/corridor/ep_0.npz" 128K
txt "$L/notes_top.txt" 5
# corpus: the thesis cites one eval cell by path, a dev log names the DPCC run and the u7hg tag
printf 'Table 6.2 reads logs/UAV_MIX/uav-corridor/plans/mix_uav_fm/H8_Dmodels.diffusion.FlowMatchingODE_9D/Efm_K3_mpc4_pid_stopgo_T0.5_u17cv2/6/results.json\n' \
    > "$FIX/Data_Analysis/DA_in_Paper/analysis/INDEX.md"
printf 'baseline trained in avoiding-d3il/diffusion/H8_K2_Dmodels.GaussianDiffusion_aw10/6\ns-curve wave tag u7hg finished\n' \
    > "$FIX/logs_in_develop/Gen15/CHANGELOG_fixture.md"
printf '# runbook fixture\n' > "$FIX/logs_in_develop/Writing/Working_Space/data_status/RUNBOOK_fixture.md"
echo "$FIX"
