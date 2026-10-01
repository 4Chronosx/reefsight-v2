# Sub-plan 15 — Hobologger data import

Roadmap position: **A5** on the app track (`sub-plans/model-accuracy-roadmap.md`, "App track").
**Blocked** until the field team provides a sample export (step 0).

## Why

The Spec and Dev Plan both commit to it, and it was never built:
- Spec, Phase C "Density, positioning, and sync": "**Hobologger/phone sync:** clocks pre-aligned before the
  dive."
- Dev Plan §12 and sub-plan 05 step 2: "sync-and-import with pre-aligned clocks, no manual event matching."
- Sub-plan 06 decision 3: environmental data "arrives through Hobologger ingestion … not diver-typed fields".
  The app deliberately has no manual temperature or conditions entry, so without this import a survey has
  **no environmental data at all**.

Verified 2026-10-01: the only mention of Hobologger in `lib/` is a doc comment in `report_exporter.dart`.

## Step 0 — get a real export first (people, not code)
Ask the field team for:
- **One real export file** from the logger they'll dive with, taken from a test deployment, plus the
  logger model and the software used (HOBOware or HOBOconnect).
- **Which variables** it records: temperature, light, depth or pressure? And the **logging interval**.
- **How they set its clock.** "Pre-aligned" needs a procedure, for example syncing the logger to the phone's
  time in the logger app right before the dive.

Don't design the parser before this arrives. HOBO CSV layouts vary by model and software version (header
rows, timezone column, units in headers), and guessing would mean rewriting it.

## Decisions (draft, confirm after step 0)
1. **Import after the dive, topside.** The file comes in through the iOS share sheet or Files ("Open in
   ReefSight"), or through a file picker on Summary. There's no Bluetooth pairing with the logger in v1 of
   this; that's future work if the logger supports it.
2. **Matched by time, no manual event matching.** Readings between the session's `startedAt` and `endedAt`
   (± a small tolerance) attach to that session. Because clocks are pre-aligned, nobody marks events by hand.
3. **Store the readings and derive summaries.** Raw readings go in a new `logger_readings` table
   (`session_id, at, variable, value, unit`). The report shows per-transect min/mean/max per variable. Each
   colony also gets the **reading nearest its `firstSeenAt`** in the colony CSV, which is cheap and useful
   for later analysis such as temperature vs bleaching.
4. **Immutability.** Like the exit fix (12) and the recount (14), the logger import is a write-once
   attachment added after End Transect. Re-importing the same file is a no-op. A different file for an
   already-attached session is refused with a message.

## Steps (after step 0)
1. Parser for the real format, with the sample file as a test fixture (redacted if needed), covering header
   detection, timezone handling and unit parsing.
2. Schema bump plus a `LoggerReading` model, and a migration test.
3. The import flow:
   - share-sheet or file-picker entry (add a package only if `share_plus` and the iOS document types
     aren't enough)
   - a preview: "N readings, 09:12–09:58, matches transect 09:20–09:41"
   - confirm and store
4. Report: an environment card on the technical tab, a per-variable summary in the session CSV (sub-plan
   12), and the nearest reading per colony in the colony CSV.
5. Sub-plan 13's "Ready to dive" card gets the manual "Hobologger clock synced" tick.
6. Sub-plan 07: add `logger_readings` to what syncs (records tier).
7. Add a `docs/` explainer covering the clock-alignment procedure and how matching works.

## Done when
- A real logger file from a test dive imports onto the right session, its readings show on Summary, and they
  appear in both CSVs.
- The clock-sync procedure is written down and on the pre-dive card.
