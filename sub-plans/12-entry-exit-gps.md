# Sub-plan 12 — GPS fix at dive entry and exit

Roadmap position: **A2** on the app track (`sub-plans/model-accuracy-roadmap.md`, "App track").

## Why: the Spec decided it, and the app dropped it by mistake

`ReefSight_Specification.md`, Phase C "Density, positioning, and sync":

> **Coordinates:** surface GPS fix at dive entry/exit only; underwater position referenced to the marked
> transect line.

The app records no coordinates (verified 2026-10-01). There's no location permission in
`ios/Runner/Info.plist`, no location column in `transect_database.dart`, and no location package in
`pubspec.yaml`. It happened like this:
- Sub-plan 05 said to port v1's geospatial layer: `../reefsight/lib/services/location_service.dart` and
  `TransectGeofence`.
- Sub-plan 06 decision 3 then said "No map, GPS, geofence … already scoped out in sub-plan 5". That misreads
  05. The intent was to drop v1's live map and geofence, but the wording also dropped the two fixes the Spec
  requires.
- `transect_setup_screen.dart`'s doc comment repeats it ("v1's GPS start/end-point pickers stay dropped").

This sub-plan restores **only what the Spec says**: two topside fixes per transect.

## Not in scope (unchanged decisions)
- No live GPS during the transect: there's no signal underwater. No map, no geofence, no point-in-belt.
- **Density still uses the physical tape length.** The GPS fixes never feed any metric.

## Decisions
1. **The entry fix is taken on the Setup screen**, topside, before descent, because that's when the phone
   still has sky view.
2. **The exit fix is taken after surfacing, from Summary, not at End Transect.** End Transect is tapped
   underwater, with no fix possible. Summary for a session without an exit fix shows **"Record exit
   position"**.
3. **The exit fix is write-once**, and it's the only field written to a survey after End Transect.
   Recording it doesn't edit the survey: the field goes from null to a value exactly once and is read-only
   after that. Sub-plan 07 needs a matching note, because a survey synced before its exit fix was recorded
   needs exactly this one later field update.
4. **Manual entry is always available as a fallback**, for example from the boat's GPS. Each fix records its
   `source` (`gps` or `manual`), so the report can say which is which.
5. **A missing fix never blocks a dive.** Setup warns ("No entry position — it'll be missing from the
   report") but Start stays enabled. That matches the existing non-blocking tape-length hint.

## Data model (schema v4, or the next version after sub-plan 11's bump)
Nullable columns on `transect_sessions`:
`entry_lat REAL, entry_lon REAL, entry_accuracy_m REAL, entry_at TEXT (ISO-8601 UTC), entry_source TEXT`,
and the same five with `exit_`. These are additive `ALTER TABLE … ADD COLUMN`s in `_upgradeSchema`, the same
pattern as v2/v3. In Dart, a `GeoFix` value class (`lat`, `lon`, `accuracyM?`, `at`, `source`) on
`TransectSession`, with `entryFix` and `exitFix`, both nullable.

## Steps
1. **Schema and model.** Add the migration and `GeoFix`. Tests:
   - a v3 database upgrades and keeps its rows
   - round-trip through `toMap`/`fromMap`
   - null fixes stay null
2. **Location service.** Use `geolocator` (v1 used it; pick the current version compatible with this SDK).
   - Put it behind an injectable `LocationProvider`, with the fake used in tests.
   - Call `getCurrentPosition` at best accuracy with a ~20 s time limit. Report accuracy, and handle
     permission denied, location services off and timeout as distinct, user-readable states.
   - Add `NSLocationWhenInUseUsageDescription` to `Info.plist` ("ReefSight records your position at the
     start and end of a transect."). Add the Android equivalent too, even though iOS is the target.
3. **Setup screen: an "Entry position" card.**
   - Acquisition starts when the screen opens.
   - It shows `Acquiring…`, then `±8 m · 10.3256° N, 123.9468° E`, then a Retry button, or a failure
     reason plus **Enter manually**.
   - Manual entry takes decimal degrees, with lat −90..90 and lon −180..180. If the point is more than
     ~50 km from Cordova it shows a non-blocking hint, to catch swapped lat/lon or sign errors.
   - The fix is passed into `insertSession`.
4. **Summary: "Record exit position"** for a session with `exitFix == null`. It uses the same acquisition
   and manual flow, writes once, and then the button is replaced by the read-only fix.
5. **Report and export.**
   - The Summary header shows both fixes, plus **entry–exit distance as a QA check** next to the tape
     length ("entry–exit 48 m apart · tape 50 m"). It's shown for a human to sanity-check, never used in
     metrics.
   - CSV gets a second, small `<base>_session.csv` (site, observer, tape, start/end, both fixes with
     source and accuracy). It's shared together with the colony CSV, since `share_plus` takes several
     files. The colony CSV's columns are unchanged.
6. **Paper trail.**
   - Add a correction note to sub-plan 06 decision 3, pointing here.
   - Fix `transect_setup_screen.dart`'s doc comment.
   - Add the write-once exit-fix note to sub-plan 07.
   - Add a `docs/` explainer (why only two fixes, why exit is recorded after surfacing).

## Tests
- Setup widget test with a fake `LocationProvider`:
  - success shows the fix and it's stored on Start
  - failure shows manual entry, and the manual fix is stored with `source: manual`
  - Start stays enabled with no fix
- Summary widget test: the exit button records once, and after that the fix is shown read-only with no
  button.
- Exporter test for the session CSV.

## Done when
- A transect started topside on a device stores an entry fix, and recording the exit after surfacing
  stores an exit fix. Both show on Summary and in the exported session CSV.
- The Spec's coordinates line is implemented as written, and the 06 correction is recorded.

## Implementation notes (2026-10-02)
Implemented as written, except for the points below. Rationale: `../docs/entry-exit-gps-fixes.md`.
- **Schema is v6, not v4.** Sub-plans 11 and 13 had already used v4 and v5. Ten nullable columns
  (`entry_*`, `exit_*`) are added in `_upgradeSchema`'s `oldVersion < 6` block.
- **Write-once is enforced in SQL.** `TransectDatabase.recordExitFix` is one
  `UPDATE … WHERE id = ? AND exit_lat IS NULL`, and returns whether it stored anything.
- **The missing-entry warning is in the "Ready to dive" card's Entry position row.** That was sub-plan
  13's grey placeholder. Setup's GPS card and that row read one `GeoFixController`.
- **Start goes through an injectable `startTransect` hook** (default `pushLiveTransect`), so widget
  tests can check the `TransectStart` (including `entryFix`) without building Live's camera. Live
  passes `entryFix` to `insertSession`. A fix that arrives after Start is tapped is dropped.
- **GPS exit only within 12 h** (`kExitGpsWindow`) of the session's end, else its last checkpoint,
  else its start. Older sessions offer manual entry only, so opening an old survey can't stamp today's
  position as its exit. Acquiring only proposes a fix; nothing is stored until **Save exit position**.
- **The session CSV adds `Entry-Exit Distance (m)`**, the same QA number as the Summary header.
- `geolocator: ^14.0.2`. iOS `NSLocationWhenInUseUsageDescription`, Android FINE/COARSE location.
- The 06 correction already existed before this work. Sub-plan 07 now has the write-once exit-fix note.
- **Verified:** `dart analyze`: no issues; `flutter test`: 332 passed. A device check is still open:
  entry fix topside → Summary → record exit → export, then check `_session.csv`.
