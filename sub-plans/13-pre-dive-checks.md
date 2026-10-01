# Sub-plan 13 — Pre-dive checks: storage, battery, heat

Roadmap position: **A3** on the app track (`sub-plans/model-accuracy-roadmap.md`, "App track"). It uses
sub-plan 12's entry fix as one of its checklist items.

## Why

Once the phone is sealed in the DIVEVOLK housing, nothing can be fixed. Three things can end a transect
early or degrade it, and the app checks none of them (verified 2026-10-01, no battery, storage or thermal
code in `lib/`):
- **Storage.** One continuous video per transect (Spec, "Recording & crash resilience"), estimated at
  ~0.6–1.2 GB (Spec, Cloud sync; not yet measured). A full disk stops the recording.
- **Battery.** Live runs the camera, two models, the tracker and the recorder at once.
- **Heat.** A sealed housing in tropical sun can't shed heat. iOS throttles the CPU, GPU and Neural Engine
  as `ProcessInfo.thermalState` rises, so frame rate drops, which also lowers the tracker update rate
  (sub-plan 09). If that happens in a field transect, the thesis needs to be able to say so.

## Decisions
1. **Warn, never block.** The diver may know better, for example a short test dive at 30% battery.
   Checks show green, amber or red with a reason, and Start stays enabled. That's the same stance as the
   tape-length hint and sub-plan 12's missing-fix warning.
2. **Thresholds** (starting values, kept in one constants class like `ClassificationPolicy`):
   - storage: red below 1× the estimated transect size, amber below 2×
   - battery: red below 20%, amber below 40%, green when charging
   - heat: amber at `serious`, red at `critical`
3. **The estimated transect size is measured, not guessed, once data exists.** Start with 1.2 GB. After
   sub-plan 09's device session, replace it with the measured bytes per minute from real recordings ×
   expected minutes. Record the measurement in this file.

## Steps
1. **Providers behind interfaces** (`StorageInfo`, `BatteryInfo`, `ThermalInfo`), each with a fake for
   tests:
   - Battery: `battery_plus` (Flutter Community).
   - Free storage: a maintained pub package with iOS support, or a ~10-line platform channel calling
     `FileManager` `volumeAvailableCapacityForImportantUsage`.
   - Thermal: a platform channel in `ios/Runner/AppDelegate.swift` returning `ProcessInfo.processInfo
     .thermalState`, plus the `thermalStateDidChangeNotification` stream.
   - **Build risk.** There's no local macOS (Spec, Build pipeline), so Swift only compiles on Codemagic.
     Keep the Swift minimal, add it in its own commit, and check the Codemagic build before building UI
     on top of it. Prefer a pub package if a maintained one covers what's needed.
2. **"Ready to dive" card on Setup.** It lists storage, battery, heat and the entry position (sub-plan 12),
   each with its status and one line of reason. Placeholder: a manual "Hobologger clock synced" tick, added
   once sub-plan 15 exists.
3. **During Live:**
   - A small HUD badge when heat reaches `serious`, or battery or storage crosses red. It sits on the HUD
     edge, not over the frame (sub-plan 06 decision 4).
   - Record the **peak thermal state** and the **count of state rises** on the session, as nullable columns.
     The report and the thesis can then explain a frame-rate drop, and the diagnostics loop line (sub-plan
     09) carries the current state.
4. **Summary (technical tab):** "Device got hot (serious) during this transect", if it did.

## Tests
- Pure check logic: thresholds → status, for each provider value, including boundaries and "charging".
- Setup widget test: the card renders each status from fakes, and Start stays enabled when everything is
  red.
- Live HUD badge widget test, with the thermal stream changing.

## Done when
- On a device, Setup shows real storage, battery and thermal values, and a low-battery state turns the card
  amber or red.
- A heat-stress run (phone in the housing in the sun) logs its thermal peak to the session, and Summary
  shows it.
- The transect size estimate has been replaced with a measured value.
