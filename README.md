# fmpcc-legacy-data-tools

A **parking place** for the tools and scripts of the FM-PCC development repository (private), plus a rough
guide to the archived experiment data. Nothing here is maintained.

- **The code of the method** is a separate repository: [`ghubliming/fmpcc`](https://github.com/ghubliming/fmpcc).
- **The archived experiment data** (Google Drive) is explained, roughly, in [`DATA_GUIDE.md`](DATA_GUIDE.md).
- **Where every file came from:** [`PROVENANCE.md`](PROVENANCE.md).

## Read this first

- Every file is an **unedited copy** from the development repository. Paths inside the scripts are the original ones
  (`/workspaces/FM-PCC`, `Data_Analysis/…`, `logs/<original path>`, cluster home folders, partition names).
- Many scripts import the development code (models, environments), which is **not** in this repository. They are kept
  for their logic. Scripts marked *standalone* need only numpy / pandas / matplotlib (or bash + rclone / zstd).
- Nothing is adapted to the released code (`fmpcc`) or to the renamed folders on Google Drive. The logic is sound;
  the paths and imports may need rework.
- `tools/slurm/env_install/reference/*.py` are Colab exports: they contain notebook `!` lines and are not valid Python on their own.
- `outdated/` is **outdated, not used and unreliable** — kept only as a record.

## What is here

| folder | what | standalone? |
|---|---|---|
| `analysis/batch_pipelines/` | turn evaluation result folders into batch CSVs: `DA_Code_v3` (obstacle avoiding), `DA_Visual_Aligning` + `DA_VA_v2` (visual aligning), `DA_UAV_v1` (quadrotor); `sbatch/` = the cluster jobs that ran them | yes |
| `analysis/viewers/` | browser pages (HTML/JS) for the batch CSVs; serve the folder over HTTP (`python3 -m http.server`), `file://` does not work | yes |
| `analysis/npz/` | inspect result `.npz` files, compare planning horizons, trajectory viewer (HTML); `docs/` = usage notes | yes |
| `analysis/result_loaders/` | the per-model `load_results_*` scripts, UAV scene-summary aggregation, visual-aligning export | mostly no |
| `analysis/gates/` | pilot checks: pass/fail of a small run read from its eval files, before a large run is launched | mostly no |
| `analysis/one_off/` | single analyses of past batches, as examples of reading raw result folders | yes, batch-specific |
| `tools/log_archive/cluster/` | cluster `logs/` → verified `.tar.zst` archives → Google Drive; triage, renaming, change check, dry-run tests (see its README) | yes (bash, python stdlib, rclone, zstd) |
| `tools/log_archive/laptop/` | pull / organise the archive from a laptop or container | yes |
| `tools/log_archive/cleanup/` | folder-tree snapshot, GIF / weight / log clean-ups, split files > 100 MB | yes |
| `tools/slurm/` | submit wrappers (`submit.sh`, `submit_after.sh`), job / pipeline templates, environment check, dataset extraction job, cluster notes, environment install scripts | yes, cluster-specific |
| `tools/checkpoints/` | rename module paths inside old pickled checkpoints (patch / revert); regenerate a stale `model_config.pkl` | no |
| `tools/bridge/` | convert an old checkpoint to the released code and compare old vs. new evaluation results | no (needs both codes) |
| `tools/release_checks/` | smoke test of every code path of the released code | needs `fmpcc` |
| `tools/benchmarks/` | ODE-solver speed / accuracy benchmarks and grid searches (v1–v4); constraint-projection solver benchmark; dynamics fit | no |
| `tools/plots_and_media/` | dependency-free SVG canvas + small 3D scene renderer, SVG → PNG / PDF, MuJoCo scene rendering, GIF frame extraction, figure helpers (with an exact Wilcoxon test), environment / constraint plots, quadrotor GIF and overview-plot generators | partly |
| `tools/uav_data_checks/` | checks of generated quadrotor demonstrations (statistics, blends, pillar scene, a mini training sanity run) + the data-preparation jobs | no |
| `tools/diagnostics/` | per-step timing logger, evaluation artefact writer, a probe of how informative the visual latent is | no |
| `tools/writing/` | LaTeX-free thesis tooling (mechanical draft checks, number audit, release builder, change carry-over between drafts, chapter tree) and a Quarto slide-deck build; they expect the original draft folders | yes, folder-specific |
| `tools/misc/` | `.py` → `.ipynb` converter | yes |
| `outdated/temp_bash/` | launch / fetch drivers of past evaluation campaigns — **outdated, unreliable** | no |

## Licence

MIT, see [`LICENSE`](LICENSE).
