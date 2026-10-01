# Sub-plan 6 — UI/UX overhaul (app shell, navigation, v1 visual salvage)

Follows sub-plan 5. Sub-plan 5's "Done when" bar was functional ("Report UI renders real data",
"Scan/Summary running against real models/tracker, not stubs"), and that bar was met, but the visual and
navigation half of its "v1 salvage" list never actually happened. The data pipeline underneath is done
and tested; the app on top of it is still a developer harness. This sub-plan is **presentation and
navigation only**: it must not change tracking, classification, storage semantics, or metric
computation.

Source of truth for requirements stays `ReefSight_Specification.md` Phase C ("Diver interaction",
"Live screen", "Post-dive report", lines 123-125). v1 = `../reefsight` (sibling repo, separate git
history), used as a **visual reference and asset source**, not as code to port wholesale. Its CV layer
is superseded (see `../MASTER_PLAN.md`).

## Where this starts from (verified 2026-09-28)

| Screen | v1 lines | v2 lines | v2 state |
|---|---|---|---|
| `splash_screen.dart` | 69 | 39 | Flat `AppColors.primary` + `Icons.water`, fixed 900 ms, no logo |
| `home_screen.dart` | 541 | 68 | Icon, title, subtitle, one "Start Survey" button. No imagery, guidance, or history |
| `transect_setup_screen.dart` | 475 | 140 | Three default `TextField`s + button. Functionally correct |
| `live_transect_screen.dart` (v1 `scan_screen.dart`) | 968 | 646 | Pipeline logic is solid. UI is debug text on `Colors.black54` boxes |
| `summary_screen.dart` | 1074 | 552 | Two tabs, donut, size-frequency bars, CSV share. Reasonably complete |

The line counts understate the gap: most of v2's `live_transect_screen.dart` is session/lifecycle logic,
not UI.

Concrete gaps:
- **No navigation structure.** Splash → Home → Setup → Live → Summary is the only path in the app. You
  can't reach a past survey: `SummaryScreen` needs a `sessionId`, and nothing lists sessions.
  `TransectDatabase` has `sessionById` but no `listSessions`. When a diver leaves Summary, that report
  can't be opened from the app again even though it's still in SQLite.
- **Broken back-stack after a survey.** Live uses `pushReplacement` to Summary, so pressing back from
  Summary lands on the Transect Setup form instead of Home.
- **No accidental-exit guard on Live.** A back swipe during a dive tears the screen down. `dispose()`
  does still persist the session, so no data is lost, but the transect ends with no warning. v1 had a
  `PopScope` confirm.
- **No branding assets.** `mobile/assets/` contains only the two `.mlpackage.zip` models. v1 has
  `assets/images/{full_logo.png, deep-sea.jpg, healthy_coral.png, bleached_coral.png}`,
  `assets/icon/app_icon.png`, and design mockups in `assets/design/`.
- **Live screen shows developer output to divers.** The per-track `#id: CORAL_BL (1234px²)` list, `seg:
  12.3ms`, and 12 px red error text are fine for development, but they don't meet the Spec's glove and
  underwater readability requirements.
- **No shared theme or widgets.** Every screen styles its own buttons and inputs inline. `main.dart`
  sets only `colorScheme` and `textTheme`.

## Design references

- `../reefsight/assets/design/splashscreen.png`: white background, full ReefSight logo (coral mark +
  wordmark + "Coral Reef Health Monitor"), slightly below centre.
- `../reefsight/assets/design/homescreen.png`: underwater photo hero with a blue gradient, logo badge
  card at top, "How do we know a coral's health state?" headline, swipeable HEALTHY/BLEACHED coral cards
  with a callout line, page dots, then a light-cyan rounded bottom sheet holding a "Before you start"
  info card and the survey entry point. v1's `home_screen.dart` already implements this. Adapt it, don't
  redraw it.
- `../reefsight/assets/design/design2.png`: third-party style reference (a hydration app), used for its
  **bottom navigation bar with a raised centre action**, rounded stat cards, and large donut. This is
  where the "menu" comes from.

## Decisions for this sub-plan

1. **Bottom navigation shell with three tabs and a raised centre "Start Survey" action.** Tabs are
   **Home**, **Surveys** (history), and **Settings**, following `design2.png`. The centre action goes
   straight to Transect Setup. The shell is hidden during Setup, Live, and Summary (pushed full-screen
   routes) so nothing can be mis-tapped mid-dive.
2. **Drop v1's "Free Survey" mode.** v1 offered Free Survey vs Transect Survey. In v2, the physical tape
   length is the density denominator (Spec "Density, positioning, and sync"; sub-plan 4 "Done when"), and
   a survey without it can't produce the metrics the report is built on. There is one survey type. The
   mockup's "Choose Survey Mode" section becomes a single primary call-to-action.
3. **No map, GPS, geofence, or per-quadrat environmental-entry UI.** These were already scoped out in
   sub-plan 5 and in `transect_setup_screen.dart`'s doc comment. Environmental data arrives through
   Hobologger ingestion (sub-plan 5 step 2), not diver-typed fields. Don't port v1's quadrat transition
   overlay.
   **Correction (2026-10-01):** "already scoped out in sub-plan 5" was wrong for GPS. Sub-plan 05 said
   to port v1's geospatial layer, and the Spec requires a surface GPS fix at dive **entry and exit**. The
   live map, geofence and quadrat UI stay dropped. The two fixes are restored by
   `12-entry-exit-gps.md`.
4. **Glove-first sizing.** Every in-water control is at least 64 dp tall. Topside controls are at least
   56 dp, which is the existing convention in this codebase. Don't put two destructive or primary actions
   next to each other on the Live screen. Minimum body text on Live is 16 sp, with high contrast against
   camera footage (solid or near-opaque backing, never `black54` with small text).
5. **Presentation only.** Changes to `live_transect_screen.dart` are limited to extracting its overlay
   widgets into `lib/widgets/` and restyling them. The session start/finalize/dispose ordering guards
   (`_disposed`, `_sessionStartFuture`, `_finalized`, `_endingTransect`) and `_handleStreamingData` must
   come out behaviourally identical. If a UI change seems to need a pipeline change, stop and raise it.
   Don't fold it in.
6. **Reuse the existing design tokens.** `AppColors` and `AppTypography` (Nunito) are already ported.
   Centralise component styling in `ThemeData` (button, input, card, and app-bar themes) so screens stop
   hand-styling.
7. **Orientation: the Live screen is locked to landscape; all topside screens are portrait.** The field
   team confirmed that the DIVEVOLK SeaTouch housing is held landscape on a transect swim (2026-09-28).
   Set `SystemChrome.setPreferredOrientations` to landscape on entering Live, and restore portrait on
   leaving it (in `dispose` and on the route to Summary). Lay out the Live HUD for a wide, short screen:
   tally along the top edge, End control on the trailing edge (right side, where the thumb sits), and
   error banners across the top without covering the centre of the frame.
8. **Surveys can't be deleted, from any screen.** They're irreversible field data. The app has no delete
   or clear action for sessions (decided 2026-09-28).
9. **Photo provenance is deferred.** Use v1's `deep-sea.jpg`, `healthy_coral.png`, and
   `bleached_coral.png` as-is. Tracking where they came from isn't required for this sub-plan
   (2026-09-28).

## Steps

### 1. Assets, theme, shared widgets
- Copy from `../reefsight/assets/` into `mobile/assets/images/` and `mobile/assets/icon/`:
  `full_logo.png`, `deep-sea.jpg`, `healthy_coral.png`, `bleached_coral.png`, `app_icon.png`. Register
  them in `pubspec.yaml`. Don't copy `assets/design/`, which is reference only, or v1's `models/`.
- Extend `main.dart`'s `ThemeData` with `elevatedButtonTheme`, `filledButtonTheme`,
  `inputDecorationTheme`, `cardTheme`, `appBarTheme`, and `navigationBarTheme` built from `AppColors`.
  Use `scaffoldBackgroundColor: AppColors.background`. Set the app-wide default orientation to portrait
  in `main()` (decision 7).
- New `lib/widgets/`:
  - `underwater_background.dart`: the photo plus gradient stack, used by Home and the Live loading and
    error states. v1 duplicates this three times.
  - `logo_badge.dart`: v1's `_LogoBadge`.
  - `glove_button.dart`: a primary or destructive button with the decision-4 minimum height, optional
    leading icon, and a busy state.
  - `section_card.dart`: a white rounded card with an icon and title header, following v1's "Before you
    start" card.
  - `health_chip.dart`: a coloured pill for `CORAL`, `CORAL_BL`, or unknown, via `AppColors.forHealth`.

### 2. Session history query (only data-layer addition)
- `TransectDatabase.listSessions()` returns every `transect_sessions` row, newest first, plus a colony
  count and a bleached count per session. Use one query with `LEFT JOIN … GROUP BY`, not N+1.
- Return a small value type, e.g. `SessionSummary { TransectSession session; int colonyCount; int
  bleachedCount; }`, in `lib/services/`.
- Rows with `ended_at IS NULL` (app killed mid-dive) are real and must be listed, flagged as
  incomplete, not hidden.
- Tests in `test/services/transect_database_test.dart` via `openInMemoryForTest()`: ordering, counts,
  zero-colony session, incomplete session.
- This is read-only, with no schema change and no version bump. Per decision 8, don't add a delete
  method.

### 3. App shell, Splash, Home
- `lib/screens/app_shell.dart`: a `Scaffold` with a `NavigationBar` or a custom bottom bar plus a raised
  centre action, using an `IndexedStack` over Home, Surveys, and Settings so tab state survives
  switching.
- Splash follows `splashscreen.png` and v1's implementation: a white background, `full_logo.png` fading
  in, then a fade transition into `AppShell`. Keep the total time at about 1.5 s. It's branding, not a
  loading screen, since models load lazily on Live.
- Home follows `homescreen.png` and v1's `home_screen.dart`:
  - The hero section (background, logo badge, headline, HEALTHY/BLEACHED carousel with page dots)
    ports close to as-is. Use this project's health colours from `AppColors`.
  - The bottom sheet has a "Before you start" `SectionCard` using v1's four field-protocol bullets. Check
    them against the Spec and Dev Plan before copying, in particular the "0-10 m" depth claim and the
    "30-50 cm" camera distance, and fix any bullet that conflicts. Add a bullet telling the diver to
    hold the housing in landscape (decision 7).
  - A primary "Start Transect Survey" `GloveButton` goes to Transect Setup (decision 2).
  - A "Recent surveys" strip shows the latest 1-3 `SessionSummary` cards, each opening that session's
    Summary, with "See all" switching to the Surveys tab. If there are no surveys, show a one-line
    empty state.

### 4. Surveys (history) screen and Summary navigation
- `lib/screens/surveys_screen.dart` lists each `SessionSummary` as a card with site name (or "Unnamed
  site"), date/time, observer, tape length, colony count, bleaching % as a `HealthChip`-style bar, and an
  "Incomplete" badge when `endedAt` is null. Tapping a card pushes `SummaryScreen(sessionId: …)`. It's
  read-only: no swipe-to-delete or long-press menu (decision 8).
- The empty state explains what will appear here and offers a "Start your first survey" button.
- Refresh the list when the tab is re-selected and after returning from a survey.
- Fix the back-stack after a survey. When Live ends, navigate so that Summary sits directly on top of
  `AppShell`, using `pushAndRemoveUntil` down to the shell route. Summary also gets an explicit "Done"
  action back to the shell. Back from Summary must never land on Transect Setup. Summary is portrait,
  so restore portrait before or while pushing it (decision 7).
- Summary restyle is light-touch. It's already the most complete screen: apply the theme, use
  `HealthChip` and `SectionCard`, and add a header showing site, date, and tape length. **Executive tab
  content stays out of scope.** The Spec marks it `[OPEN]` (line 125). Restyle what exists and don't
  invent new report content.

### 5. Transect Setup restyle
- Group the fields into `SectionCard`s: "Transect" (tape length) and "Survey details" (site, observer).
- The field team uses tapes of 50-100 m (2026-09-28), so give tape length quick-pick chips for **50, 75,
  and 100 m** plus a free-entry field that accepts any value. Keep the chip values in one `const` list so
  they're trivial to change.
- Validation stays as it is: any positive number is accepted, so the free-entry field stays flexible.
  A value outside 50-100 m shows a **non-blocking** hint under the field ("Outside the usual 50-100 m
  range. Double-check the tape length."). It must not disable the start button.
- Default the field to 50 m instead of the current `'10'`.
- Prefill site and observer from the most recent session (`listSessions().first`), which avoids adding
  a preferences dependency. Keep them editable.
- Show a compact pre-dive checklist (camera housing sealed, tape laid, lighting, phone held landscape)
  as the final card before "Start Transect". It's informational, not a blocking gate.

### 6. Live Transect screen (presentation only, see decision 5)
- The screen is locked to landscape (decision 7). Everything below is laid out for landscape.
- Extract `_TallyBadge` and `_PerformanceAndTracksOverlay` into `lib/widgets/`, then restyle them:
  - The **Tally HUD** (top edge) follows v1's `colony_counter_hud.dart`: seen, healthy, and bleached
    counts in their health colours, plus elapsed transect time. It's large, high-contrast, and readable at
    arm's length through a housing.
  - A **recording indicator** (top-left): a red dot with "REC" and elapsed time, driven by
    `TransectRecorder` state. The Spec's recording-isolation guarantee is invisible to the diver today.
    This makes it visible, and it turns amber with a message when `_recordingError` is set.
  - An **error banner**: segmentation, recording, and storage errors appear as a banner across the top,
    with an icon and one-line plain-language message. Raw exception text goes behind a tap-to-expand
    toggle, not inline red text. The banner must not cover the centre of the camera frame.
  - The **debug overlay** (per-track list and `seg: ms`) is hidden by default and toggled from Settings
    ("Show diagnostics"). Keep it, because it's useful for field debugging and thesis screenshots. When
    it's shown, dock it to the left edge.
- The **End Transect** control is a single `GloveButton` (destructive, at least 64 dp) on the trailing
  (right) edge. Tapping it opens a confirm sheet ("End transect? N colonies recorded") with two large
  buttons, Keep surveying and End. Tapping twice by accident underwater must not end a dive.
- **Back and edge-swipe guard**: `PopScope(canPop: false)` routes to the same confirm sheet.
- **Loading state**: until `onModelLoad` fires, show `UnderwaterBackground` + logo + "Loading coral
  model…", following v1's scan-screen loading state, instead of a bare camera view.
- **Overlay colours**: the plugin's native box and mask overlay stays on (`showOverlays` default in
  `third_party/ultralytics_yolo/lib/widgets/yolo_controller.dart`). Drawing masks in per-track health
  colours with track IDs would need a custom painter over tracker output. That's a stretch goal only. If
  attempted, it goes in a separate widget and must not touch `_handleStreamingData`.
- **Verify the plugin overlay under landscape lock.** Check that `YOLOView`'s native overlay and the
  `imageWidth`/`imageHeight` in the streaming payload still line up with the preview after the
  orientation lock. Crop geometry (`crop_geometry.dart`) and tracker boxes depend on those dimensions.
  If they don't line up, stop and raise it: it's a pipeline question, not a styling fix (decision 5).

### 7. Settings / About
- **Show diagnostics on Live** (a toggle, stored in-memory or in SQLite, whichever needs no new
  dependency, or add `shared_preferences` if both are awkward).
- **About**: app version, which model assets are bundled (`ModelAssets` names: `coralvos_primary`
  segmentation and NMFS-OSI bleaching classifier), and a plain note that both are interim and not yet
  Cordova-fine-tuned (mobile `CLAUDE.md`). This is for honest disclosure to LGU users and the panel.
- **Data**: storage location and session count. There's no delete or clear action (decision 8).

### 8. Tests
- Widget tests, following the existing `test/` style with sqflite FFI via `flutter_test_config.dart`:
  - The shell renders all three tabs, and the centre action pushes Transect Setup.
  - Surveys shows its empty state with an empty DB, lists seeded sessions newest first, marks an
    incomplete one, and a tap opens Summary with the right `sessionId`. There's no delete affordance.
  - Setup defaults to 50 m. Tapping the 50, 75, or 100 chip fills the field. A blank or non-positive
    value disables start. A positive value outside 50-100 m (for example 30 or 150) shows the hint but
    keeps start **enabled**. Site and observer are prefilled from the latest session.
  - Summary's "Done" returns to the shell, not to Setup.
  - Tapping End Transect once shows the confirm sheet and doesn't end the session.
- Live screen widget tests can't run `YOLOView` headlessly. Test the extracted HUD, banner, and
  confirm-sheet widgets in isolation at a landscape test surface size.
- The existing service and tracking tests must stay green untouched, which is evidence that decision 5
  held.

## Verification limits

The camera and model path only runs on-device: iOS, `.mlpackage.zip` assets. That's blocked on the Apple
Developer account (`sub-plans/track1-handoff.md`, "Do these first" #2), and Codemagic builds don't
exercise the UI. Until then, verification is widget tests plus a Codemagic build succeeding. State
this explicitly when reporting the sub-plan done, and don't claim the Live screen was checked
visually. Once hardware access exists, do an on-device pass: glove test in the housing held landscape,
readability in daylight and at depth, and the overlay-alignment check from step 6.

## Done when
- Launching the app shows the branded splash, then Home, matching `homescreen.png`, inside a three-tab
  shell with a centre Start Survey action.
- Every completed or incomplete session in SQLite can be reached from the Surveys tab and opens its
  report, and none can be deleted. Back from any report returns to the shell.
- The Live screen runs in landscape and shows a readable tally, a recording indicator, and
  plain-language error banners. Ending a transect needs a confirmed deliberate action, and the back
  gesture is guarded. Topside screens return to portrait afterward.
- Transect Setup offers 50/75/100 m presets, accepts any positive length, and warns (without blocking)
  outside 50-100 m.
- No screen hand-styles buttons or inputs that the theme already covers.
- All pre-existing `test/` suites pass unchanged, and the new widget tests above pass.

## Remaining open item
- **Executive-summary content.** This is still `[OPEN]` in the Spec (line 125). It isn't this
  sub-plan's decision, but the restyle should leave that tab easy to change.
