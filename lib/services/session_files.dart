import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'colony_photos.dart';
import 'transect_session.dart';
import 'transect_video.dart';

/// Removes a deleted survey's files (`TransectDatabase.deleteSession`).
/// Injected into Surveys like `DatabaseOpener`, since `path_provider` has
/// no platform channel under `flutter test`.
typedef SessionFilesDeleter = Future<void> Function(TransectSession session);

/// Folders under the documents directory whose files are named
/// `session<id>_...`: `MaskStorage` and `ColonyPhotoStore`.
const _perSessionFolders = ['masks', ColonyPhotoStore.folder];

/// Deletes [session]'s files under [documentsDirectory] and returns how many
/// were removed:
/// - its video: the saved path, or the same file name in the current
///   documents directory (iOS moves the container, see
///   `resolveTransectVideo`); for a survey that never ended, its leftover
///   recording (`findOrphanedVideo`), the one Summary showed for it.
/// - every `session<id>_*` file in `masks/` and `colony_photos/`. A sweep by
///   name, not by the colony rows: photos are kept per track *and* label
///   but only one per track is in the DB, and a `.tmp` may be left over.
///
/// Runs after the DB delete has committed. A file that can't be deleted is
/// logged and skipped -- the worst case is a leftover file, never a
/// half-deleted survey.
Future<int> deleteSessionFiles(
  TransectSession session, {
  required String documentsDirectory,
}) async {
  final id = session.id;
  if (id == null) throw ArgumentError('session has no id');

  final paths = <String>{};
  final stored = session.videoPath;
  if (stored != null && stored.isNotEmpty) {
    paths
      ..add(stored)
      ..add(p.join(documentsDirectory, p.basename(stored)));
  } else if (session.endedAt == null) {
    try {
      final orphan = await findOrphanedVideo(session, documentsDirectory);
      if (orphan != null) paths.add(orphan.path);
    } catch (error) {
      debugPrint('ReefSight: looking for survey $id\'s leftover video failed: $error');
    }
  }

  final prefix = 'session${id}_';
  for (final folder in _perSessionFolders) {
    final dir = Directory(p.join(documentsDirectory, folder));
    if (!await dir.exists()) continue;
    await for (final entity in dir.list()) {
      if (entity is File && p.basename(entity.path).startsWith(prefix)) paths.add(entity.path);
    }
  }

  var removed = 0;
  for (final path in paths) {
    final file = File(path);
    try {
      if (await file.exists()) {
        await file.delete();
        removed++;
      }
    } catch (error) {
      debugPrint('ReefSight: could not delete $path: $error');
    }
  }
  return removed;
}

/// [deleteSessionFiles] in the app's documents directory -- Surveys' default.
Future<void> deleteSessionFilesInDocuments(TransectSession session) async {
  final documentsDir = await getApplicationDocumentsDirectory();
  await deleteSessionFiles(session, documentsDirectory: documentsDir.path);
}
