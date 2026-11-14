import 'dart:io';

import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/app_database.dart';
import '../services/app_settings.dart';
import '../services/frame_point.dart';
import '../services/genus_tag.dart';
import '../services/photo_transect_store.dart';
import '../services/point_sampler.dart';
import '../services/tau_catalogue.dart';
import '../services/tb_categories.dart';
import '../services/transect_database.dart';
import '../services/transect_frame.dart';
import '../widgets/glove_button.dart';
import '../widgets/section_card.dart';
import 'photo_transect_capture_screen.dart' show appDocumentsPath;

/// Issue #10: expert review of one photo transect, frame by frame.
///
/// - **Points.** Each frame's scoring points sit on its photo, placed through
///   its 1 × 1 m corners (`frameToImage`). Tapping one shows the model's
///   label; the reviewer accepts it (the same code, stored as reviewed),
///   picks another TB 2017-05 code, or clears an earlier correction. The
///   model's label is never overwritten (`setExpertCategory`).
/// - **Genus groups.** The reviewer tags the TAUs (TB 2019-04 Table 3) seen
///   in the photo, and those seen along the tape but in no photo.
/// - **Who.** The first change asks for the reviewer's name, pre-filled from
///   the station's observer, and keeps it in [AppSettings.reviewerName].
///
/// Every change goes to the database at once, so leaving the screen loses
/// nothing; cover is rebuilt from the corrections by whatever reads it next.
class PointReviewScreen extends StatefulWidget {
  const PointReviewScreen({
    super.key,
    required this.sessionId,
    required this.title,
    this.openDatabase = openAppDatabase,
    this.documentsDirectory = appDocumentsPath,
    this.now = DateTime.now,
  });

  final int sessionId;
  final String title;
  final DatabaseOpener openDatabase;
  final Future<String> Function() documentsDirectory;
  final DateTime Function() now;

  @override
  State<PointReviewScreen> createState() => _PointReviewScreenState();
}

/// What the point sheet hands back.
sealed class _PointChoice {}

class _Accept extends _PointChoice {}

class _Clear extends _PointChoice {}

class _Code extends _PointChoice {
  _Code(this.code);
  final String code;
}

class _PointReviewScreenState extends State<PointReviewScreen> {
  List<TransectFrame> _frames = const [];
  Map<int, List<FramePoint>> _points = const {};
  List<GenusTag> _tags = const [];
  String? _observer;
  String? _docs;
  int _index = 0;
  bool _loaded = false;
  bool _busy = false;
  Object? _error;

  TransectFrame? get _frame => _frames.isEmpty ? null : _frames[_index];

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Whether it loaded.
  Future<bool> _load() async {
    try {
      final docs = _docs ?? await widget.documentsDirectory();
      final db = await widget.openDatabase();
      try {
        final session = await db.sessionById(widget.sessionId);
        final stationId = session?.stationId;
        final station = stationId == null ? null : await db.stationById(stationId);
        // After a relaunch the setting is empty: guess whoever reviewed this
        // station last, then the station's observer.
        final lastReviewer = stationId == null ? null : await db.lastReviewerForStation(stationId);
        final points = <int, List<FramePoint>>{};
        final frames = <TransectFrame>[];
        // Every photo can be tagged (tags don't need points or corners);
        // only frames with points get the point overlay.
        for (final f in await db.framesForSession(widget.sessionId)) {
          if (f.isMissing || f.imagePath.isEmpty) continue;
          frames.add(f);
          points[f.id!] = await db.pointsForFrame(f.id!);
        }
        final tags = await db.genusTagsForSession(widget.sessionId);
        if (!mounted) return true;
        setState(() {
          _docs = docs;
          _observer = lastReviewer ?? station?.observerName;
          _frames = frames;
          _points = points;
          _tags = tags;
          _index = _index.clamp(0, frames.isEmpty ? 0 : frames.length - 1);
          _loaded = true;
        });
        return true;
      } finally {
        await db.close();
      }
    } catch (error) {
      debugPrint('ReefSight: loading the review failed: $error');
      if (mounted) setState(() => _error = error);
      return false;
    }
  }

  /// The reviewer's name, asked for once; `null` if they cancel.
  Future<String?> _reviewer() async {
    final remembered = AppSettings.instance.reviewerName.value.trim();
    if (remembered.isNotEmpty) return remembered;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _ReviewerDialog(initial: _observer ?? ''),
    );
    if (name == null || name.isEmpty) return null;
    AppSettings.instance.reviewerName.value = name;
    return name;
  }

  Future<void> _write(Future<void> Function(TransectDatabase db, String reviewer) change) async {
    final reviewer = await _reviewer();
    if (reviewer == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final db = await widget.openDatabase();
      try {
        await change(db, reviewer);
      } finally {
        await db.close();
      }
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $error')));
    }
    // Reloaded whether or not the save went through, so the screen shows
    // what is stored; a failed reload says so instead of "could not save".
    if (!await _load() && mounted) {
      messenger.showSnackBar(const SnackBar(content: Text('Saved, but the screen could not refresh')));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _review(FramePoint point) async {
    final choice = await showModalBottomSheet<_PointChoice>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _PointSheet(point: point),
    );
    if (choice == null || !mounted) return;
    final at = widget.now();
    await _write((db, reviewer) => switch (choice) {
          _Accept() => db.setExpertCategory(point.id!, point.categoryCode!, by: reviewer, at: at),
          _Clear() => db.clearExpertCategory(point.id!),
          _Code(:final code) => db.setExpertCategory(point.id!, code, by: reviewer, at: at),
        });
  }

  Future<void> _tagFrame(TransectFrame frame) async {
    final current = {for (final t in _tags) if (t.frameId == frame.id) t.tauCode};
    final picked = await _pickTaus('Genus groups in this photo', current);
    if (picked == null || _sameSet(picked, current) || !mounted) return;
    await _write((db, reviewer) => db.setFrameTaus(frame.id!, picked, by: reviewer, at: widget.now()));
  }

  Future<void> _tagTape() async {
    final current = {for (final t in _tags) if (t.frameId == null) t.tauCode};
    final picked = await _pickTaus('Seen on the tape, in no photo', current);
    if (picked == null || _sameSet(picked, current) || !mounted) return;
    await _write((db, reviewer) => db.setTransectTaus(widget.sessionId, picked, by: reviewer, at: widget.now()));
  }

  static bool _sameSet(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

  Future<Set<String>?> _pickTaus(String title, Set<String> current) => showModalBottomSheet<Set<String>>(
        context: context,
        isScrollControlled: true,
        builder: (context) => _TauPicker(title: title, initial: current),
      );

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: !_loaded
            ? Center(child: _error != null ? Text('Could not load: $_error') : const CircularProgressIndicator())
            : _body(frame),
      ),
    );
  }

  Widget _body(TransectFrame? frame) {
    final points = frame == null ? const <FramePoint>[] : _points[frame.id] ?? const <FramePoint>[];
    final reviewed = points.where((p) => p.expertCategoryCode != null).length;
    final transectTaus = {for (final t in _tags) t.tauCode};
    final frameTaus = [for (final t in _tags) if (frame != null && t.frameId == frame.id) t.tauCode]..sort();
    final tapeTaus = [for (final t in _tags) if (t.frameId == null) t.tauCode]..sort();
    final meter = frame?.meterMark;
    final scored = frame != null && frame.corners != null && points.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (frame == null)
          const Text('No photos yet. Genus groups seen on the tape can still be tagged below.')
        else ...[
        Text(
          'Frame ${_index + 1} of ${_frames.length}${meter == null ? '' : ' · ${_meters(meter)} m'}',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          scored
              ? '$reviewed of ${points.length} points reviewed'
              : frame.excluded
                  ? 'Excluded from cover: genus groups can still be tagged'
                  : 'No points yet: they are placed when the frames are exported for analysis',
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 8),
        AspectRatio(
          aspectRatio: _aspect(frame),
          child: LayoutBuilder(
            builder: (context, box) =>
                _photoWithPoints(frame, scored ? points : const [], Size(box.maxWidth, box.maxHeight)),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: GloveButton(
                label: 'Previous',
                icon: Icons.chevron_left,
                onPressed: _index > 0 && !_busy ? () => setState(() => _index--) : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GloveButton(
                label: 'Next',
                icon: Icons.chevron_right,
                onPressed: _index < _frames.length - 1 && !_busy ? () => setState(() => _index++) : null,
              ),
            ),
          ],
        ),
        ],
        const SizedBox(height: 16),
        SectionCard(
          icon: Icons.local_florist_outlined,
          title: 'Genus groups (TAUs)',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Transect: ${transectTaus.length} TAUs', style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              if (frame != null) ...[
                if (frameTaus.isEmpty)
                  const Text('None tagged in this photo.', style: TextStyle(fontSize: 13))
                else
                  Wrap(spacing: 6, runSpacing: 6, children: [for (final c in frameTaus) Chip(label: Text(c))]),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _tagFrame(frame),
                  icon: const Icon(Icons.sell_outlined),
                  label: const Text('Tag genus groups'),
                ),
                const SizedBox(height: 8),
              ],
              if (tapeTaus.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('On the tape: ${tapeTaus.join(', ')}', style: const TextStyle(fontSize: 13)),
                ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _tagTape,
                icon: const Icon(Icons.straighten),
                label: const Text('Seen on tape, not in a photo'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static double _aspect(TransectFrame f) {
    final w = f.widthPx, h = f.heightPx;
    return w != null && h != null && w > 0 && h > 0 ? w / h : 4 / 3;
  }

  static String _meters(double m) => m == m.roundToDouble() ? m.toStringAsFixed(0) : m.toString();

  Widget _photoWithPoints(TransectFrame frame, List<FramePoint> points, Size box) {
    const target = 44.0;
    // A frame without corners (not set yet, or "no frame visible") shows the
    // photo alone, for tagging; points are only drawn with corners.
    final corners = frame.corners;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Image.file(
            File(PhotoTransectStore(documentsDirectory: _docs!, sessionId: widget.sessionId)
                .absolutePath(frame.imagePath)),
            key: ValueKey(frame.imagePath),
            fit: BoxFit.fill,
            cacheWidth: 1600,
            errorBuilder: (_, _, _) => const ColoredBox(
              color: Colors.black26,
              child: Center(child: Icon(Icons.broken_image, color: Colors.white54, size: 48)),
            ),
          ),
        ),
        if (corners != null) Positioned.fill(child: CustomPaint(painter: _QuadPainter(corners))),
        if (corners != null)
          for (final pt in points)
          Builder(builder: (context) {
            final at = frameToImage(corners, (x: pt.xNorm, y: pt.yNorm));
            return Positioned(
              left: at.x * box.width - target / 2,
              top: at.y * box.height - target / 2,
              width: target,
              height: target,
              child: GestureDetector(
                key: ValueKey('point-${pt.pointIndex}'),
                behavior: HitTestBehavior.opaque,
                onTap: _busy ? null : () => _review(pt),
                child: Center(child: _PointDot(point: pt)),
              ),
            );
          }),
      ],
    );
  }
}

/// Owns its controller, so it outlives the dialog's closing animation.
class _ReviewerDialog extends StatefulWidget {
  const _ReviewerDialog({required this.initial});
  final String initial;

  @override
  State<_ReviewerDialog> createState() => _ReviewerDialogState();
}

class _ReviewerDialogState extends State<_ReviewerDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Reviewer name'),
        content: TextField(
          controller: _controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(helperText: 'Saved with each correction and genus tag'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, _controller.text.trim()), child: const Text('Save')),
        ],
      );
}

/// Numbered dot: teal once reviewed, white with the model's label, grey
/// when the point has no label yet.
class _PointDot extends StatelessWidget {
  const _PointDot({required this.point});
  final FramePoint point;

  @override
  Widget build(BuildContext context) {
    final reviewed = point.expertCategoryCode != null;
    final color = reviewed
        ? AppColors.healthy
        : point.categoryCode == null
            ? AppColors.unknown
            : Colors.white;
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.85),
        border: Border.all(color: Colors.black87, width: 1.5),
      ),
      child: Text(
        '${point.pointIndex + 1}',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: reviewed ? Colors.white : Colors.black87,
        ),
      ),
    );
  }
}

class _PointSheet extends StatelessWidget {
  const _PointSheet({required this.point});
  final FramePoint point;

  @override
  Widget build(BuildContext context) {
    String label(String code) => '${tbCategory(code).name} ($code)';
    final model = point.modelClass;
    final conf = point.modelConfidence;
    final mapped = point.categoryCode;
    final summary = model == null
        ? 'Model: not analyzed'
        : 'Model: $model${conf == null ? '' : ' (${(conf * 100).round()}%)'}'
            '${mapped == null ? '' : ' → ${label(mapped)}'}';
    final expert = point.expertCategoryCode;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ListTile(
            title: Text('Point ${point.pointIndex + 1}', style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text([summary, if (expert != null) 'Reviewer: ${label(expert)} (${point.expertName ?? '?'})']
                .join('\n')),
          ),
          if (mapped != null)
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('Accept model label'),
              onTap: () => Navigator.pop(context, _Accept()),
            ),
          if (expert != null)
            ListTile(
              leading: const Icon(Icons.undo),
              title: const Text('Clear correction'),
              onTap: () => Navigator.pop(context, _Clear()),
            ),
          const Divider(),
          for (final major in MajorCategory.values) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(major.db, style: Theme.of(context).textTheme.labelLarge),
            ),
            for (final c in kTbCategories.values)
              if (c.major == major)
                ListTile(
                  dense: true,
                  title: Text(label(c.code)),
                  trailing: c.code == expert ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(context, _Code(c.code)),
                ),
          ],
        ],
      ),
    );
  }
}

/// Multi-select of TB 2019-04 TAUs: the priority units first, then the rest
/// by name, filtered by name or code. Hands back the set on Done.
class _TauPicker extends StatefulWidget {
  const _TauPicker({required this.title, required this.initial});
  final String title;
  final Set<String> initial;

  @override
  State<_TauPicker> createState() => _TauPickerState();
}

class _TauPickerState extends State<_TauPicker> {
  late final Set<String> _selected = {...widget.initial};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final t in tausForPicker())
        if (q.isEmpty || t.name.toLowerCase().contains(q) || t.code.toLowerCase().contains(q)) t,
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(child: Text(widget.title, style: Theme.of(context).textTheme.titleMedium)),
                FilledButton(onPressed: () => Navigator.pop(context, _selected), child: const Text('Done')),
              ],
            ),
            const SizedBox(height: 4),
            Text('${_selected.length} selected · TB 2019-04 Table 3', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search genus or code'),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in shown)
                  FilterChip(
                    label: Text('${t.name} (${t.code})'),
                    selected: _selected.contains(t.code),
                    onSelected: (on) => setState(() => on ? _selected.add(t.code) : _selected.remove(t.code)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
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
        ..strokeWidth = 2
        ..color = AppColors.secondary,
    );
  }

  @override
  bool shouldRepaint(_QuadPainter old) => old.corners != corners;
}
