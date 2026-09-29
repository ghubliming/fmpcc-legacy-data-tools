# Release smoke test — every path runs, nothing is kept

Not part of `Released/`. One Slurm job runs every training and evaluation path of the release for a few steps
under a line tracer, then reports what ran, what failed and which lines of the release never ran.

```bash
Slurm_Codes/submit.sh logs_in_develop/Rebuild_Repo_Agent/smoke/smoke_release.sh      # from the repository root
```

**Options (env):**
- `MJX_ENV=<conda env with requirements-mjx.txt>` adds the MuJoCo MPC controller path.
- `KEEP=1` keeps the scratch copy.
- `AVOID_DATA` / `ALIGN_DATA` override the D3IL data folders (defaults: `d3il/environments/dataset/data/…`).
- `CONDA_ENV` (default `FMPCC`).

| phase | what runs (seed 6) |
| :-- | :-- |
| data | the quadrotor demonstration generator: 3 flights per scene |
| training | 4 steps for each of avoiding, aligning, UAV corridor and UAV s-curve × diffusion / FM / MeanFM / CI-MeanFM. Every branch of the trainer runs: warm-up and cosine, EMA, periodic and best checkpoints, held-out loss. Plus a resume (4 → 6 steps) and CI-MeanFM at α_end 0 (its JVP branch) |
| evaluation | every evaluation configuration (avoiding, UAV-pillars, aligning, UAV corridor tilt / hump, UAV s-curve) × every model, all variants and tightenings, 1 episode / context / flight of 3 control steps, K 2 at η 1.0 so that endpoint projection has a guiding step. It also covers the checkpoint choices best / latest / numeric, EMA and raw weights, `--tag`, and the test contexts |

**The log ends with:**
- `ok` / `FAIL` / `skip` per process;
- the traced lines of `fmpcc/` and `scripts/` per file, with the line ranges that never ran; the vendored D3IL and MJX code as totals;
- the repository check;
- `SMOKE VERDICT: PASS | FAIL`.

**Nothing is written into the repository, and nothing can be overwritten:**
- **Scratch copy:** everything runs on a copy of `Released/` in `$TMPDIR` (or `/tmp`), `fmpcc_smoke_<job id>`. It is created fresh (the job stops if it exists) and removed on exit; the job also checks that `fmpcc` imports from it.
- **Data are only read:** the D3IL data are reached through symlinks. The aligning training split is cut to 3 episodes in the copy only.
- **No stray files:** `PYTHONDONTWRITEBYTECODE=1`, W&B off, and the matplotlib cache stays in scratch.
- **Repository check:** `git status` is compared before and after the job, Slurm logs aside.
- **Only output:** the Slurm log.

`trace_lines.py` is standard-library Python: `run` executes a script under `sys.settrace` and records the lines of
files under the copy; `report` compares them with the executable lines of every file. Checked in the container on
a mock repository: argument passing, ok / FAIL / skip bookkeeping, the report, removal of the scratch copy and an
unchanged `git status`.

## Runs

| date | job | log | verdict |
| :-- | :-- | :-- | :-- |
| 2026-09-28 | 26303 | [`evidence/18_10_25_smoke_release_26303.log`](evidence/18_10_25_smoke_release_26303.log) | **PASS**: 41 ok, 1 skip (MuJoCo MPC, no `MJX_ENV`); own code 2146/2258 lines ran (95.0 %), vendored D3IL 54.7 %; repository unchanged. Never ran: the MJX tracker and error / abort / W&B / success branches that 3-step runs cannot reach |
