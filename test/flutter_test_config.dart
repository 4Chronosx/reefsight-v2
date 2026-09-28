import 'dart:async';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// `sqflite` has no platform channel under `flutter test`. `sqflite_common_ffi`
// is the package's own documented way to run real SQLite (not a mock) from
// plain Dart tests -- this file's name/location (`test/flutter_test_config.dart`)
// is a `package:test` convention: it runs once before every test in this
// directory, so individual test files don't each need this boilerplate.
//
// `databaseFactoryFfiNoIsolate`, not `databaseFactoryFfi` (sub-plan 6,
// ui-ux-overhaul, step 8, adding the first `testWidgets` tests in this repo):
// the isolate-backed factory's background isolate never delivers its
// `dart:isolate` reply inside `testWidgets`'s `FakeAsync` zone --
// reproducible as a 10-minute `TimeoutException` in
// `_RawReceivePort._handleMessage`, even wrapped in `tester.runAsync()`.
// `sqflite_common_ffi`'s own docs (`doc/testing.md`, "Writing widget test")
// call this out explicitly: "use the ffi implementation without isolate."
// The plain (non-widget) tests under `test/services/` keep working
// identically -- this factory is a strict subset of the isolate one, just
// without the isolate hop.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  await testMain();
}
