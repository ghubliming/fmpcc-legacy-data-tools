# PROGRESS — organize v2 (plan: `PLAN_organize_v2.md`)

One line per step, newest last. Times UTC.

| date / time | step | status | note |
|---|---|---|---|
| 2026-09-27 22:32 | raw layer `full_20260927` | ✅ done | job 26289, 98 archives, 101.1 → 75.3 GiB, no changes |
| 2026-09-28 17:15 | plan v2 agreed + recorded | ✅ done | `PLAN_organize_v2.md` |
| 2026-09-28 17:18 | prep: rclone 1.60.1 + zstd 1.5.7 in container, `gdrive` config | ✅ done | drive-test PASS (4.9 TiB free) |
| 2026-09-28 17:20 | fetch `raw/meta` of `full_20260927` | ✅ done | 98 manifests, 227 receipts, 16 MB → `/workspaces/FMPCC_log_archive/full_20260927/raw/meta` |
| 2026-09-28 18:40 | 2 identify thesis data | ✅ done | 128 folders (106 evaluations + 22 training runs), 20.8 GiB, from the folder lists/tags in `DA_in_Paper` (sources.py + analysis scripts, INDEX rows of v5.31); backbone filters applied (MeanFM U-Net only at the DPCC protocol; FM = aw10 model); Table 6.3 five-seed cells incl. the reused low-budget `msghfmink` cells; pillars_v2 turbo replays excluded (not read by the analysis); 43 superseded folders (corridor v2 `u17cv2`, pillars_hg `u7hg`, old s-curve `u18sc`, 3.7 GiB) held for the author |
| 2026-09-28 19:10 | 3 naming draft | ✅ written | `naming_draft/NAMING_DRAFT.md` + `naming_map_draft.tsv`: 128 unique names in thesis wording (task / engine from model class / backbone / α_end / K / threshold / protocol / controller / scene / seeds), old path + tags + meaning per folder; 4 open points |
| 2026-09-28 19:20 | 3b naming decisions | ✅ author: "finish all the way" | Claude's proposals taken as decisions: (1) superseded 43 folders stay in raw, marked in the master MD; (2) words as drafted; (3) α_end of the aligning CI-MeanFM confirmed from the run config at build time; (4) launch-args folders kept as own folders |
| 2026-09-28 19:58 | 4 code + dry run | ✅ done | organize.py, raw_rebuild.sh, organize_pipeline.sh, curate rename, local organize-plan / finalize / publish-organized; dry run 55/55; α_end of aligning CI-MeanFM = 0.0 confirmed from its config |
| 2026-09-28 19:57 | 4b real plan on Drive | ✅ done | `full_20260927/triage/CURATE_PLAN.tsv.gz` (+sha256): 128 folders, 101,023 entries, 20.8 GiB, 2,909 key files |
| 2026-09-28 20:56 | 5 cluster jobs | ✅ done | pipeline 26305 → curate 26306 (128 folders curated, 0 failures) → raw rebuild 26307 (22 archives rebuilt without thesis folders, 32 units untouched) |
| 2026-09-28 21:40 | 5b finalize | ✅ done | coverage check PASS (every file in exactly one place); 22 archives swapped (md5 re-checked), 5 removed (all content curated); raw/ = 93 archives, meta 327 files 0 differences; old versions → Drive trash (30 days) |
| 2026-09-28 21:58 | 6 publish + restore check | ✅ done | master README, NAMING, RESTORE, naming_map, 128 folder notes, guides in raw/ curated/ (+ per task) triage/ and the Drive root; check-drive (2 raw units incl. a rebuilt one, 2 curated folders) PASS |
| — | open | author | the test copy `smoke_20260927_2035/` on Drive can be deleted (`rclone purge gdrive:FMPCC_logs_backup/smoke_20260927_2035`) — author's call |
