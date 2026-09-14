# Sub-plan 5 — UI, reporting, and v1 salvage

Dev Plan Track 3, §11-12. Deliberately last: builds against sub-plan 4's real data models instead of
guessing their shape, and is where most of `../reefsight` (v1)'s genuinely reusable work plugs in.

## Steps
1. **Report UI** — two tabs: executive summary (LGU/decision-makers) and technical detail (academic
   panel). Project-specific UX decision, two distinct audiences.
2. **Hobologger data ingestion** — sync-and-import with pre-aligned clocks, no manual event matching.
   Last item in Track 3 for a reason; nothing upstream depends on it, don't pull it forward.

## v1 salvage — adapt, don't port wholesale
`../reefsight` is a separate repo built on a superseded CV architecture (see `../MASTER_PLAN.md`), but
its UI/domain/geospatial layer is largely independent of that and worth copying in, file by file, with
adaptation — not merged at the repo level:
- Screens: Splash, Home, Scan, Transect Setup, Summary — copy and adapt to consume this project's real
  tracker/model output shapes, not v1's.
- Provider/`ChangeNotifier` state pattern (`SessionManager`) — pattern is reusable, exact fields aren't.
- Data models (`ColonyRecord`, `QuadratRecord`, `TransectModel`, `SurveyMetadata`) — good starting
  shape; extend for mask-derived size and species-confidence fields sub-plan 4's schema needs.
- `TransectGeofence` (belt polygon generation, point-in-belt check) — transect protocol logic, doesn't
  care which CV pipeline is underneath; should port over close to as-is.
- CSV export schema and `fl_chart` analytics — adapt column list to sub-plan 4's actual schema.
- Design system (`app_colors.dart`, Nunito typography) — reuse directly, no CV dependency at all.

## Done when
- Report UI renders real data from a completed transect session (sub-plan 4's output), both tabs.
- At minimum Scan/Summary screens are running against this project's real models/tracker, not stubs.
