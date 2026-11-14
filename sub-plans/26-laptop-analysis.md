# Sub-plan 26: Laptop analysis and results import (issue #7)

Roadmap position: **M2**, the seventh issue of the DENR-aligned version (`4Chronosx/reefsight-v2` #7).
It builds on #6's points, mapping and cover (`25-category-mapping-and-cover.md`) and carries out the
laptop route of `docs/denr-tb-2019-04-alignment.md` §4 and §10. The format and the reasoning behind it
are written up in `../docs/laptop-analysis-exchange-format.md`.

## Starting point

- #6 gave seeded points per frame, the CoralscapesV2 → TB map, `setPointModelLabel`,
  `refreshTransectCover`, and the v11 columns `analysis_status`, `model_id`, `analyzed_on` and
  `analyzed_at`. Nothing wrote labels yet, and nothing showed cover.
- `archive` 4.3.0 was already in `pubspec.lock` as a dependency of `image`.

## Decisions (approved with the plan)

| # | Decision |
|---|---|
| D1 | The **app** places the points and sends both positions: area (`u`, `v`) and photo (`img_x`, `img_y`). The notebook only re-checks the photo position from the corners. |
| D2 | The **app** maps classes to TB codes (`category_map`). The notebook returns only the raw class and its confidence. |
| D3 | The package is **one .zip** (manifest, README, `photos/T<n>/m<NN>.jpg`), written with `ZipFileEncoder`, photos stored uncompressed and streamed from disk. `archive` was promoted to a direct dependency. |
| D4 | Results match by point id, guarded by session, `point_seed`, the station on screen and each frame's exact corners. A frame changed since the export (corners moved, retaken, deleted) is **stale** and skipped. |
| D5 | An unknown class or model, a foreign frame or point, a seed mismatch, or a colony-count transect **rejects the whole file**, in one transaction. |
| D6 | The status is `pending` on export (if unset). On import it is `done` when every point is labeled, otherwise `pending`. Model id, `analyzed_on = laptop` and the time are always written. Expert columns are never touched. |
| D7 | Export is **per station**, for photo-transect stations only. Colony count is outside the bulletins (#3). Preliminary frames get points with #13. |
| D8 | Each transect tile gets a **cover line**: `HC x% · Bleached y% · n points · laptop`. The station mean, SD, SE and grade are #8's. |

## What was built

- **`lib/services/analysis_manifest.dart`** (pure):
  - `buildAnalysisManifest` builds the export;
  - `parseAnalysisResults` validates the shape and throws a `FormatException` with the reason;
  - `AnalysisImport` reports the outcome per transect.
- **`TransectDatabase.applyAnalysisResults`:**
  - checks everything, writes the labels, sets the status, model id and `analyzed_on`/`analyzed_at`, and
    rebuilds cover, all in one transaction;
  - `refreshTransectCover`'s body became `_refreshCover(txn, …)`, shared with it.
- **`lib/services/laptop_analysis.dart`:**
  - `exportStation` samples, builds the manifest, checks the photo files and writes the zip, leaving no
    partial zip on failure;
  - `share`;
  - `importResults`;
  - `describeImport`, the dialog text.
- **`lib/services/station_checks.dart`:** `transectCoverLine`.
- **`StationDetailScreen`:**
  - a "Cover analysis (laptop)" card with Export and Import, for photo stations only;
  - a dialog with the import summary or the reason it was refused;
  - the cover line on each tile;
  - `exportForAnalysis` and `pickResultsFile` injectable for tests.
- **Notebook** `machine-learning-pipeline/notebooks/28_coralscapes_laptop_cover.ipynb` (written, **not run**):
  - pinned weights (`c61183ec…`) with an `id2label` check against the app's fixture;
  - EXIF-upright size check;
  - a port of `frameToImage` that checks every point;
  - the model card's sliding-window inference, with bilinear logit sampling at the points;
  - overlays;
  - `results.json` and `points.csv`;
  - run folder `research_logs/runs_cover/<RUN_ID>/`, and `latest_run.txt` after its checks.

## Tests

The full suite has 945 passing tests (54 new), and `flutter analyze` is clean.
- `analysis_manifest_test`: manifest content, photo names, `img_x/img_y` = `frameToImage`, and parser
  accept/reject cases.
- `laptop_analysis_db_test`:
  - the happy path with hand-worked cover;
  - idempotent re-import, expert labels kept, stale frames (moved, moved back, retaken), partial files;
  - all-stale transects left unstamped, and files for another station refused;
  - every rejection rolling back.
- `laptop_analysis_test`:
  - the zip's contents;
  - pending status, no resampling on re-export, refusals that leave no zip;
  - **end to end**: export → a stand-in notebook answers the manifest → import → HC 30 %, `done`, `laptop`.
- `station_screens_test`: import, the error dialog, a cancelled picker, export and its failure, and no
  card on colony-count or preliminary stations.

## Left for later

- **Run the notebook on the November 15 photos** (user). Check the overlays. Compare with the expert's CPCe
  scoring of the same frames (#16).
- The station summary, grades and CPCe export (#8). Point review (#10). The phone route (#11, #12).
- A device check of the share sheet and the Files picker on the iPhone.

## Review fixes (code and security review, 2026-11-14)

- **High:** a stale frame whose points were deleted could leave a transect `done` with a cover over fewer
  frames. Now `done` requires no stale frames and points on every scorable frame.
- A retaken or deleted frame, or one whose corners were moved and moved back, is stale instead of
  rejecting the file. A frame or point of another transect is still rejected.
- A transect with nothing labeled isn't stamped `analyzed_on`.
- Imports are tied to the station on screen. Picked files over 10 MB are refused.
- The busy state always clears, and unexpected errors show a message.
- The zip is deleted after sharing. The README warns that EXIF is kept.
- Notebook: `use_safetensors=True`, `padding_mode='border'`, and a tolerance on the 0-1 position check.
