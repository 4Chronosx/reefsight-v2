# Sub-plan 28: Organized sharing through the iOS share sheet (issue #9)

Roadmap position: **M2**, the ninth issue of the DENR-aligned version (`4Chronosx/reefsight-v2` #9).
It builds on #8's station summary and CPCe sheet (`27-station-summary-and-cpce-export.md`) and carries
out `docs/denr-tb-2019-04-alignment.md` §9b, **layer 1 only** (the in-app Google Drive upload, layer 2,
stays deferred, as decided on November 14, 2026). The layout and naming rules are explained in
`../docs/organized-share-package-layout.md`.

## Starting point

- Sharing was per file: "Export CPCe sheet" (one CSV per station, #8), "Export & Share CSV" and "Share
  report with photos" (colony and session CSVs plus loose colony photos, sub-plans 5, 12 and 18), and
  "Share Transect Video". Loose files lose any folder structure in Drive, AirDrop and email.
- `archive` (zip streaming from disk) and `share_plus` were already dependencies, used together by #7's
  laptop export (`laptop_analysis.dart`). No dependency was added.

## Decisions (approved with the plan)

| # | Decision |
|---|---|
| D1 | One **.zip** per share, so the folder layout survives Drive, AirDrop and email. Photos and video are stored uncompressed and streamed from disk. |
| D2 | Root `<code>_<yyyy-mm-dd>` (survey day); `_T2` for one transect, `_T1_T3` for several but not all; `PRELIMINARY_` in front for a preliminary station (alignment doc §7). |
| D3 | `station_summary_CPCe.csv` only when **every** transect is in and the station has at least one analyzed transect. A subset's summary would read as the station result. |
| D4 | Unassigned surveys: root `<site>_<yyyy-mm-dd>_<HHmm>` (local start time), one folder `transect/`. |
| D5 | Photo names `NNN_mMM.<ext>`: order along the tape (1-based) and meter mark; `m12-5` for a decimal mark; `NNN_t<mm>-<ss>` for a preliminary frame with only a video time. |
| D6 | The existing single-file share buttons stay; the zip is a separate **Share / Save** action. |
| D7 | Video off by default; a warning above 500 MB; a free-space check (package + 50 MB) before writing. |
| D8 | A missing frame photo stops the share with a clear message unless photos are left out. Colony photos and videos that are gone are just left out, as Summary already does. |

## What was built

- **`lib/services/share_package.dart`**: the naming rules (`photoEntryName`, `stationRootName`,
  `unassignedRootName`, `transectFolder`, `describeBytes`); `ShareSource.forStation` /
  `ShareSource.forSession` load everything once for the picker (frames, points, cover, colonies, and
  which files exist with their sizes); `ShareOptions` (transects, photos, colony photos, video);
  `writeShareZip` (refuses an empty or foreign selection, missing photos, and too little free space,
  and leaves no partial zip); `shareZip` (share sheet, then deletes the zip).
- **`ReportExporter`**: `exportStationInfoCsv` (station fields, then a row per transect in the
  package; PRELIMINARY stamp or research-scope note first), `exportTransectCoverCsv` (one row per TB
  code and major, empty below the header until the transect is fully labeled), `exportPointsCsv`
  (every point, named by its photo's path in the zip). All go through `csvSafe`.
- Colony-count and unassigned transects reuse `exportCsv` and `exportSessionCsv` unchanged, plus their
  context colony photos under `colony_photos/`.
- **`lib/widgets/share_package_sheet.dart`**: `SharePackageSheet` (transect checkboxes for a station,
  content toggles, zip name, total size, warnings) and `shareSurveyPackage` (load, pick, pack, share;
  errors in a SnackBar).
- **Station screen**: a Share / Save action in the app bar (whole station) and on each transect row
  (that transect ticked to start). Injectable `documentsPath` and `sharePackage` for tests.
- **Summary screen** (Technical tab): **Share / Save (.zip)** for an unassigned survey or a
  colony-count station transect.

## Verification

- `flutter test`: **1022 passed** (new: `share_package_test.dart` 14, `share_package_db_test.dart` 16,
  `share_package_sheet_test.dart` 4). `dart analyze lib test`: no issues.
- The DB tests write real files into temp directories, build the zip, decode it, and check every entry
  name, the photo bytes, and the CSV contents (headers, cover %, the photo name on each point, the
  `'=cmd` formula guard on free text).

## Open

- **Device check pending:** Save to Files → Google Drive and AirDrop with a real station on the iPhone,
  and how Drive copes with a zip over 1 GB (video on).
- The zip goes to the temporary directory and is deleted after the share sheet closes. If iOS kills
  the app while the sheet is open, the zip stays in `tmp/` until iOS purges it; the app doesn't clean
  `tmp/` at launch.
