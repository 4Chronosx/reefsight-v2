# Sub-plan 20 — Schema v11: stations, frames, points and cover (issue #1)

Roadmap position: **M1**, first issue of the DENR-aligned version (`4Chronosx/reefsight-v2` #1).
Every later issue (#2 to #19) builds on these tables. The design is in
`docs/reefsight-v2-blueprint.md` §3–5; the reasons behind it are in
`docs/denr-tb-2019-04-alignment.md` §8. This file covers what was built, what changed from the design,
and how it was checked.

## What was built

- **Schema v11** in `lib/services/transect_database.dart` (`_schemaVersion = 11`). `_createSchema`
  builds it for new installs. `_upgradeSchema` adds an `oldVersion < 11` block for existing phones.
  Both use the same SQL constants (`_stationsTableSql`, `_stationSessionColumns`, `_v11ChildTablesSql`,
  `_stationTransectIndexSql`), so the two paths can't drift apart.
  - New tables: `stations`, `transect_frames`, `frame_points`, `category_map`, `transect_cover`.
  - Thirteen nullable columns on `transect_sessions`, and a partial unique index on
    `(station_id, transect_number) WHERE station_id IS NOT NULL`.
  - `genus_tags` (#10) and `drive_uploads` (deferred) were left out, as the issue says.
- **Models** in `lib/services/`:
  - `station.dart`: `Station`, `StationSummary`, and the enums `SurveyType`, `FrameMode`, `ReefZone`.
  - `transect_frame.dart`: `TransectFrame`, the `NormPoint` record, and the enums `FrameSource`,
    `CornerSource`, `DistanceMethod`.
  - `frame_point.dart`: `FramePoint`, with `effectiveCategoryCode`, which prefers the expert's code.
  - `category_mapping.dart`, `transect_cover.dart`: one row of each table.
  - `transect_session.dart`: the v11 fields, plus the enums `CaptureSource`, `AnalysisStatus`,
    `AnalyzedOn`.
  - `db_enum.dart`: each enum stores the snake_case value from the blueprint (`photo_transect`,
    `in_app`, …), not its Dart name. Renaming an enum value in Dart therefore never changes what's
    on disk. Unknown values read back as `null`, the same as the existing `asNameMap()` reads.
- **Repository methods** on `TransectDatabase`:
  - Stations: `insertStation`, `updateStation`, `stationById`, `listStations`.
  - Transects: `transectsForStation`, `nextTransectNumber`, `setAnalysisStatus`.
  - Frames: `insertFrame`, `framesForSession`, `updateFrameCorners`, `setFrameExcluded`.
  - Points: `insertFramePoints`, `pointsForFrame`, `pointsForSession`, `setPointModelLabel`,
    `setExpertCategory`.
  - Category map: `upsertCategoryMappings`, `categoryMapFor`.
  - Cover: `replaceTransectCover`, `coverForSession`.

## What changed from the blueprint, and why

1. **The table is `transect_sessions`, not `sessions`.** The blueprint's SQL named the table
   `sessions`, but the app has always used `transect_sessions`. Pasting that SQL in as written
   would have failed. The blueprint's SQL and tables are now corrected.
2. **The deep-edge fix reuses `GeoFix`.** The blueprint had `deep_edge_fixed_at` and no source column.
   The station now stores its fix with `GeoFix.toColumns('deep_edge')`, giving `deep_edge_lat`,
   `_lon`, `_accuracy_m`, `_at` and `_source`. This is the same format as the transect entry and exit
   fixes (sub-plan 12), so the station setup screen (#2) can reuse `GeoFixPanel`. The record also keeps
   whether the fix came from GPS or was typed in, which the blueprint version didn't. The user approved
   this choice on 2026-11-14.
3. **`deleteSession` now deletes a transect's frames, points and cover first.** Foreign keys are on
   (`PRAGMA foreign_keys = ON` in `onOpen`), and none of the tables has `ON DELETE CASCADE`. Without
   this change, deleting a transect that had frames would have failed with a foreign-key error. It
   deletes in this order: points, frames, cover, colonies, then the session, all in one transaction.
   The station is never deleted along with a transect. `deleteStation` comes with #2's screens.
4. **Station rules are checked in Dart.** Photo-transect stations must have a frame mode, and
   preliminary and colony-count stations must not. A blank station code is also rejected. These are
   `ArgumentError`s, following `recordRecount`. The database's CHECK constraints only cover the
   allowed values, as in the blueprint.

## Decisions to know about

- **The CHECK lists are fixed on disk.** SQLite can't change a CHECK constraint in place. Adding a
  new survey type, frame mode or frame source later needs a table rebuild in its own migration. Adding
  the Dart enum value alone isn't enough.
- **Transect numbers aren't reused.** `nextTransectNumber` returns one more than the highest number in
  use, so numbers already written on a datasheet never come back. The 3–5 limit is enforced by #2,
  not by the database.
- **`setAnalysisStatus` only writes the fields it's given.** Setting a finished transect back to
  `pending` keeps the previous run's model and time until a new run replaces them.
- **The model's label and the expert's label are stored separately.** `setPointModelLabel` never
  touches the expert columns, and `setExpertCategory` never touches the model's. The disagreements are
  the evidence for #16 (validation) and for retraining.
- **`category_map` starts empty.** Filling in the CoralscapesV2 mapping is #6, which is waiting on
  CCEF.
- **Station transects also show up in `listSessions`,** the Surveys tab's query. Separating them is
  #2's UI work. The query itself didn't change.

## How it was checked

- `test/services/transect_database_v11_test.dart` (real SQLite through `sqflite_common_ffi`):
  - **Fresh install:** the file reports `user_version` 11, has all five tables, and has the partial
    index. `genus_tags` and `drive_uploads` aren't present.
  - **Upgrade from v10:** the test copies the exact v10 schema into its own fixture, so it starts
    from a real v10 file rather than today's code. After the upgrade:
    - the old session reads back with every v11 field null;
    - `listSessions` counts still match, and the colony still reads back;
    - the old survey can still be deleted.
  - **Upgraded and fresh schemas match:** `PRAGMA table_info` is compared for every table, so a v10
    phone ends up with exactly the schema a new install gets.
  - **Constraints:**
    - a transect number is unique within one station only;
    - sessions without a station are never limited by that index;
    - a transect's station must exist;
    - one frame per meter mark, but preliminary frames without a meter mark aren't limited;
    - one point per index, and a failed batch of points adds nothing;
    - the CHECK constraints reject unknown values written in raw SQL.
  - **Repository behaviour:** ordering of stations, transects, frames and points; the deep-edge fix
    round trip; replacing cover rather than adding to it; keeping expert corrections separate from
    the model's label.
  - **Deleting a transect:** deleting one transect of a station removes its frames, points and cover.
    The other transect and the station stay.
- `test/services/station_models_test.dart`: `toMap` and `fromMap` round trips for every model,
  including the stored enum values, legacy null fields, rejection of anything but four corners, and
  rejection of point positions outside 0–1.
- Results on 2026-11-14: `flutter analyze` reported no issues; `flutter test` passed all 636 tests
  (46 of them new, including the review fix's test).

## Review follow-ups (code review, 2026-11-14: approved, no critical or high findings)

Fixed here: `insertSession` now rejects a station transect that has no `transectNumber`. Without
the check, the partial unique index would let such rows through (it treats NULLs as distinct), and
`nextTransectNumber` would ignore them.

For #2, and #4 or #5 once frames have image files:
- **Frame images stay on disk after a delete.** `deleteSessionFiles` (`session_files.dart`) only
  removes the video, masks and colony photos. Either store frame images under a `session<id>_`
  folder and add it to `_perSessionFolders`, or have `deleteSession` return the frames' paths.
- **`Station.copyWith` can't clear a field** (`x ?? this.x`). Switching a station away from photo
  transect with `copyWith` keeps the old frame mode, and `updateStation` then throws. The edit screen
  should build a new `Station(...)`, or `copyWith` needs a way to clear fields.
- **Picking the next number and inserting the transect are two steps.** A double tap ends in a
  unique-index `DatabaseException`: nothing is corrupted, but the user sees an error. Consider one
  method that does both in a single transaction.
- **Meter marks are compared as real numbers.** `UNIQUE (session_id, meter_mark)` treats 0.3 and
  0.30000000000000004 as different, and a photo frame with no meter mark isn't deduplicated at all.
  Use whole meters, or require a meter mark on every frame that isn't a video frame.
- **Some updates fail silently on a wrong id.** `updateStation`, `setAnalysisStatus`,
  `updateFrameCorners` and `setPointModelLabel` do nothing when the id doesn't exist. Return a bool,
  like `recordExitFix`, if a caller needs to know.

## Next

#2 (stations and transect setup screens) builds on `insertStation`, `listStations`,
`nextTransectNumber` and `GeoFixPanel`. #6 adds the category mapping and the cover calculation on top
of `pointsForSession`, `categoryMapFor` and `replaceTransectCover`.
