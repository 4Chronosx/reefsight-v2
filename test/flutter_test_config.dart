import 'dart:async';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// `sqflite` has no platform channel under `flutter test`. `sqflite_common_ffi`
// is the package's own documented way to run real SQLite (not a mock) from
// plain Dart tests -- this file's name/location (`test/flutter_test_config.dart`)
// is a `package:test` convention: it runs once before every test in this
// directory, so individual test files don't each need this boilerplate.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await testMain();
}
