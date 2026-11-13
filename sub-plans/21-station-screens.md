# Sub-plan 21 — Station and transect setup screens (issue #2)

Roadmap position: **M1**, second issue of the DENR-aligned version (`4Chronosx/reefsight-v2` #2),
built on schema v11 (`20-schema-v11-stations.md`). The station design is in
`docs/denr-tb-2019-04-alignment.md` §1 and §8, and the flow diagram in `docs/reefsight-v2-blueprint.md`
§1. This file covers what was built, the choices made along the way, and how it was checked.

## What was built

- **Pure rules** (no Flutter), in `lib/services/`:
  - `transect_placement.dart`:
    - `generateRandomPlacement(Random)` gives TB 2019-04 Fig. 3's random distance along the 75 m
      axis and random 0–25 m swim-out, rounded to 0.1 m.
    - `alongError`/`swimoutError` are range checks.
    - `TransectPlacement` holds the station fields a transect carries into `insertSession`
      (station id, T-number, capture source, depths, placement).
  - `station_checks.dart`:
    - TB 2019-04 flags: station or transect deeper than 6 m, tape not 50 m, fewer than 3 transects.
    - `defaultTransectNumber`, the T-number preselect.
    - `transectStatus`, the status line on the station screen.
    - Display labels for `SurveyType`, `FrameMode` and `ReefZone`.
- **Screens**, in `lib/screens/`:
  - `station_edit_screen.dart`:
    - Create or edit a station: code, name, date, site, observer, survey type, frame mode
      (photo transect only), reef zone, depth range, deep-edge GPS (`GeoFixPanel`), marker placed,
      notes.
    - `createStation()` is the "new station, then open it" flow, used by the shell and the Surveys
      tab.
  - `station_detail_screen.dart`:
    - Station details and flags.
    - T1–T5 with status and flags.
    - **Add transect**, disabled at 5.
    - Long-press a transect to delete it.
    - A disabled **Station summary** button that #8 will enable.
  - `station_transect_setup_screen.dart`:
    - T-number chips (used numbers disabled), tape (flag if not 50 m), start/end depth
      (flag over 6 m), random placement with **Generate**, recount switch (colony count only),
      entry GPS fix and the Ready-to-dive checks.
  - `capture_placeholder_screen.dart`: where photo and preliminary transects land until #4/#5 and
    #13 exist.
- **Changed**:
  - `surveys_screen.dart`: a **Stations** section, then an **Unassigned** group. Unassigned holds
    every survey outside a station, which is all surveys before v11 plus quick transects since.
    Delete and recount export work as before.
  - `app_shell.dart`: the centre button opens a chooser: **New station** or **Quick transect (no
    station)**.
  - `home_screen.dart`: recent surveys skip photo and preliminary station transects (see
    "Review fixes").
  - `transect_setup_screen.dart` and `live_transect_screen.dart`: an optional `placement` travels
    from Setup to Live's `insertSession`. Live's other change: a station transect's Summary is
    placed on its station route, not on the shell.
  - `transect_database.dart`:
    - `listUnassignedSessions()`.
    - `openInMemoryForTest(ignoreClose:)` plus `closeForTest()`, for multi-step widget tests (each
      screen closes the handle it opens).

## Decisions

1. **Who inserts the transect row.**
   - Colony count keeps the existing behaviour: Live inserts the session at start, now with the
     station fields added.
   - Photo and preliminary transects are inserted by the setup screen. This gives #4 (photo
     capture), #5 (import) and #13 (preliminary video) a real `sessionId` to attach frames to, and
     the station shows the transect as **Awaiting capture** until then.
   - The alternative, blocking those survey types until #4/#13 land, would have stopped the station
     flow from being tested end to end now.
2. **The quick transect stays.** The field team dives on 2026-11-15, the day after this was built,
   and has only used the station-less flow. It stays one tap away (FAB chooser, Surveys empty state)
   and saves under Unassigned. Once stations have been used in the field it can be retired or
   relabelled.
3. **Survey type and frame mode lock once a station has a transect.**
   - `TransectDatabase.updateStation` left this check to the screens (sub-plan 20).
   - The edit screen still shows them but disables them, with a "Locked" note.
   - Save keeps the stored values, not the chips.
4. **T-numbers.**
   - The preselect is `nextTransectNumber` while it is free and ≤ 5. Otherwise it is the lowest free
     number, so deleting T2 of T1–T5 offers T2 again.
   - Any free number can be picked, as the issue asks for "T1–T5, unique".
   - The database's unique index stays the final guard.
5. **Flags warn, never block.** A transect deeper than 6 m or on a 75 m tape is still data. It is
   flagged on the setup form, the transect row, and (for the station's max depth or a count below 3)
   the station card. The station summary (#8) will reuse `station_checks.dart`.
6. **Random placement values are optional.** They can be generated in the app or typed in from a
   draw on the boat. Values outside the station (more than 75 m along or 25 m out) are errors,
   because the transect would not be in the station.
7. **The deep-edge fix is not acquired when the form opens.** Setup's entry fix starts on open
   because the diver is at the entry point. A station is often created before reaching its deep edge,
   so the GPS button is tapped there.
8. **Capture source.** Colony count gets `legacy_colony`, preliminary gets `in_app_video`, and photo
   transect gets `in_app_photos`, or `imported_photos` when the station's frame mode is `imported_mixed`.
   Photo and preliminary transects get `points_per_frame = 10` (CPCe). `point_seed` is left for the
   analysis step (#6).

## Review fixes

A Flutter review of the first version found these, all fixed and tested:

- **A colony-count Start could create a duplicate T-number.** Live inserts the row and keeps
  recording if that insert fails. So a T-number taken since the setup screen opened (a Live left
  with back, or a double tap) would record a whole dive unsaved. The fixes:
  - Setup now re-reads the used numbers right before pushing Live and refuses a taken one.
  - Start is held disabled until Live returns.
  - Numbers are refreshed afterwards.
  - `StartTransect` now returns `FutureOr<void>` so this can be awaited.
- **After a station colony-count transect, back from Summary went to Home.** Live's end handoff
  removed routes down to the shell. For a station transect it now stops at the station route
  (`StationDetailScreen.routeName`). The station screen reloads when Summary pops, through the
  shell's `routeObserver`.
- **Photo and preliminary rows showed on Home as "Incomplete" colony surveys.** Opening one there
  would run Summary's crash recovery. Home's recent strip now skips them. Settings only counts
  sessions, so it is unaffected.
- **A failed read on the setup screen said "All five transects are set up".** It now says the read
  failed and offers Retry.
- **Pressing back while a station was saving could pop the screen underneath.** The pop is now
  skipped once the screen is gone.

Left as is:
- Live itself still records when its insert fails; it shows a banner, as before. The pre-check
  above removes the known way that happens for station transects. Making Live stop is a Live
  change, better made with #3.
- Tapping an in-progress colony-count transect opens Summary, as a Surveys card does.

## Verification

- `flutter test` (after deleting `build/native_assets/windows/sqlite3.dll`): **670 tests pass**.
  `dart analyze`: no issues.
- New tests:
  - `test/services/station_checks_test.dart` (15): placement bounds and rounding over 500 seeded
    draws, the same seed giving the same numbers, range errors, `applyTo`, the 6 m and 50 m
    boundaries, station and transect flags, T-number defaults including the full station, status
    lines, labels.
  - `test/services/transect_database_v11_test.dart` (+2): `listUnassignedSessions` returns only
    station-less rows; `ignoreClose` really ignores close and `closeForTest` really closes.
  - `test/screens/station_screens_test.dart` (17):
    - Station edit: required code, frame mode for photo only, saved fields, the depth flag and the
      min-above-max error, the type lock with `createdAt` kept.
    - Transect setup: used numbers disabled, Generate matches the seeded generator, the tape and
      depth flags, the placement range error.
    - Routing: colony count hands Live a `TransectPlacement` and inserts nothing itself; photo and
      preliminary insert the row with the right `capture_source` and open capture.
    - The taken-number refusal, and one Live per tap with numbers refreshed on return.
    - Station detail: statuses, flags and the T5 limit; long-press delete removes the row and files.
    - Home skips photo station rows; Surveys separates stations from Unassigned.
    - **The issue's "Done when"**: three photo transects added from the station screen, each opening
      capture and returning, ending with T1–T3 stored as `in_app_photos`.
  - `app_shell_test.dart` and `surveys_screen_test.dart` were updated for the chooser and the new
    empty state.
- Not covered by automated tests:
  - Live's new end-of-transect route and the station screen's reload on Summary pop. Live needs the
    camera plugin, so check these on the phone: start a colony-count station transect, end it, and
    press back from Summary. You should land on the station, with the transect listed.
  - The deep-edge GPS on a real device.

## Next

#3 (colony count as a station survey type) builds on the colony-count route here. #4 replaces
`pushCapturePlaceholder` for photo transects, and #13 does the same for preliminary transects. #8
enables the Station summary button.
