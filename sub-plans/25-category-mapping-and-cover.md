# Sub-plan 25 — Category mapping, point sampling and transect cover (issue #6)

Roadmap position: **M2**, the sixth issue of the DENR-aligned version (`4Chronosx/reefsight-v2` #6).
It builds on the schema v11 data layer (`20-schema-v11-stations.md`) and the frames from capture
(`23-photo-transect-capture.md`) and import (`24-photo-import-and-corners.md`). It carries out §1b
(CPCe method) and §7 (the 39-class mapping) of `docs/denr-tb-2019-04-alignment.md`. The reasoning is
written up in `../docs/cpce-point-sampling-and-cover.md`.

The issue is labelled `blocked: ccef`. The mapping ships as a draft, and changing it later is safe
(see "Mapping changes" below).

## Starting point

- v11 already had `frame_points`, `category_map` and `transect_cover`, with their models and
  writers (`insertFramePoints`, `setPointModelLabel`, `setExpertCategory`, `upsertCategoryMappings`,
  `replaceTransectCover`). Nothing filled them.
- `point_seed` was a column that nothing set.
- `transect_cover` was keyed `(session_id, category_code)`. DC and AA are both TB codes and major
  categories, so one transect couldn't hold both levels.
- The §7 draft paraphrased the model's class names and left out `other animal` (id 11).

## Decisions (approved with the plan)

| # | Decision |
|---|---|
| D1 | Schema **v12**: `level` (`code` · `major`) joins the `transect_cover` key. The table is a cache with no data, so the upgrade drops and recreates it. |
| D2 | ReefSight codes **ACX** (Acropora, form unknown) and **HCX** (hard coral, form unknown), both under HC. |
| D3 | The blueprint's six major categories, HC · DC · AA · OB · AB · TWB, with MA/HA/CA in AA. |
| D4 | `algae covered substrate` → DCA; `unknown hard substrate` → RCK (AB); `other animal`, `seagrass`, `crown of thorn` → OT; `dead clam` excluded. |
| D5 | `point_seed` is assigned the first time a transect is sampled (secure random 32-bit), not at setup. |

All of D2–D4 are in §5's questions for CCEF.

## What was built

- **`lib/services/tb_categories.dart`:** the TB 2017-05 code catalogue (code → name, major category).
  `isExcludedCode` is true only for TWB. Unknown codes throw.
- **`lib/services/coralscapes_mapping.dart`:** the 40 exact labels → codes, under
  `kCoralscapesModelId`. The major category and the excluded flag are derived from the catalogue, so
  they can't disagree.
- **`lib/services/point_sampler.dart`:**
  - Mulberry32 plus a MurmurHash3 `fmix32` frame seed. The frame key is the meter mark in mm, or the
    video time in ms.
  - `samplePoints` gives uniform points in the area's own coordinates.
  - `frameToImage` is the square-to-quad homography, for #7 and #12.
- **`lib/services/cover_calculator.dart`:** `computeCover` returns a `CoverComputation`.
  - Rows: per code, plus BLEC always; and HC, DC, AA, OB, AB always.
  - Counts: frames scored, all points, excluded and unlabeled points.
  - It is complete only when every point is labeled and at least one is counted.
- **`TransectDatabase`:**
  - Schema v12. The CoralscapesV2 map is seeded on every create and upgrade.
  - `seedCategoryMap`: validates the rows, replaces the model's rows, re-maps that model's points
    and drops their cover; it returns false when nothing changed.
  - `ensureFramePoints`: assigns the seed, samples frames that can be scored and have no points, and
    is idempotent.
  - `refreshTransectCover`: computes and caches in one transaction.
  - `insertFramePoints`, `setPointModelLabel` and `setExpertCategory` now drop the transect's cached
    cover in the same transaction. The two setters reject codes outside the catalogue and unknown
    points.
- **`TransectCoverRow.level`** (`CoverLevel`), defaulting to `code`.

## Mapping changes

`seedCategoryMap` runs inside `onCreate`/`onUpgrade`, not on every open. The app opens several
connections at once (`AppShell`'s `IndexedStack`), and re-seeding on each open could race. So **a
change to `coralscapes_mapping.dart` ships with a `_schemaVersion` bump** (an `onUpgrade` step with
nothing else in it is fine). The upgrade then re-seeds once and re-maps the stored points.

## Tests

- `tb_categories_test`, `coralscapes_mapping_test`: the mapping is checked against the pinned
  `test/fixtures/coralscapesv2_id2label.json`.
- `point_sampler_test`: golden values from the reference JavaScript Mulberry32/fmix32, run under
  Node.
- `cover_calculator_test`: a hand-worked 30-point transect, plus the expert, exclusion, incomplete
  and empty cases.
- `transect_cover_db_test`:
  - v12 fresh install and v11 → v12 upgrade;
  - seeding, re-mapping and dropped classes;
  - `ensureFramePoints`;
  - cache invalidation;
  - the end-to-end "done when" case.

Full suite: 891 passing; `flutter analyze` clean. A code review found nothing critical or high. Its
fixes are in:
- `insertFramePoints` validates codes;
- `frameToImage` refuses collinear or folded corners;
- the explainer gives the frame-key rounding rule for the Python port.

## Left for later

- Running the segmenter and writing labels (#7 laptop, #12 phone).
- Showing cover on screen and the station mean/SD/SE and grades (#8).
- Point review UI (#10).
- Preliminary video frames have no corners, so `ensureFramePoints` skips them. How they're sampled is
  decided in #13.
