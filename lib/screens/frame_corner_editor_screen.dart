import 'dart:io';

import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/frame_corners.dart';
import '../services/photo_transect_store.dart';
import '../services/transect_database.dart';
import '../services/transect_frame.dart';
import '../widgets/glove_button.dart';

/// Issue #5: the corner editor (alignment doc §9, "Defining the 1 × 1 m
/// area"). As in CPCe, the diver drags four corners onto the physical frame
/// in each photo; points are placed only inside that area (#6). Works on
/// imported and in-app (#4) photos alike.
///
/// - Starts at the first photo with no corners (or [startFrameId]).
/// - **Copy previous** takes the last photo's corners (`copied`); dragging
///   any corner afterwards makes them `manual`.
/// - **No frame visible** excludes the photo (`no_frame`): it can't be
///   scored as an official photo transect.
/// - Corners are saved in image order (TL, TR, BR, BL) and must outline a
///   convex shape; a crossed one is refused with a message.
///
/// Corners are normalized to the photo **as displayed** (EXIF orientation
/// applied) -- see `../docs/photo-import-ordering-and-frame-corners.md`.
class FrameCornerEditorScreen extends StatefulWidget {
  const FrameCornerEditorScreen({
    super.key,
    required this.db,
    required this.sessionId,
    required this.documentsDirectory,
    required this.title,
    this.startFrameId,
  });

  /// Already open; owned by the screen that pushed this one.
  final TransectDatabase db;
  final int sessionId;
  final String documentsDirectory;
  final String title;
  final int? startFrameId;

  @override
  State<FrameCornerEditorScreen> createState() => _FrameCornerEditorScreenState();
}

class _FrameCornerEditorScreenState extends State<FrameCornerEditorScreen> {
  List<TransectFrame> _frames = const [];
  int _index = 0;
  List<NormPoint> _corners = defaultCorners();
  CornerSource _source = CornerSource.manual;
  bool _loaded = false;
  bool _saving = false;
  Object? _error;

  late final PhotoTransectStore _store =
      PhotoTransectStore(documentsDirectory: widget.documentsDirectory, sessionId: widget.sessionId);

  TransectFrame? get _frame => _frames.isEmpty ? null : _frames[_index];
  int get _withoutCorners => _frames.where(_needsCorners).length;

  static bool _needsCorners(TransectFrame f) => f.corners == null && f.excludeReason != kNoFrameReason;

  @override
  void initState() {
    super.initState();
    _load(initial: true);
  }

  Future<void> _load({bool initial = false}) async {
    try {
      final frames = [for (final f in await widget.db.framesForSession(widget.sessionId)) if (!f.isMissing) f];
      if (!mounted) return;
      setState(() {
        _frames = frames;
        if (initial) {
          final start = frames.indexWhere((f) => f.id == widget.startFrameId);
          final firstNeeding = frames.indexWhere(_needsCorners);
          _index = start >= 0 ? start : (firstNeeding >= 0 ? firstNeeding : 0);
        }
        _index = _index.clamp(0, frames.isEmpty ? 0 : frames.length - 1);
        _loaded = true;
        _resetCorners();
      });
    } catch (error) {
      debugPrint('ReefSight: loading frames for corners failed: $error');
      if (mounted) setState(() => _error = error);
    }
  }

  void _resetCorners() {
    final f = _frame;
    _corners = [...f?.corners ?? defaultCorners()];
    _source = f?.cornerSource ?? CornerSource.manual;
  }

  void _goTo(int index) => setState(() {
        _index = index;
        _resetCorners();
      });

  /// The previous photo's corners, unless it has none or was marked "no
  /// frame visible" (its leftover corners don't describe a frame).
  List<NormPoint>? get _previousCorners {
    if (_index == 0) return null;
    final prev = _frames[_index - 1];
    return prev.excludeReason == kNoFrameReason ? null : prev.corners;
  }

  void _copyPrevious() {
    final prev = _previousCorners;
    if (prev == null) return;
    setState(() {
      _corners = [...prev];
      _source = CornerSource.copied;
    });
  }

  void _drag(int corner, Offset delta, Size box) {
    setState(() {
      final c = _corners[corner];
      _corners[corner] = clampNorm((x: c.x + delta.dx / box.width, y: c.y + delta.dy / box.height));
      _source = CornerSource.manual;
    });
  }

  Future<void> _save() async {
    final frame = _frame;
    if (frame == null || _saving) return;
    final ordered = orderCorners(_corners);
    if (!isValidFrame(ordered)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('The four corners must outline the frame: no crossed or folded sides.'),
      ));
      return;
    }
    // One transaction: it also lifts a "no frame visible" exclusion.
    await _write(() => widget.db.updateFrameCorners(frame.id!, ordered, _source));
  }

  Future<void> _markNoFrame() async {
    final frame = _frame;
    if (frame == null || _saving) return;
    await _write(() => widget.db.setFrameExcluded(frame.id!, excluded: true, reason: kNoFrameReason));
  }

  /// Saves, reloads, then moves to the next photo still needing corners
  /// (or simply the next one), so a whole transect goes quickly.
  Future<void> _write(Future<void> Function() body) async {
    setState(() => _saving = true);
    try {
      await body();
      await _load();
      if (!mounted) return;
      final next = _nextIndex();
      if (next != null) _goTo(next);
    } catch (error) {
      debugPrint('ReefSight: saving corners failed: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  int? _nextIndex() {
    for (var step = 1; step < _frames.length; step++) {
      final i = (_index + step) % _frames.length;
      if (_needsCorners(_frames[i])) return i;
    }
    return _index < _frames.length - 1 ? _index + 1 : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text('Corners · ${widget.title}')),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_error != null) return Center(child: Text('Could not load the photos: $_error'));
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    final frame = _frame;
    if (frame == null) return const Center(child: Text('No photos on this transect yet.'));

    final meter = frame.meterMark?.round();
    final noFrame = frame.excludeReason == kNoFrameReason;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '${meter == null ? '' : '$meter m · '}Photo ${_index + 1} of ${_frames.length} · '
            '$_withoutCorners without corners'
            '${noFrame ? ' · No frame visible' : ''}',
            style: const TextStyle(color: Colors.white, fontSize: 16),
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(child: _photoWithCorners(frame)),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              GloveButton(
                label: 'Previous',
                icon: Icons.chevron_left,
                onPressed: _index > 0 && !_saving ? () => _goTo(_index - 1) : null,
              ),
              GloveButton(
                label: 'Copy previous',
                icon: Icons.content_copy,
                onPressed: _previousCorners != null && !_saving ? _copyPrevious : null,
              ),
              GloveButton(
                label: 'No frame visible',
                icon: Icons.hide_image_outlined,
                onPressed: _saving || noFrame ? null : _markNoFrame,
              ),
              GloveButton(label: 'Save corners', icon: Icons.check, onPressed: _saving ? null : _save),
              GloveButton(
                label: 'Next',
                icon: Icons.chevron_right,
                onPressed: _index < _frames.length - 1 && !_saving ? () => _goTo(_index + 1) : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _photoWithCorners(TransectFrame frame) {
    final w = frame.widthPx, h = frame.heightPx;
    final aspect = w != null && h != null && w > 0 && h > 0 ? w / h : 4 / 3;
    // The photo sits inset by half a handle on every side, inside a box that
    // owns the whole area: a corner at the photo's edge keeps its full
    // touch target (a Stack only hit-tests inside its own bounds), and
    // stays clear of the iOS edge-swipe back gesture.
    const pad = _handle / 2;
    return LayoutBuilder(builder: (context, outer) {
      final maxW = outer.maxWidth - 2 * pad, maxH = outer.maxHeight - 2 * pad;
      final w = maxW / maxH > aspect ? maxH * aspect : maxW;
      final box = Size(w, w / aspect);
      return Center(
        child: SizedBox(
          width: box.width + 2 * pad,
          height: box.height + 2 * pad,
          child: Stack(
            children: [
              Positioned(
                left: pad,
                top: pad,
                width: box.width,
                height: box.height,
                child: Image.file(
                  File(_store.absolutePath(frame.imagePath)),
                  key: ValueKey(frame.imagePath),
                  fit: BoxFit.fill,
                  cacheWidth: 1600,
                  errorBuilder: (_, _, _) => const ColoredBox(
                    color: Colors.black26,
                    child: Center(child: Icon(Icons.broken_image, color: Colors.white54, size: 48)),
                  ),
                ),
              ),
              Positioned(
                left: pad,
                top: pad,
                width: box.width,
                height: box.height,
                child: CustomPaint(painter: _QuadPainter(_corners)),
              ),
              for (var k = 0; k < 4; k++)
                // pad + x·w − handle/2, and pad is handle/2.
                Positioned(
                  left: _corners[k].x * box.width,
                  top: _corners[k].y * box.height,
                  child: GestureDetector(
                    key: ValueKey('corner-$k'),
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (d) => _drag(k, d.delta, box),
                    child: Container(
                      width: _handle,
                      height: _handle,
                      alignment: Alignment.center,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.healthy.withValues(alpha: 0.6),
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }

  /// Glove-sized touch target around each corner dot.
  static const double _handle = 56;
}

class _QuadPainter extends CustomPainter {
  _QuadPainter(this.corners);
  final List<NormPoint> corners;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..moveTo(corners[0].x * size.width, corners[0].y * size.height);
    for (final c in corners.skip(1)) {
      path.lineTo(c.x * size.width, c.y * size.height);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = isValidFrame(orderCorners(corners)) ? AppColors.healthy : AppColors.bleached,
    );
  }

  @override
  bool shouldRepaint(_QuadPainter old) => true;
}
