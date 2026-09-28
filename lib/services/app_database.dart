import 'package:path_provider/path_provider.dart';

import 'transect_database.dart';

/// Opens the on-device [TransectDatabase] at the platform's documents
/// directory -- the `getApplicationDocumentsDirectory()` ->
/// `TransectDatabase.open()` pair that `summary_screen.dart` and
/// `live_transect_screen.dart` each already do inline.
///
/// Centralized here (sub-plan 6, ui-ux-overhaul) so the new topside screens
/// that read the DB (Home's recent-surveys strip, Surveys, Setup's
/// site/observer prefill, Summary) can take this as an injectable
/// constructor parameter instead of calling `path_provider` directly --
/// which has no platform channel under `flutter test` (finding surfaced
/// while planning this sub-plan's step 8 widget tests). Follows
/// `transect_recorder.dart`'s pattern of injecting the platform-coupled
/// call as a plain function so the caller stays testable; tests substitute
/// `TransectDatabase.openInMemoryForTest` directly, no wrapper needed there.
typedef DatabaseOpener = Future<TransectDatabase> Function();

Future<TransectDatabase> openAppDatabase() async {
  final documentsDir = await getApplicationDocumentsDirectory();
  return TransectDatabase.open(documentsDir.path);
}
