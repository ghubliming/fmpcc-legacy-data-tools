# The archived experiment data — a rough guide

Rough on purpose: enough to find your way, not a specification. The archive itself carries its own `README.md`,
`NAMING.md` and `RESTORE.md` at the top — read those for details.

## Where it is

Google Drive, `FMPCC_logs_backup/full_20260927/` — a snapshot (2026-09-27) of the whole `logs/` folder of the
training cluster (~300k files, ~100 GiB before compression). Every file is in there exactly once.

```
full_20260927/
├── README.md  NAMING.md  RESTORE.md  naming_map.tsv
├── curated/<task>/models/<name>/          training runs that matter (weights, losses, configs)
├── curated/<task>/evaluations/<name>/     evaluation runs that matter (results, plots, logs)
└── raw/                                   everything else: development runs, tests, abandoned work
```

Tasks: `D3IL-avoiding`, `D3IL-aligning`, `UAV-corridor`, `UAV-s-curve`, `UAV-pillars`.

## Get a folder

```bash
rclone copy gdrive:FMPCC_logs_backup/full_20260927/curated/D3IL-avoiding/evaluations/<name> .
zstd -dc <name>.tar.zst | tar -xf -        # → <name>/<seed>/...
```

Each curated folder holds a short `README.md`, plain copies of its small summary files, and one `.tar.zst` with
everything. For `raw/`, search the file lists in `raw/meta/manifests/` first, then fetch only that archive
(`RESTORE.md` shows how).

## Read a folder name

`Analytic-MeanFM_K2_thr0.5_20ep_seeds6-10` = model · step budget · projection threshold · episodes · training seeds.

| part | roughly |
|---|---|
| `FM` · `Analytic-MeanFM` · `CI-MeanFM` · `Diffusion` | the generative model (flow matching · MeanFlow · consistency-interpolated MeanFlow · diffusion baseline) |
| `U-Net` · `SiT` · `DiT` | network backbone |
| `K2` | network evaluations per plan; `trainedK20` = a diffusion model trained for that budget |
| `thr0.5` | activation threshold of the constraint projection |
| `2ep` · `20ep` | evaluation episodes per seed |
| `seed6` · `seeds6-10` | training seeds (one sub-folder each) |
| `geometric-ctrl` · `MJPC` · `tilt` · `hump` | quadrotor controller · corridor scene variant |

`naming_map.tsv` (in the archive) maps each name back to the original `logs/…` path — the old scripts expect that path.

Until 2026-09-30 the `Analytic-MeanFM` folders were called `MeanFM_…` (the thesis renamed the label); `curated/_meta/RELABEL_20260930_analytic_meanfm.tsv` lists old → new.

## What the files are, roughly

| file | roughly |
|---|---|
| `results/halfspace_<geometry>/<variant>.npz` | obstacle-avoiding evaluation, one file per projection variant and obstacle layout: per-episode arrays such as `n_success`, `n_success_and_constraints`, `n_violations`, `n_steps`, `avg_time` |
| other `*.npz` | per-rollout metrics and trajectories. Open with `numpy.load(path, allow_pickle=True)` and look at `.files` |
| `results.json` | quadrotor evaluation summary per variant (flights, goal reached, collisions, steps, timing) |
| `diagnostics/rollout_<i>_stats.json` | per-flight timing and outcome (quadrotor) |
| `*.csv`, `all_seeds/`, `plots/`, `*.png`, `*.svg` | summaries and figures written by the evaluation |
| `losses.json` / `losses.pkl` | training curve |
| `state_best.pt`, `state_<N>.pt` | PyTorch weights (best / periodic) |
| `*_config.json`, `*_config.pkl`, `seeds_config.json`, `args.json` | configuration of the run. The `.pkl` files need the old development code to unpickle; the `.json` twins do not |
| `config_snapshot_*/` | a copy of the configuration at launch — its **time stamp** is reliable, its content may not match what ran |
| `*.log`, `realtime_*.log` | console output, per-step timing |
| `*.gif`, `*.mp4`, `_clean_*_runlogs/` | renders and clean-up logs — ignore |

Variant names inside `results/`, roughly: `diffuser` = no projection · `dpcc-r/-c/-t-tightened` = projection at
every step with the random / cost / consistency candidate rule, on tightened constraints · `hardflow_sls-*` =
projection of the predicted end point only. Model class names in old folder names: `GaussianDiffusion` = Diffusion,
`FlowMatchingODE` = FM, `MeanFlowODE` = Analytic-MeanFM, `AlphaFlowODE` = CI-MeanFM.

## Aggregate many folders

1. Unpack the folders and move them back to their original paths (the loop at the end of the archive's `RESTORE.md`
   reads `naming_map.tsv`).
2. Run the matching pipeline in `analysis/batch_pipelines/` on that tree: `DA_Code_v3` (avoiding), `DA_VA_v2`
   (aligning), `DA_UAV_v1` (quadrotor). Each has a `main_da_batch.py --parent-path <logs/...>`; the jobs in
   `sbatch/` show the arguments that were used. `--no-plots` gives only the CSVs.
3. Browse the CSVs with the page in `analysis/viewers/`.

The last full batch run (2026-09-27, one batch per task) is already on Drive: `FMPCC_logs_backup/analysis_csv_20260927/` (its `README.md` says which file is which).

The sbatch files call the pipelines by their original location (`Data_Analysis/<pipeline>/`) — adjust that path.

## Old data vs. the released code

The data was written by the development code. The released code ([`ghubliming/fmpcc`](https://github.com/ghubliming/fmpcc))
has a different layout: each evaluation writes one `.npz` per variant plus the resolved configuration (`.yaml`) and a
figure under `<run>/eval/`. Names and keys differ; nothing converts old result files. Old checkpoints can be converted
with `tools/bridge/convert.py` (see its README).
