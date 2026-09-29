# tools/slurm — setting FM-PCC up on the TUM I6 Slurm cluster

Copied as-is from the development repository, so paths, user and host names are the original ones (login node `vmknoll81`,
GPU node `i6-gpu-1`, partition `gpu-1-student`, home `/u/home/<user>`, repo `~/FMPCC/FM-PCC`) — replace them with your own.
Rough order for a new setup:

| step | read / run | what |
|---|---|---|
| 1 | `env_install/remote_setup_guide.md` | Miniconda, SSH key + clone of the repository, creating the `FMPCC` conda env |
| 2 | `env_install/requirements.txt` | the pinned package list of that env |
| 3 | `env_install/install_d3il_fix/install_d3il_fix.md` | D3IL installed for real (the Colab-style install leaves it broken) |
| 4 | `env_install/d3il_data_set_extraction/dataset_zip_note.md` · `extract_dataset_job.sh` | the D3IL dataset zip and where it goes · unzipping it as a job |
| 5 | `verify_env_job.sh` + `help_docus/how_to_run_verification_initial_setup.md` | the first job: does the env work on a compute node |
| 6 | `submit.sh` · `submit_after.sh` + `help_docus/submit_and_slurm_entry_notes.md` | how every job is submitted (log under `Slurm_Codes/logs/<date>/`), a dependent job, common Slurm commands |
| 7 | `guides/gpu_isolation/GPU_VERIFY_GUIDE.md` (+ `FIX_PLAN.md`) | **needed in every GPU job:** pin MuJoCo's EGL rendering to the GPU Slurm allocated (`CUDA_DEVICE_ORDER=PCI_BUS_ID`, `MUJOCO_EGL_DEVICE_ID`). Without it a job also touched another GPU and the cluster's IT sent a warning (job 21318: allocated GPU 2, used 0 and 2). The guide also shows how to check a running job |
| 8 | `guides/headless_mujoco/COLLECT_SH_GL_FIX.md` | physics-only jobs (no rendering): `MUJOCO_GL=disabled` — no GPU context at all |
| 9 | `templates/` · `help_docus/example_SLURM.sh` | starting points for new job and pipeline scripts |
| — | `env_install/UAV_mjpc_controller/install_UAV_mjpc_mjx_env.md` · `guides/mjpc_agent_server/PLAN.md` | optional: the second env `FMPCC_mjx` (JAX + MJX) for the MuJoCo MPC controller · building its `agent_server` binary without touching `third_party/` |
| — | `guides/env_clone/GUIDE_remote_env_setup.md` | optional: clone the env for a side project without risking the working one (written for HardFlow) |
| — | `env_install/reference/` | the original Colab-style install notebooks (the `.py` exports are not valid Python on their own) |
| — | `../log_archive/cluster/README.md` | the separate `logarch` env (zstd, rclone, python) and the Google Drive remote of the log archive |

The released code ([`ghubliming/fmpcc`](https://github.com/ghubliming/fmpcc)) has its own, shorter install section and `slurm/` scripts.
