import 'package:flutter/foundation.dart';

import 'photo_transect_store.dart';
import 'transect_database.dart';
import 'transect_frame.dart';

/// Issue #4: the state of one photo transect's capture (TB 2017-05: one
/// still every 1 m from the 0 m mark, about 51 on a 50 m tape), kept out of
/// the screen so it can be tested without a camera.
///
/// Every meter mark is captured, missing (the diver marked it, e.g. a
/// meter they couldn't reach), or still to do. After each shot the counter
/// moves to the next meter still to do -- after the current one, wrapping
/// back to an earlier gap -- so a retake or a skipped meter doesn't lose the
/// diver's place. Each change is written straight to the database, so
/// leaving (or a crash) loses at most the shot being saved, and [load]
/// resumes where capture stopped.
enum MeterStatus { pending, captured, missing }

/// Takes one still and returns the path of the camera's temp file.
typedef TakePicture = Future<String> Function();

class PhotoTransectCapture extends ChangeNotifier {
  PhotoTransectCapture({
    required this.db,
    required this.store,
    required this.sessionId,
    required double tapeLengthMeters,
    DateTime Function()? clock,
  })  : meters = List.unmodifiable([for (var m = 0; m <= tapeLengthMeters.floor(); m++) m.toDouble()]),
        _clock = clock ?? DateTime.now;

  final TransectDatabase db;
  final PhotoTransectStore store;
  final int sessionId;

  /// 0, 1, ... up to the tape length, in meters.
  final List<double> meters;
  final DateTime Function() _clock;

  final Map<double, TransectFrame> _frames = {};
  int _index = 0;
  bool _busy = false;

  double get current => meters[_index];

  /// A shot or a missing mark is being saved; another is refused until done.
  bool get busy => _busy;

  TransectFrame? frameAt(double meter) => _frames[meter];

  MeterStatus statusOf(double meter) {
    final frame = _frames[meter];
    if (frame == null) return MeterStatus.pending;
    return frame.isMissing ? MeterStatus.missing : MeterStatus.captured;
  }

  int get capturedCount => meters.where((m) => statusOf(m) == MeterStatus.captured).length;
  int get missingCount => meters.where((m) => statusOf(m) == MeterStatus.missing).length;
  int get pendingCount => meters.where((m) => statusOf(m) == MeterStatus.pending).length;
  bool get isComplete => pendingCount == 0;

  /// Reads what's already saved and starts at the first meter still to do.
  Future<void> load() async {
    _frames.clear();
    for (final frame in await db.framesForSession(sessionId)) {
      final meter = frame.meterMark;
      if (meter != null && meters.contains(meter)) _frames[meter] = frame;
    }
    final firstPending = meters.indexWhere((m) => statusOf(m) == MeterStatus.pending);
    _index = firstPending < 0 ? 0 : firstPending;
    notifyListeners();
  }

  void select(double meter) {
    final i = meters.indexOf(meter);
    if (i < 0) throw ArgumentError.value(meter, 'meter', 'not a meter mark on this tape');
    _index = i;
    notifyListeners();
  }

  void next() {
    if (_index < meters.length - 1) select(meters[_index + 1]);
  }

  void previous() {
    if (_index > 0) select(meters[_index - 1]);
  }

  /// Takes a still at the current meter, saves it with [tiltDeg] (the level
  /// indicator's reading at the shutter, `null` if there was none), replacing
  /// any photo or missing mark there, and moves on. If the database write
  /// fails the new file is deleted and the meter stays as it was.
  Future<TransectFrame> capture(TakePicture takePicture, {double? tiltDeg}) => _exclusive(() async {
        final meter = current;
        final at = _clock();
        final tempPath = await takePicture();
        final still = await store.save(tempPath, meterMark: meter, at: at);
        final frame = TransectFrame(
          sessionId: sessionId,
          meterMark: meter,
          imagePath: still.relativePath,
          source: FrameSource.inApp,
          widthPx: still.width,
          heightPx: still.height,
          capturedAt: at,
          tiltDeg: tiltDeg,
        );
        final ({int id, TransectFrame? replaced}) result;
        try {
          result = await db.replaceFrameAtMeter(frame);
        } catch (_) {
          // Only before the commit: after it, the row points at this file.
          await store.delete(still.relativePath);
          rethrow;
        }
        return _applySaved(frame, result);
      });

  /// Marks the current meter as missing (dropping any photo there) and
  /// moves on.
  Future<TransectFrame> markMissing() => _exclusive(() async {
        final frame = TransectFrame.missingMeter(sessionId: sessionId, meterMark: current, markedAt: _clock());
        return _applySaved(frame, await db.replaceFrameAtMeter(frame));
      });

  /// Ends the transect (`ended_at`). Capture can still be reopened later to
  /// retake a meter; this only records when the diver called it done.
  Future<void> finish() => db.closeSession(sessionId, _clock());

  /// After the commit: updates the state and deletes the replaced file.
  Future<TransectFrame> _applySaved(TransectFrame frame, ({int id, TransectFrame? replaced}) result) async {
    final saved = TransectFrame.fromMap(frame.toMap()..['id'] = result.id);
    final old = result.replaced;
    if (old != null && old.imagePath != saved.imagePath) await store.delete(old.imagePath);
    _frames[saved.meterMark!] = saved;
    _advance();
    return saved;
  }

  /// To the next meter still to do after the current one, wrapping round;
  /// stays put when every meter is done.
  void _advance() {
    for (var step = 1; step <= meters.length; step++) {
      final i = (_index + step) % meters.length;
      if (statusOf(meters[i]) == MeterStatus.pending) {
        _index = i;
        return;
      }
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() body) async {
    if (_busy) throw StateError('A shot is still being saved');
    _busy = true;
    notifyListeners();
    try {
      return await body();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
