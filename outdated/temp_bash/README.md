# `Slurm_Codes/archived_temp_bash/` — archived one-off submit drivers

Everything that sat in `Slurm_Codes/temp_bash/` on 2026-09-27: the per-wave eval, fetch and pipeline drivers of
2026-09-09 … 2026-09-24, plus the `_*` helper files their pipelines generated. They are archived here so the run
history is backed up in git. `temp_bash/` itself stays gitignored scratch for the next driver.

* **Run history, not entry points.** The real entry points are `Slurm_Codes/sbatch/`, submitted with
  `Slurm_Codes/submit.sh`.
* **Verbatim.** Every file is byte-identical to its `temp_bash/` copy (md5-checked at the move). Only the folder
  changed. Do not edit them.
* **Old path → new path.** File names are unchanged: `Slurm_Codes/temp_bash/<file>` is now
  `Slurm_Codes/archived_temp_bash/<folder>/<file>`, with the folder from the index below. Dev logs, runbooks and
  code comments still cite the old path.
* **Re-running.** Paths inside the scripts still point at `Slurm_Codes/temp_bash/` (usage lines, `HERE=`, sibling
  drivers, generated helpers). Copy a driver back into `Slurm_Codes/temp_bash/`, check it against the current code,
  then run it. The pipelines rewrite their `_*` helpers there at run time.
* `README_temp_bash_original.md` is the folder's old README as of 2026-09-24: why the drivers exist, and the naming
  and validation convention.
* Dropped at the move: `temp_bash/__pycache__/`, seven `.pyc` caches of the `_*.py` helpers. One was a stale compile
  of `_r37_eval.py`, the earlier name of `_rw23_eval.py`.

## Layout

| folder | dates | what |
|---|---|---|
| `uav_gen15_U11-U17/` | 09-09 … 09-19 | Gen15 UAV: five-missions close-out, U11–U16 corridor probes, U13 threshold guard, U17 pillars_xl (abandoned) |
| `uav_p23_paper_runs/` | 09-22 … 09-24 | UAV paper runs: U19 corridor v3 → P23 waves (R33) with master chain and path fetch · U18 R39 pillars live · R44 s-curve |
| `thesis_pipelines/` | 09-17 … 09-23 | thesis-ledger pipelines: R8 · 09-18 pending · 09-22 all-lacking · 09-23 must-need · 09-23 red wave, with their `_lr22_*` `_mn23_*` `_rw23_*` helpers |
| `thesis_figures/` | 09-18 … 09-20 | v3 figure-artefact fetch waves 1–3 · R24 Fig 6.3 diffusion K=2 panel (two pipelines, `_fig63*` helpers, fetch) |

## Index

`Gen15/…` = `logs_in_develop/Gen15/…`, `data_status/…` = `logs_in_develop/Writing/Working_Space/data_status/…`,
`DA_in_Paper/…` = `Data_Analysis/DA_in_Paper/…`. A folder instead of a file means no log names the script.
**tracked** = the file was already in git before the move (force-added past the ignore rule).

### `uav_gen15_U11-U17/`

| file | wave | documented in |
|---|---|---|
| `resubmit_20260909_fixes.sh` | re-send the two unfinished arms: af pillars K=5, fm s_curve K=20 | `Gen15/Campaign_20260907_five_missions/` |
| `submit_20260910_diffusion_baseline_and_scurve_mirror.sh` | pillars diffusion baseline (train + eval), s_curve af and diffusion rows under `u7hg` | `Gen15/Campaign_20260907_five_missions/CLOSURE_20260910_uav_engine_ladder_final.md` |
| `eval_20260910_corridor_ball.sh` | U11 first corridor_ball run, 3 engines × K=2 / K=5 | `Gen15/U11/CHANGELOG_20260910_corridor_ball_and_geo_variant_override.md` |
| `eval_20260911_u12_injection.sh` | U12 corridor_ball_v2 fast injection (gates) | `Gen15/U12/CHANGELOG_20260911_corridor_ball_v2_on_trajectory.md` |
| `eval_20260911_u12_boundsfree_probe.sh` | U12 action-bound probe | same |
| `eval_20260911_u12_full_wave.sh` | U12 full wave | same |
| `submit_20260912_remaining.sh` | pillars diffusion `dpcc-t-tightened` finish + corridor_ball_v2 `bounds_free` diagnostic | `Gen15/Campaign_20260907_five_missions/`, `Gen15/U12/` |
| `eval_20260912_u13_injection.sh` | U13 corridor_ball_v3 (ball r 0.05) injection | `Gen15/U13/CHANGELOG_20260912_corridor_ball_v3.md` |
| `eval_20260912_u13_v32_injection.sh` | U13 corridor_ball_v3_2 (ball r 0.01) injection | same |
| `eval_20260912_u13_v32_fullproj.sh` | U13 v3_2 at full projection (threshold 0.5 → 1.0, with a `restore` mode) | `Gen15/U13/` |
| `restore_threshold_guard.sh` | dependency job that puts the threshold back to 0.5 after that eval | `Gen15/U13/` |
| `eval_20260912_u14_corridor_gate.sh` | U14 corridor_gate, slanted halfspace | `Gen15/U14/` |
| `eval_20260913_u15_corridor_gate_n1.sh` | U15 rev2 slide halfspace, `FMPCC_SAFE_EPS_FRAC=1.0` | `Gen15/U15/CHANGELOG_20260913_corridor_gate_n1.md`, `Gen15/U15/CHANGELOG_20260913_u15r2_slide_and_plots.md` |
| `eval_20260913_u16_corridor_v2_slide.sh` | U16 wide corridor v2 + slide, injection | `Gen15/U16/CHANGELOG_20260913_corridor_v2_wide_slide.md` |
| `eval_20260913_u16fix_pdes.sh` | U16 fix 1: geometry bound to the setpoint (`-pdes`) | `Gen15/U16/CHANGELOG_20260913_u16fix_pdes_binding.md` |
| `eval_20260913_u16fix2_tightened.sh` | U16 fix 2: `-pdes` + DPCC tightening | same |
| `eval_20260913_u16_corridor_v2_paper.sh` | U16 corridor_v2 paper wave, all engines | `Gen15/U16/CHANGELOG_20260913_corridor_v2_paper_run.md` |
| `eval_20260919_u17_pillars_xl.sh` | U17 pillars enlarged at test time, **abandoned** | `data_status/SLURM_RUNBOOK_20260919_pillars_enlarged.md`, `Gen15/U17/` |

### `uav_p23_paper_runs/`

| file | wave | documented in |
|---|---|---|
| `eval_20260922_u19_corridor_v3.sh` **tracked** | U19 corridor_v3 pilot and wave (tilt, ablation hump), tags `u19cv3t` `u19cv3ah` | `Gen15/U19/PLAN_20260922_U19_corridor_v3_z_slide.md` |
| `eval_20260923_p23_corridor_v3.sh` **tracked** | P23 corridor v3 paper waves C1–C5, both scenes (R33), tags `p23cv3t` `p23cv3ah` | `data_status/SLURM_RUNBOOK_20260923_uav_corridor_v3_pillars_v2.md` |
| `eval_20260923_p23_corridor_v3_master.sh` **tracked** | master chain that submits C1 → C5 one wave at a time (last link ran 2026-09-23) | same, and `Gen15/U19/PILOT_20260922_U19_gates_G1-G3.md` |
| `fetch_20260924_p23cv3_corridor_paths.sh` **tracked** | tar of the flown paths the corridor-v3 DA lacked | `logs_in_develop/Writing/Working_Space/v5/changelogs/v5.8_20260925_round2_fix.md` |
| `eval_20260923_p23_pillars_live.sh` **tracked** | R39 pillars-v2 live eval, MeanFM and CI-MeanFM × K1 / K2, tag `p23uavpv2live` | `Gen15/U18/CHANGELOG_20260923_U18_fix7_p23_live_real_eval.md` |
| `export_20260923_p23_pillars_live.sh` | tar of the R39 live results and plant sidecars | `Gen15/U18/CHANGELOG_20260923_U18_fix9_live_result_DA.md` |
| `eval_20260923_p23_scurve_R44.sh` | R44 s-curve: A raw grid, B projection, C controller; tags `p23scgrid` `p23scproj` `p23scmjpc`. The template for a tagged driver (marker = results suffix + job name + job-id ledger) | `data_status/SLURM_RUNBOOK_20260923_uav_scurve_R44.md` |
| `fetch_20260924_R44_scurve.sh` | one tar of every R44 tag: results, job logs, ledgers, md5 manifest | same, and `DA_in_Paper/analysis/DA_20260924_scurve_R44a_raw_grid.md` |

### `thesis_pipelines/`

| file | wave | documented in |
|---|---|---|
| `pipeline_20260917_r8_dpccproto_all.sh` | R8 DPCC-protocol rows: FM eval ∥ CI-MeanFM seeds 7–10 train → eval | `data_status/SLURM_RUNBOOK_20260917_dpcc_protocol_rows.md` |
| `pipeline_20260918_pending_all.sh` | every runnable confirmed-missing run of the 09-18 data audit | `data_status/SLURM_RUNBOOK_20260918_pending_runs.md` |
| `pipeline_20260922_all_lacking_runs.sh` | remaining thesis runs R2 · R26 · R30 · R31 · R16, plus opt-in groups | `data_status/SLURM_RUNBOOK_20260922_all_lacking_runs.md` |
| `_lr22_*` (13) | its generated wrappers (4 `.py`) and job scripts (9 `.sh`) | — |
| `pipeline_20260923_must_need.sh` | R16 (tab:va-models) + R36 (tab:avoiding-projectors), six jobs | same runbook, and `DA_in_Paper/analysis/DA_20260924_R16_R36_must_need.md` |
| `_mn23_*` (7) | its eval wrapper, three R16 job scripts, three R36 eval configs (`.yaml`) | — |
| `pipeline_20260923_red_wave.sh` | red wave: R2fix + R37a / R37b / R37c | same runbook, and `DA_in_Paper/analysis/DA_20260923_R2fix_R37_aligning.md` |
| `_rw23_*` (5) | its eval wrapper and four job scripts | — |

### `thesis_figures/`

| file | wave | documented in |
|---|---|---|
| `fetch_20260918_v3_figure_artefacts.sh` | wave 1: stage the artefacts for the v3 draft's missing figures | `Data_Analysis/analysis_results_checkpoint/LEDGER_20260918_v3_figure_artefact_fetch.md` |
| `fetch_20260919_v3_figure_artefacts_wave2.sh` | wave 2: the two cells wave 1 missed (F4, F5) | same |
| `fetch_20260920_v3_figure_artefacts_wave3.sh` | wave 3: every download item (§4) of the 09-20 pending list, which `data_status/PENDING_20260922_all_lacking_runs.md` replaced | same |
| `pipeline_20260919_fig63_diffusion_K2.sh` | R24 Option B: one job, no training. Dead route: that engine was the flow model under an old class name | `data_status/PENDING_20260919_fig63_diffusion_K2_panel.md` |
| `_fig63_panel_*` (2) | its eval wrapper and job script | — |
| `pipeline_20260919_fig63_K2_optionA.sh` | R24 Option A: train diffusion at K=2, then evaluate (chained) | same |
| `_fig63a_*` (4) | its train and eval wrappers and job scripts | — |
| `fetch_20260919_fig63_diffusion_K2.sh` | stage what Option A produced for the Fig 6.3 panel | same |
