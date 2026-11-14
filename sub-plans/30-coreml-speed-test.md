# Sub-plan 30: Core ML conversion and iPhone 14 speed test for the Coralscapes segmenter (issue #11)

Roadmap position: **M3**, the go/no-go gate for #12 (the Core ML bridge). It follows `docs/denr-tb-2019-04-alignment.md`
§7 and §10. Method, thresholds and the license finding: `../docs/coralscapes-coreml-speed-test.md`.

## Starting point

- The cover segmenter (`EPFL-ECEO/segformer-b5-finetuned-coralscapesv2-1024-1024`, rev `c61183ec`) runs only on
  a laptop (notebook 28, #7). Its speed on the iPhone 14 is unmeasured.
- No Mac: Swift compiles only on Codemagic, and coremltools can't run predictions off macOS.

## Decisions (approved with the plan, 2026-11-14)

| # | Decision |
|---|---|
| D1 | The thresholds in the doc's §2 were fixed before measuring (defaults accepted). |
| D2 | The benchmark is a **dev screen inside ReefSight** (Settings → Diagnostics), so its Swift is reusable by #12. |
| D3 | The int8-weight arm is **included** (`INCLUDE_W8`, on by default in notebook 29). |
| D4 | Models reach the phone as an **AirDropped zip**, not as app assets. |
| D5 | Fidelity is checked by a **round trip**: the phone writes class maps, notebook 29 part 2 compares them with PyTorch. |
| D6 | The Swift stays in `AppDelegate.swift` (no `project.pbxproj` edits), on channel `reefsight/coreml_bench`. |

## What was built

- `machine-learning-pipeline/notebooks/29_coralscapes_coreml_export.ipynb` (written, not run). Part 1 converts,
  saves the reference and packs `coralscapes_bench_<RUN_ID>.zip`. Part 2 compares the phone's results and prints the
  go/no-go table.
- `lib/services/coreml_benchmark.dart`:
  - `BenchManifest` (validated, safe paths only) and `extractBenchPackage`, which checks every entry before writing
    and refuses `..`, absolute paths and symlinks;
  - `LatencyStats`, `ComputePlanSummary`;
  - the `CoreMlBench` interface plus `NativeCoreMlBench`;
  - `BenchmarkRunner`: `runArm` / `runMatrix` / `runSustained` / `writeReport`, with `log.txt` in the results folder.
- `lib/screens/coreml_benchmark_screen.dart`: load, run matrix, sustained test (model, compute units, 1/5/20/30 min),
  stop, share results. Holds the screen awake while running.
- `ios/Runner/AppDelegate.swift` `CoreMlBench`, one serial queue:
  - `compile`, `load` and `unload`;
  - `predict`, which times `prediction(from:)` only and writes uint8 argmax and confidence maps;
  - `computePlan` (`MLComputePlan`, iOS 17.4+) and `footprint` (`phys_footprint`).
- Settings → Diagnostics → **Core ML benchmark**.
- Tests: `test/services/coreml_benchmark_test.dart` (26) and `test/screens/coreml_benchmark_screen_test.dart` (2).

## Review fixes (code and security review, 2026-11-14)

- Swift: `.cpuAndGPU` is behind `#available(iOS 14)` (the deployment target is 13.0; this would have broken the
  Codemagic build). NaN or infinite logits are counted (`non_finite_pixels`, which invalidates an arm) instead of
  trapping. Non-float32 logits are refused rather than read element by element. `utsname.machine` is recorded, so
  the report proves which phone it came from.
- Peak memory is sampled natively every 20 ms during load and each prediction: the transient peak jetsam counts,
  which before-and-after readings miss.
- Each arm records its heat at start and end, and the matrix waits (up to 10 min) for `fair` before each arm, so
  later arms aren't timed heat-soaked. Stop is honoured inside an arm, and leaving the screen stops a run.
- `bench_results.json` is rewritten after every arm, and the sustained run writes `sustained_partial.json` every
  20 runs, so an OS kill keeps the data. The sustained run makes one untimed warm-up call first.
- Unzip: size caps (1 GB per entry, 3 GB in all, 1 MB manifest), extraction into a temporary folder renamed on
  success, the folder named by the validated `run_id` (not the zip's file name, which could be `...zip`), and the
  work folder moved to Application Support (not backed up to iCloud).

## To do (in order)

1. **Codemagic build** of this commit, checked before anything else: the Swift has never been compiled.
2. Run notebook 29 part 1 in the Linux container. Optionally first copy 4–8 Alegria photos from the Nov 15 dive into
   `datasets/reefsight_analysis/alegria_2026-11-15_samples/`.
3. On the iPhone 14 (doc §3 protocol), **minimum first** (2026-11-15: the full matrix was closed by iOS after a few
   minutes, probably for memory; unconfirmed):
   - Load package (the zip reaches the phone through iCloud Drive or Google Drive → Files; AirDrop needs a Mac).
   - **Quick test**: `cs_512_w8` on CPU + Neural Engine, no compute plan, 10 timed runs.
   - Sustained test, which defaults to the same lightest model; 5 min is enough for a first heat reading.
   - Share results. A run iOS closed can be shared later from **Earlier results**; its `log.txt` logs each step
     before it starts, so the last line names the step that died.
   - The full matrix (lightest model first) only once the quick test works.
4. Run notebook 29 part 2; fill in the doc's §5; decide go / post-dive only / no-go; comment on #11.
5. **License:** ask EPFL-ECEO about the NVIDIA `mit-b5` terms before #12 ships any weights (doc §4).
