import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Resolves a session's stored `video_path` to a file that actually exists
/// on disk, or `null` if there isn't one.
///
/// `TransectSession.videoPath` is stored as an absolute path, but iOS moves
/// the app's sandbox container (a new UUID in the path) on every reinstall
/// and on some app updates -- the recording is still in Documents, just not
/// at the old absolute path. So this falls back to looking the file up by
/// name in the *current* documents directory before giving up, instead of
/// hiding the video just because the stored prefix went stale.
Future<File?> resolveTransectVideo(String? storedPath) async {
  if (storedPath == null || storedPath.isEmpty) return null;

  final direct = File(storedPath);
  if (await direct.exists()) return direct;

  final documentsDir = await getApplicationDocumentsDirectory();
  final relocated = File(p.join(documentsDir.path, p.basename(storedPath)));
  if (await relocated.exists()) return relocated;

  return null;
}
