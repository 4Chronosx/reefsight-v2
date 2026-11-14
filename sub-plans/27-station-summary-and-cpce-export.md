# Sub-plan 27: Station summary, grading and CPCe-layout export (issue #8)

Roadmap position: **M2**, the eighth issue of the DENR-aligned version (`4Chronosx/reefsight-v2` #8).
It builds on #6's per-transect cover (`25-category-mapping-and-cover.md`) and #7's laptop results
(`26-laptop-analysis.md`), and carries out `docs/reefsight-v2-blueprint.md` §6 and
`docs/denr-tb-2019-04-alignment.md` §1b and §8. The statistics are explained in
`../docs/station-summary-statistics-and-grading.md`.

## Starting point

- `transect_cover` held each transect's % per TB code and major category (BLEC and every major always
  present), but only the counted-point total. The frame, all-point and excluded counts the CPCe sheet
  needs came only from `refreshTransectCover`'s `CoverComputation`.
- `station_checks.dart` had the depth, tape and minimum-count flags, and `reportsBulletinCover`.
- The station screen had a disabled "Station summary (coming with #8)" button.

## Decisions (approved with the plan)

| # | Decision |
|---|---|
| D1 | **Sample SD (n − 1)**, as CPCe's Excel sheets compute it; SE = SD ÷ √n. With one transect, SD and SE are blank, not 0. |
| D2 | **Only transects with complete cover** (every point labeled) count toward n. The others are flagged "T<n> not analyzed: left out of the summary", and the minimum of 3 is checked against n. |
| D3 | A code missing from a transect is **0 %** there, so each mean is over all n. |
| D4 | The grade is taken from the mean **rounded to one decimal** (`gradeHardCoral` parses `toStringAsFixed(1)`), the value shown: 44.0 → B, 33.0 → C, 22.0 → D. |
| D5 | The summary loads through `stationCoverInputs`, which rebuilds each transect's cover in one transaction and returns the counts. No schema change. |
| D6 | **One CSV per station**, `reefsight_<site>_<station>_cpce_<survey day>.csv`, `PRELIMINARY_` in front for preliminary stations, shared through the share sheet. The organized .zip is #9. |
| D7 | A "Uses expert corrections" row per transect (#10 will fill it). |

## What was built

- **`lib/services/station_summary.dart`** (pure): `CoverGrade` (A–D, Excellent–Poor),
  `gradeHardCoral`, `StationTransectCover`, `CategoryStat` (percents, mean, SD, SE) and
  `StationCoverSummary.compute` (majors HC, DC, AA, OB, AB, then codes in catalogue order; flags;
  `isPreliminary`, `gradeLine` with ", indicative"). Refuses colony-count stations. Constants
  `kPreliminaryStamp`, `kFlagNoSpread`, `kNoSummaryYet`.
- **`TransectDatabase.stationCoverInputs`**: each transect by number with its rebuilt cover, in one
  transaction; refuses unknown and colony-count stations.
- **`ReportExporter.exportStationCpceCsv`**, `stationCpceFilename`, `shareStationSheet`. The table
  follows **TB 2017-05 Figure 6** (the sample CPCe sheet, checked against the figure):
  - header: the PRELIMINARY stamp (first line), station, name, site, survey day, survey type, frame
    mode, observer, reef zone, depth range, deep-edge fix with source, model, where analyzed, expert
    use, report scope;
  - `TRANSECT NAME` row (T1…Tn), then `Number of frames`, `Total points` and `Total points (minus
    tape+wand+shadow)`, with no statistics (as in the figure);
  - `MAJOR CATEGORY (% of transect)` with `MEAN`, `STD. DEV.`, `STD. ERROR`: the five majors labelled
    `NAME (CODE)`, the **TWB row as a % of all points** (CPCe's "TAPE, SHADOW, BLOCKS, IND (TWB)";
    every other row is over the points counted, `StationCoverSummary.excludedStat`), and the
    `Sum (excluding tape+shadow+wand)` check row (100.00);
  - `SUBCATEGORIES (% of transect)`: **every** TB code, zeros included, under a header per major and
    alphabetical by name within it, as CPCe lists its code file (`catalogueStats`);
  - `TRANSECT DETAILS`: tape, depths and expert use per transect;
  - result: transects analyzed, hard coral station mean (one decimal), grade, bleached coral mean,
    then one `Flag` row each.
- **`ReportExporter.csvSafe`**, applied to every cell of every CSV the app writes (`_write`): text
  starting with `=`, `+`, `-`, `@`, tab or CR gets a leading apostrophe so Excel shows it as text
  instead of running it as a formula. Numbers, and text that parses as a number ("-12.50"), are left
  alone, so negative values in the recount columns are unchanged.
- **`lib/screens/station_summary_screen.dart`**: PRELIMINARY banner, the hard coral card (mean, ± SE,
  "n of N transects analyzed", grade, the scale, bleached coral), flags, the cover table (scrolls
  sideways), and **Export CPCe sheet** (injectable for tests).
- **`station_detail_screen.dart`**: the Station summary button opens the screen once any transect has
  cover, and otherwise shows `kNoSummaryYet` under it.

## Verification

- `flutter test`: **988 passed** (new: `station_summary_test.dart` 22, `stationCoverInputs` 4, CPCe
  export 10, `csvSafe` 3, station screens 4 new or replaced). `flutter analyze`: no issues.
- Figure 6's own numbers check the TWB rule: T1 has 290 points and 286 after tape, wand and shadow,
  HC 27.97 % = 80 / 286, and TWB 1.38 % = 4 / 290.
- Worked example under test: HC 30, 40, 50 % → mean 40.0, SD 10.00, SE 5.77, grade B. Pooling check:
  20/100 and 10/10 average to 60 %, not the pooled 27.3 %.

## Open

- **Major categories differ from Figure 6** (for CCEF, with the mapping): the figure's majors are
  HC, AA, AB, **MA**, **HA**, OB and TWB, with **no DC major**. ReefSight's are the blueprint's HC, DC,
  AA (with MA, HA and CA in it), OB, AB and TWB (`tb_categories.dart`, #6). The subcategory rows are
  the same either way; only the major roll-up would change.
- Figure 6's coral subcategories are genera (ACAN, CAU, FAV, ...), the TAU-style code file; ReefSight's
  are TB life-forms until #10 brings genus tags.
- Device check: export and share from the iPhone.
- Diversity (TAU counts) is #10; the CMEMP/Agos format is #18.
