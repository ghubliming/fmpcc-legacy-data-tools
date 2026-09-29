# log_archive tests

## 1. Offline dry run — the whole pipeline, no cluster, no Google

```bash
bash Slurm_Codes/sbatch/log_archive/tests/run_dryrun.sh        # KEEP=1 keeps the temp folder for inspection
```

Builds a small fake FM-PCC checkout (`make_fixture.sh`, ~20 MB: split trees, training runs with seed folders, eval
variants with `all_seeds/` + `plots/`, UAV eval cells with wave tags, `(Bf_…)` snapshots, abandoned lines, loose files,
renders, periodic checkpoints, a symlink, an empty dir, spaces and parentheses in names, a fake thesis/dev-log corpus)
and runs every step with inline "jobs", a folder as "Drive" (`stubs/rclone`) and `CLUSTER=local` for the laptop script.
`stubs/zstd` (gzip inside) is used only when no real zstd is installed. 42 checks, among them:
init job T1–T8 · laptop download test · raw upload staged **and** streamed (byte-identical) · resume = no-op ·
24 h hand-over (pause + continue) · route A rolling download + upload · triage labels (thesis by path, thesis/referenced
by wave tag, dev-log reference, snapshot + abandoned excluded, eval variant = one run with seeds 6 7, renders kept only
where expert references need them) · `set` · tampered plan refused · curate pause/continue/finish · renders and
`state_<N>.pt` left out of curated but present in raw · key files plain · full restore from "Drive" of every raw unit and
every curated folder · a file changed after archiving is detected and `FORCE_UNITS` heals it · `drive-test`.
It writes only into a temp dir and takes well under a minute, so it is fine to run on the cluster login node as well
(checks GNU tar/find/awk/date there before any real job).

## 2. Real smoke test on the cluster — a few small folders, every stage

**One command** (cluster login node, repo root; it submits the jobs, waits, runs the light steps, restore test via srun):

```bash
nohup bash Slurm_Codes/sbatch/log_archive/tests/smoke_cluster.sh > smoke.log 2>&1 &   # tail -f smoke.log
# UNITS="uav_naive solver_bench" … to pick folders · CLEAN=1 … to delete the smoke copy afterwards
```

Ends with a PASS/FAIL table (raw · triage · curate · changes · publish · restore). `smoke_cluster.sh` does exactly the
manual steps below:

After the one-time setup (plan §7: conda env `logarch`, rclone remote `gdrive` on the cluster and in the container):

```bash
# cluster, repo root
./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_selftest.sh               # T7 = can a compute node reach Drive?
ONLY_UNITS="uav_naive solver_bench" ./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_pack_gdrive.sh smoke_20260928
# container
L=Slurm_Codes/download_remote_logs/logarch_local.sh
bash $L drive-test                          # can THIS container reach Drive?
bash $L fetch-meta smoke_20260928
bash $L triage smoke_20260928               # read triage/TRIAGE.md
bash $L plan-curate smoke_20260928
# cluster
./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_curate.sh smoke_20260928
./Slurm_Codes/submit.sh Slurm_Codes/sbatch/log_archive/logarch_changes.sh smoke_20260928   # exit 0 = logs/ unchanged
# container
bash $L publish smoke_20260928
bash $L check-drive smoke_20260928 0        # downloads everything of the smoke stamp and restores it: must PASS
```

`uav_naive` (16 files, 19 MB) + `solver_bench` (4 files) take minutes. For a run with training runs, tiers and an
abandoned label, add `avoiding-d3il-visual(1e4_EMA_changed)` (484 files, 262 MB) to `ONLY_UNITS`.
Remove the smoke stamp afterwards: `rclone purge gdrive:FMPCC_logs_backup/smoke_20260928` and
`rm -r export_tmp/log_archive/smoke_20260928` on the cluster.
