# `Slurm_Codes/temp_bash/` — one-off submission scripts

Throwaway submit drivers for a specific wave of jobs. **Not** part of the pipeline: the real entry
points stay in `Slurm_Codes/sbatch/` and are invoked through `Slurm_Codes/submit.sh`.

## Why these exist at all

Long `UAV_MIX_VARIANTS` strings pasted into a terminal **break**. The shell wraps around column
~160, and a line break landing inside the quotes splits a variant name — `dpcc-r-\n  geo_free` or
`dpcc-r-  geo_free`. `.strip()` in `mix_uav_test/eval_mix_uav.py` only trims the ENDS of a name, so
the mangled token fails the variant check and the job exits 2. Jobs **25555** and **25582** died
exactly that way, and **25580** died from a related paste accident (the env assignments and
`submit.sh` became two separate commands, so nothing was exported at all).

A script keeps every line short and gets the list right once.

## Convention

* one file per wave, named `<verb>_<YYYYMMDD>_<what>.sh`
* build variant lists as bash **arrays**, one name per line, joined at runtime — never a long literal
* **validate before submitting**: name shape, count, no whitespace, and any rule the eval enforces
  (e.g. HardFlow needs a `dpcc-*` companion at the same K; `hardflow_*` is degenerate at K < 3)
* always set `UAV_EVAL_HOURS=24` — the default is `N_SEEDS × 8` = **8 h** and it silently truncates
  (job 25553 died at 8:00:10 with a variant at trial 7/10)
* locate the repo root by walking up for `Slurm_Codes/submit.sh`, so the script runs from anywhere
* run with `bash Slurm_Codes/temp_bash/<script>.sh`

## Contents

| script | wave |
|---|---|
| `pipeline_20260917_r8_dpccproto_all.sh` | one dated login-shell driver: FM eval ∥ CI-MeanFM train, then dependent CI-MeanFM eval; maximum two concurrent jobs |
| `pipeline_20260922_all_lacking_runs.sh` | 2026-09-22 remaining thesis runs, ledger order: A R2 · B R26 (4 trainings → 5-seed eval) · C R30 · D/E R31 s-curve grid · F R16 · G/H opt-in. PLAN default; writes `_lr22_*` wrappers/jobs (read at job start). No pillars group by design. |
| `eval_20260923_p23_scurve_R44.sh` | 2026-09-23 R44 UAV-s-curve: A = raw grid (10 cells, tag `p23scgrid`), B/C gated on the author's pick (`PHASE=B SC_ENGINE= SC_K=`, `PHASE=C … SC_RULE=`). Modes plan/submit/status/export; the tag is also the job name (marker). Runbook `data_status/SLURM_RUNBOOK_20260923_uav_scurve_R44.md` |
| `fetch_20260924_R44_scurve.sh` | 2026-09-24 R44: ONE tar.gz of every R44 tag present (p23scgrid/p23scproj/p23scmjpc): result folders + job logs + ledgers, md5 manifest. Tar-only on the cluster |

The older scripts in this directory are retained only as local run history. The whole directory is
gitignored; the tracked copies predating that rule were removed from the Git index on 2026-09-17.
