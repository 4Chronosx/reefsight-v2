# Sub-plan 22 — Colony-count mode as a station survey type (issue #3)

Roadmap position: **M1**, third issue of the DENR-aligned version (`4Chronosx/reefsight-v2` #3),
built on the station screens (`21-station-screens.md`). The decision it carries out is in
`docs/denr-tb-2019-04-alignment.md` §10: colony count stays as a third survey type, a research mode
outside the bulletins, whose colony counts and bleaching prevalence are **never mixed into the
bulletin cover summaries**.

## Starting point

#2 had already done the routing:
- a colony-count station's transect setup hands Live a `TransectPlacement`;
- Live writes the station fields when it inserts the session;
- the end-of-transect Summary sits on the station route;
- tapping a colony-count transect opens its Summary.

What was missing was the station context after the dive, and anything that actually *enforced* the
separation (until now it was only a label).

## What was built

- **The separation is enforced in the database** (`transect_database.dart`):
  - `insertFrame` and `replaceTransectCover` throw `ArgumentError` for a session in a
    `colony_count` station (`_rejectColonyCount`).
  - Points need a frame, so they are blocked too.
  - The station summary (#8) can therefore never find colony-count cover rows to pool, whatever its
    query.
  - A station-less session is unaffected, and so is a photo or preliminary one.
- **The one filter for #8** (`station_checks.dart`):
  - `reportsBulletinCover(SurveyType)`: photo and preliminary say yes, colony count says no.
  - `kResearchScopeNote`: "Research survey, outside DENR-BMB TB 2019-04 and TB 2017-05".
  - `kColonyCountNoStationSummary` and `stationTransectLabel` ("ALG-S1 · T2").
- **The per-transect report** (`report_data.dart`, `executive_summary.dart`, `summary_screen.dart`):
  - `TransectReport` gained an optional `station`. Summary reads it when the session has a
    `station_id`, and a failed read drops only the station line.
  - The header shows "ALG-S1 · T2" and the research label.
  - The Executive tab's details list gains Station and Survey rows.
  - A quick transect renders exactly as before.
- **The comparison fix.**
  - The problem: `previousSessionForSite` matched on site name only, so the Executive tab would have
    told T2 of a station "Down from X% at the last survey of this site" against T1 from an hour
    earlier. Transects of one station are replicates of one survey, not a repeat survey.
  - The fix: the query now skips sessions in `excludingId`'s own station, and
    `ExecutiveSummary._isEarlierSameSite` makes the same check.
- **Export** (`report_exporter.dart`):
  - `exportCsv` and `exportSessionCsv` take an optional `station`.
  - A station transect's files are named `reefsight_<site>_<station>_T<n>_<start>`, so T1–T5 are told
    apart by name. The station code is free text, so it is sanitized like the site.
  - The session CSV gains four columns at the **end**: Station, Transect, Survey Type, Report Scope.
    Every earlier column keeps its position, and the colony CSV is unchanged.
  - A quick transect keeps its old filename, with the four columns empty.
- **The station screen** (`station_detail_screen.dart`):
  - A colony-count station shows the research label on its card.
  - Each transect row shows that transect's own "N colonies · X% bleached (…)", in the Surveys card's
    wording.
  - Instead of the Station summary button, it says the results are per transect and never pooled
    into a cover summary.
  - Opening a transect's Summary now passes the station screen's `openDatabase`, which was the
    default before.
- **Live refuses to record an unsaved station transect** (`live_transect_screen.dart`). #2's review
  deferred this. If the insert fails and there is a `placement`, Live shows "T*n* was not saved"
  ("Recording did not start") and pops back to setup, which re-reads the used numbers. A quick
  transect keeps the old behaviour (it records, with the banner), because the field team knows it and
  dives on 2026-11-15.

## Decisions

1. **Guard in the database, not only in the summary.** A filter in #8 alone would leave the rule to
   whoever writes the next query. The guard makes a colony-count cover row impossible to store, and
   the filter documents which types count.
2. **A blinded recount stays blinded on the station screen.** A transect with results still hidden
   (sub-plan 14) shows "Results hidden — recount pending", never its counts, exactly as on Surveys.
3. **No pooled colony-count station figure.** The issue asks for transects "grouped under the
   station", and §10 says colony results are reported separately. A station-level colony summary
   (mean prevalence across transects) would be a new research output, so it is not built here.
4. **Quick transects are left as they were**, with no research label, the same filename and the same
   Live behaviour. They are colony counts too, but changing them the day before a dive buys nothing.
   Label them when the quick transect is retired or relabelled (`21-station-screens.md` decision 2).

## Review fixes

A Flutter review found no critical issues. It confirmed:
- the SQL NULL cases of the same-station skip;
- no blinded-recount leak;
- Live's dispose path after the new early return.

These were fixed:
- **A colony transect could be compared with a photo transect.**
  - The problem: another station at the same site could be a photo or preliminary station. Those have
    no colonies, so the Executive tab would have read "down from 0 colonies".
  - The fix: `previousSessionForSite` now takes only station-less sessions or colony-count stations.
    This is tested.
- **Live kept a closed database handle.** A failure *after* the insert (in the photo store or the
  checkpointer) closed the handle but left `_db` and `_sessionId` set. Recording then wrote to the
  closed handle, and the new refusal didn't fire. The catch now clears both.
- A missing space in `kFlagStationTooDeep`'s declaration (cosmetic).

## Verification

- `flutter test` (after deleting `build/native_assets/windows/sqlite3.dll`): **690 tests pass**, up
  from 670. `dart analyze`: no issues.
- New tests:
  - `transect_database_v11_test.dart` (+7):
    - Colony-count transects take no cover and no frames; photo and station-less ones still do.
    - The same-station skip, no photo-station comparison, another station still found, a quick
      transect still comparing with an earlier station transect.
  - `station_checks_test.dart` (+2): `reportsBulletinCover` and the scope note.
  - `executive_summary_test.dart` (+2): the Station and Survey rows in order; no comparison with a
    same-station transect.
  - `report_exporter_test.dart` (+4): the columns come last, the filename is sanitized and
    T-numbered, the station and research cells are filled, and a quick transect is unchanged.
  - `summary_screen_test.dart` (+2): the station line and label, and their absence on a quick
    transect.
  - `station_screens_test.dart` (+3):
    - The research label, per-transect results and hidden results; photo stations keep the #8
      placeholder.
    - **The issue's "Done when"**: three colony-count transects added from the station. Live is
      stubbed with what Live does: insert via the placement, write colonies, close. The test checks
      T1–T3 as `legacy_colony`, each "Complete" with its own count, no frames or cover, and T2 opening
      a Summary titled "ALG-S1 · T2".
- Not covered by automated tests (Live needs the camera plugin):
  - Live's "not saved" refusal. It has no easy on-device trigger, because setup's pre-check (#2)
    already catches a taken T-number. It was checked by reading the code: `PopScope(canPop: false)`
    blocks only system back, not the programmatic pop, and `dispose()` finalizes with no session id
    exactly as on the existing failure path.
  - The station-transect end handoff from #2, which is still unverified on a device. Start a
    colony-count station transect, end it, then press back from Summary: you should land on the
    station, with the transect showing its colony count.

## Next

#4 (in-app photo capture) replaces `pushCapturePlaceholder` for photo transects. #8 builds the
station summary, and must take only `reportsBulletinCover` types (the database guard already keeps
colony-count cover out).
