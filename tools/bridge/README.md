# P7 bridge — one old job through the new code

Not part of `Released/`. On the cluster, from the root of the old repository, in the FMPCC environment; the
release is put on `PYTHONPATH` (no install).

## 0 · One command: `p7_avoiding_meanfm.sh`

```bash
Slurm_Codes/submit.sh logs_in_develop/Rebuild_Repo_Agent/bridge/p7_avoiding_meanfm.sh [cell] [seed]
```

Steps 1–3 below for one D3IL-avoiding MeanFM (U-Net) cell. The default is the K2 cell of 2026-09-06
(`…_A1_B4_…_msghfmink_A1_mfunet_s6`, η 1.0, four candidates, SLSQP), seed 7; that cell has no seed 6. K, η and
candidates come from the cell name; geometries, variants, tightening and episodes come from the old result
files. The output goes to `logs/bridge_p7/<stamp>/`, and the log ends with `P7 VERDICT: AGREE`, `DIFFER`, or
`AGREE ON DECISIONS, PATH DRIFT` (decisions equal, paths beyond 1e-5, e.g. a different GPU type). Another cell
of the same training run: pass its plans folder name and a seed, e.g. `…_K3_…_A1_B4_…_msgR46t63 6`.

## 1 · Convert the checkpoint of the picked job

```bash
B=logs_in_develop/Rebuild_Repo_Agent/bridge
python $B/convert.py --env <avoiding|aligning|uav> --model <diffusion|fm|meanfm|ci_meanfm> \
    --old <old training run>/<seed> --which <best|step> --data <demonstrations> [--scene corridor|s_curve] \
    --out logs_bridge/<env>/<model> --seed <seed>
```

| family | `--old` (seed directory) | `--which` | `--data` |
| :-- | :-- | :-- | :-- |
| avoiding diffusion | `logs/avoiding-d3il/diffusion/H8_K<K>_Dmodels.GaussianDiffusion_aw10/<s>` | best | `d3il/environments/dataset/data/avoiding/data` |
| avoiding FM | `logs/avoiding-d3il/flow_matching_v3_ode_selectable/H8_Dmodels.diffusion.FlowMatchingODE_a1.5_b1.0_aw10/<s>` | best | same |
| avoiding MeanFM | `logs/avoiding-d3il/flow_matching_v3_meanflow/…_bbunet_…/<s>` | best | same |
| avoiding CI-MeanFM | `logs/avoiding-d3il/flow_matching_v3_alphaflow/…_bbunet_…_ae0.2_…/<s>` | 80000 | same |
| aligning (all four) | `logs/aligning-d3il-visual/mix_visual_aligning_<engine>/<train id>/6` | best; CI-MeanFM 100000 | — (the run's normaliser pickles) |
| UAV (all four) | `logs/UAV_MIX/uav-<scene>/mix_uav_<engine>/<train id>/6` | best; CI-MeanFM 100000 | `data/uav_fm/v1/<scene>` |

UAV-pillars flies the avoiding checkpoints: convert them as `avoiding`.

## 2 · Evaluate the same configuration with the release

```bash
python Released/scripts/evaluate.py Released/configs/eval/<config>.yaml --run logs_bridge/<env>/<model> --tag bridge \
    --set seeds=[<s>] steps=<K> activation_threshold=<η> <geometry/geometries> "variants=[...]" <tightened> <episodes/flights>
```

Name mapping: geometries `top-left-hard` → `top_left_hard` (etc.), `combined_5[-tightened]` → `combined_5[_tightened]`;
variants `diffuser` → `unguided`, `dpcc-<r|c|t>` → `per_step:<random|cumulative_cost|temporal_consistency>`,
`hardflow_sls-<r|c|t>` → `endpoint:<rule>` (`hardflow_new-*` is the IPOPT endpoint, not in the release), `-tightened` → `tightened=[true]` (avoiding,
aligning) or `tightened=true` (UAV). The quadrotor keeps the random stream across flights and variants: give the
variant list of the old job in its order and the old flight count (corridor jobs of record flew 12: `flights=12`).

## 3 · Compare

```bash
python $B/compare.py --env <avoiding|aligning|uav> --old <old variant npz> --new <new variant npz>
```

Decisions must agree exactly (`==`), trajectories within drift (`--drift`, default 1e-5); `~~` rows are
accumulated quantities, `..` rows time. `AGREE` / `DIFFER` at the end.

## Cells that cannot replay (LEDGER §4, §14)

- D3IL-avoiding diffusion and FM under temporal consistency (the old policy stored the wrong previous plan).
- D3IL-aligning cells in which the old circuit breaker skipped projections (`projection_health` in the old JSON).
- Quadrotor variants that follow, in their job, a variant the release does not run (the single-candidate
  `hardflow_new` without a rule suffix): the random stream differs from there on. Corridor waves C1, C2, C5 and the first job of C4
  replay in full, C3 and the second job of C4 up to their per-step variant; every s-curve phase (A, B, C) replays.
- The MuJoCo MPC cells need the release installed in the second environment as well.
