# Sub-plan 29: Expert review, point corrections and genus-group diversity (issue #10)

Roadmap position: **M2**, the tenth issue of the DENR-aligned version (`4Chronosx/reefsight-v2` #10).
It builds on #8's station summary (`27-station-summary-and-cpce-export.md`) and #9's share package
(`28-organized-sharing.md`), and carries out `docs/reefsight-v2-blueprint.md` §4 (`genus_tags`) and
`docs/denr-tb-2019-04-alignment.md` §1 and §10. The reasoning is in
`../docs/expert-review-and-tau-diversity.md`.

## Starting point

- `frame_points` already had `expert_category_code`, `expert_name` and `reviewed_at`;
  `FramePoint.effectiveCategoryCode` preferred the expert's code; `setExpertCategory` existed and
  dropped the cover cache; `computeCover` set `uses_expert`; the CPCe sheet had a "Uses expert
  corrections" row; `points.csv` had the expert columns, Reviewed At included.
- No way to undo a correction, no review screen, no `genus_tags`, no TAU list, no diversity.

## Decisions (approved with the plan)

| # | Decision |
|---|---|
| D1 | A tag belongs to a **frame**: the TAUs seen in that photo, one row each. `frame_id` NULL is a TAU seen on the tape but in no photo. |
| D2 | **Reviewer name** asked on the first change, pre-filled from the station's observer, kept in `AppSettings.reviewerName` (in memory, like the other settings) until relaunch. |
| D3 | **Accepting the model's label** writes the same code as the expert's, so the point counts as reviewed. `clearExpertCategory` undoes a correction. |
| D4 | **Diversity counts tags only** and doesn't wait for cover. No tags anywhere: no figure and no grade (not D), with `kNoDiversityYet`. A transect with no tags is flagged. |
| D5 | **A ≥ 27 · B 23–26 · C 19–22 · D 0–18** (Table 2's >26, >22–26, >18–22, 0–18 on whole counts). Letters only: the bulletin gives no words for diversity. |
| D6 | **TAU catalogue = TB 2019-04 Table 3** (59 units), apart from the TB 2017-05 life-form codes (CB, CE, CF, CM and CMR appear in both lists with different meanings). |
| D7 | **Replacing a frame's photo drops its tags**, as it drops its points. Moving the corners keeps them (same photo). |
| D8 | `genus_tags.station_id` is the transect's, filled in by the database. No method moves a transect to another station, so it can't go stale. |

## What was built

- **`lib/services/tau_catalogue.dart`**: `Tau`, `kTaus` (Table 3 in the bulletin's order; codes as
  printed, "Coscinaraea" and "fungiids" spelled as the genera are), `kPriorityTauCodes` (PORB, PORE,
  PORM, the six Acropora units, HEL: what TB 2019-04 asks for even without TAU expertise),
  `isTauCode`, `tau()` (throws on an unknown code), `tausForPicker()` (priority first, then by name).
- **`lib/services/genus_tag.dart`**: `GenusTag` with `toMap`/`fromMap`.
- **Schema v13** (`transect_database.dart`): `genus_tags` with `UNIQUE (session_id, frame_id, tau_code)`
  and the partial unique index `idx_genus_tags_tape` for tape tags (SQLite's UNIQUE treats NULLs as
  distinct). Tags go with `deleteSession`, `replaceFrameAtMeter` and frames removed by
  `saveImportedFrames`; the foreign key would refuse the frame delete otherwise.
- **DB API**: `clearExpertCategory`, `setFrameTaus` / `setTransectTaus` (replace the set; an
  unchanged code keeps who first tagged it; checks codes, tagger, transect in a station, not colony
  count, all before writing; cover is untouched), `genusTagsForSession`, `genusTagsForStation`,
  `rawDatabaseForTest`.
- **`lib/services/station_diversity.dart`** (pure): `DiversityGrade`, `gradeDiversity`,
  `kDiversityScale`, `kNoDiversityYet`, `TransectDiversity`, `StationDiversity.compute` (per
  transect, the union across transects, grade, flags, `gradeLine`).
- **`lib/screens/point_review_screen.dart`**: frame by frame, the photo with its 1 × 1 m outline and
  numbered points (white: model label, teal: reviewed, grey: unlabeled), "n of 10 points reviewed".
  A point's sheet shows the model class, confidence and mapped code, then **Accept model label**,
  **Clear correction** and every TB code under its major. The genus panel shows the transect's TAU
  count, the photo's tags, **Tag genus groups** and **Seen on tape, not in a photo** (searchable
  multi-select, priority units first). The reviewer dialog owns its controller (disposing it in the
  caller broke the dialog's closing animation).
- **Station detail**: **Expert review** on the photo-transect analysis card (picks the transect when
  there are several).
- **Station summary**: a **Generic diversity (station)** card (grade line, per-transect counts,
  scale, flags) over every transect of the station; `StationSheetExporter` now takes the diversity.
- **Export**: `exportStationCpceCsv(diversity:)` adds `GENERIC DIVERSITY (TB 2019-04)` (T1…Tn,
  STATION), `GENUS GROUPS (TAUs)` (one row per TAU, `x` where seen; rows prefixed "TAU " because
  "Acropora branching (ACB)" is also a life-form row above), station figure, grade (", indicative"
  for preliminary), scale and flags, after the cover result. `exportGenusTagsCsv` writes
  `genus_tags.csv` (Photo, Meter, TAU, TAU Name, Tagged By, Tagged At; tape tags first) in every
  bulletin transect folder of the share package; `ShareSource.diversity` goes into the sheet.

## Verification

- `flutter test`: **1069 passed** (new: `tau_catalogue_test.dart` 5, `genus_tags_db_test.dart` 16,
  `station_diversity_test.dart` 8, `point_review_screen_test.dart` 8, CPCe diversity and
  `genus_tags.csv` 5, share package 2, station summary screen 3; the v12 assertions in
  `transect_cover_db_test.dart` and `transect_database_v11_test.dart` moved to v13).
  `flutter analyze`: no issues.
- Table 3 checked against `paper/tb2019-04.pdf` (`pdftotext -layout`, lines 399–437): 30 units in the
  left column, 29 in the right.
- Worked example under test: three transects at 30, 40 and 50 % HC; one T1 sand point corrected to
  coral takes T1 to 40 % and the station mean from 40.0 to 43.3 %.

## Open

- **Device check** on the iPhone: point taps on real photos, the sheets with the keyboard up.
- **For CCEF:** whether diversity is counted per station or per transect, and whether TAUs seen
  outside the photos (tape tags) count.

## Code review (fixed)

- Frames with no points yet (before the laptop export places them), with no corners, or excluded
  could not be tagged, and the tape button was unreachable on a transect with no scored frame. The
  review screen now lists every photo; points are drawn only where there are corners and points.
- A station with genus tags but no analyzed transect left diversity out of the share zip; the sheet
  now goes in when there are tags.
- `mounted` checks after the point and TAU sheets close.

## Gaps closed after the first pass

- **Station summary with tags alone:** the station detail's Station summary button now opens once a
  transect has cover *or* any genus tag ("Genus groups tagged: n TAUs" under Expert review), and the
  summary shows `kNoCoverYet` above the diversity card with the export button. `kNoSummaryYet` now
  says "analyzed or genus groups tagged".
- **Corner moves on a reviewed frame** ask first ("Discard expert corrections?", Keep / Move
  corners), since moving corners resamples the points (#6's rule).
- **Reviewer name after a relaunch:** still in memory (no persistence package), but the dialog is
  pre-filled from `lastReviewerForStation` (the latest correction or tag on the station), then the
  observer.
- **`_setTaus` checks** (frame, transect, station, survey type) now run inside the write
  transaction.
- **Save vs. reload:** a reload failing after a committed save says "Saved, but the screen could not
  refresh" instead of "Could not save".
- Tests: **1075 passed** (new: `lastReviewerForStation` 3, review pre-fill 1, station detail with
  tags only 1, corner-move warning 1; one #8 test now expects `kNoCoverYet`). One unrelated
  `photo_transect_capture_screen_test` failed once under full-suite load and passed on re-run and
  alone.
