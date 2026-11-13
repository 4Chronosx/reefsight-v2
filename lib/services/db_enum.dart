/// An enum stored in SQLite under a fixed snake_case value (`photo_transect`,
/// `in_app`, ...) -- the spelling `docs/reefsight-v2-blueprint.md` §4 gives
/// for schema v11, kept apart from the Dart name so renaming a value in Dart
/// never changes what's on disk.
mixin DbEnum on Enum {
  String get db;
}

/// The value of [values] stored as [raw], or `null` for a missing or
/// unrecognised value -- the same tolerance as the existing
/// `asNameMap()[...]` reads in `TransectSession.fromMap`, so a row written by
/// a newer app version reads back as "not recorded" instead of throwing.
T? enumFromDb<T extends DbEnum>(List<T> values, Object? raw) {
  if (raw == null) return null;
  for (final value in values) {
    if (value.db == raw) return value;
  }
  return null;
}

/// SQLite has no boolean: 0/1, with `null` kept as "not recorded".
int? boolToDb(bool? value) => value == null ? null : (value ? 1 : 0);

bool? boolFromDb(Object? raw) => raw == null ? null : raw == 1;

DateTime? dateTimeFromDb(Object? raw) => raw == null ? null : DateTime.parse(raw as String);
