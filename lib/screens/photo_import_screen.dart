import 'dart:io';

import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/app_database.dart';
import '../services/photo_import.dart';
import '../services/photo_import_checks.dart';
import '../services/photo_import_order.dart';
import '../services/photo_metadata.dart';
import '../services/photo_source.dart';
import '../services/photo_transect_store.dart';
import '../services/station.dart';
import '../services/transect_database.dart';
import '../widgets/glove_button.dart';
import 'frame_corner_editor_screen.dart';
import 'photo_transect_capture_screen.dart' show appDocumentsPath;

/// Issue #5: import a photo transect shot on another camera (alignment doc
/// §9) -- pick from Photos or Files, check the order (EXIF time, filename
/// fallback), drop extra shots, mark gaps, answer the lens question for a
/// GoPro, save, then set each photo's corners. Topside work, so a normal
/// (not housing) layout; the controls still use glove-sized buttons.
class PhotoImportScreen extends StatefulWidget {
  const PhotoImportScreen({
    super.key,
    required this.station,
    required this.sessionId,
    required this.transectNumber,
    this.openDatabase = openAppDatabase,
    this.documentsDirectory = appDocumentsPath,
    this.photoSource = const PluginPhotoSource(),
    this.reader = const RoutingMetadataReader(),
  });

  final Station station;
  final int sessionId;
  final int transectNumber;
  final DatabaseOpener openDatabase;
  final Future<String> Function() documentsDirectory;
  final PhotoSource photoSource;
  final PhotoMetadataReader reader;

  @override
  State<PhotoImportScreen> createState() => _PhotoImportScreenState();
}

class _PhotoImportScreenState extends State<PhotoImportScreen> {
  TransectDatabase? _db;
  PhotoImport? _import;
  String? _docs;
  Object? _loadError;
  bool _disposed = false;

  String get _title => '${widget.station.code} · T${widget.transectNumber}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final db = await widget.openDatabase();
      if (_disposed) {
        await db.close();
        return;
      }
      _db = db;
      final session = await db.sessionById(widget.sessionId);
      if (session == null) throw StateError('Transect ${widget.sessionId} is not on this phone');
      final docs = await widget.documentsDirectory();
      final import = PhotoImport(
        db: db,
        store: PhotoTransectStore(documentsDirectory: docs, sessionId: widget.sessionId),
        reader: widget.reader,
        sessionId: widget.sessionId,
        tapeLengthMeters: session.tapeLengthMeters,
      );
      await import.load();
      if (_disposed) return;
      import.addListener(_onChanged);
      setState(() {
        _docs = docs;
        _import = import;
      });
    } catch (error) {
      debugPrint('ReefSight: opening photo import failed: $error');
      if (mounted) setState(() => _loadError = error);
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    _import?.removeListener(_onChanged);
    _import?.dispose();
    _db?.close();
    super.dispose();
  }

  Future<void> _pick(Future<List<PickedPhoto>> Function() picker) async {
    final import = _import;
    if (import == null || import.busy) return;
    try {
      final picked = await picker();
      if (picked.isEmpty || !mounted) return;
      await import.addPhotos(picked);
    } catch (error) {
      debugPrint('ReefSight: picking photos failed: $error');
      _snack('Could not import: $error');
    }
  }

  Future<void> _save() async {
    try {
      await _import!.save();
      _snack('Saved ${_import!.photos.length} photos.');
    } catch (error) {
      debugPrint('ReefSight: saving the import failed: $error');
      _snack('Could not save: $error');
    }
  }

  Future<void> _openCorners() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FrameCornerEditorScreen(
        db: _db!,
        sessionId: widget.sessionId,
        documentsDirectory: _docs!,
        title: _title,
      ),
    ));
    await _import?.load();
  }

  /// Leaving with unsaved changes asks first; "Discard" deletes the copies
  /// made since the last save.
  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave without saving?'),
        content: const Text('Photos added or changes made since the last save will be lost.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Stay')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
        ],
      ),
    );
    if (leave != true || !mounted) return;
    await _import?.discard();
    if (mounted) Navigator.of(context).pop();
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final import = _import;
    return PopScope(
      canPop: import == null || (!import.dirty && !import.busy),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !(import?.busy ?? false)) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(title: Text('Import photos · $_title')),
        body: SafeArea(child: _body()),
      ),
    );
  }

  Widget _body() {
    if (_loadError != null) return Center(child: Text('Could not open this transect: $_loadError'));
    final import = _import;
    if (import == null) return const Center(child: CircularProgressIndicator());

    final withoutCorners = import.savedWithoutCorners;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              GloveButton(
                label: 'From Photos',
                icon: Icons.photo_library_outlined,
                onPressed: import.busy ? null : () => _pick(widget.photoSource.pickFromLibrary),
              ),
              GloveButton(
                label: 'From Files',
                icon: Icons.folder_open,
                onPressed: import.busy ? null : () => _pick(widget.photoSource.pickFromFiles),
              ),
            ],
          ),
        ),
        if (import.busy && import.progressTotal > 0)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('Copying ${import.progressDone} of ${import.progressTotal}…'),
          ),
        Expanded(
          child: import.slots.isEmpty
              ? Column(children: [
                  ..._checks(import),
                  const Expanded(
                    child: Center(child: Text('No photos yet. Pick a transect\'s photos from Photos or Files.')),
                  ),
                ])
              : ReorderableListView.builder(
                  // The checks scroll with the list, so on a small phone
                  // they never squeeze the photos off screen.
                  header: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _checks(import)),
                  itemCount: import.slots.length,
                  onReorder: (from, to) {
                    if (!import.busy) import.move(from, to);
                  },
                  itemBuilder: (context, i) => _slotTile(import, i),
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              GloveButton(
                label: 'Save order',
                icon: Icons.save_outlined,
                onPressed: import.canSave && import.dirty ? _save : null,
              ),
              GloveButton(
                label: withoutCorners > 0 ? 'Set corners ($withoutCorners left)' : 'Corners',
                icon: Icons.crop_free,
                onPressed: !import.dirty && !import.busy && import.photos.isNotEmpty ? _openCorners : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _checks(PhotoImport import) {
    final lines = <Widget>[];
    void warn(String text, {bool bad = true}) => lines.add(_CheckLine(text: text, bad: bad));

    if (import.photos.isNotEmpty) {
      warn(
        '${import.photos.length} photos for ${import.expectedCount} meters '
        '(0-${import.expectedCount - 1} m), ordered by '
        '${import.orderedByTime ? 'capture time' : 'filename (some photos have no capture time)'}.',
        bad: import.countFarOff,
      );
    }
    if (import.extraCount > 0) {
      warn('${import.extraCount} past the end of the tape: remove extra shots before saving.');
    }
    if (import.cameras > 1) warn('Photos from ${import.cameras} cameras: check they are one transect.');
    if (import.failedNames.isNotEmpty) warn('Could not import: ${import.failedNames.join(', ')}.');
    if (import.photos.any((p) => isActionCamera(p.metadata))) {
      lines.add(_LensQuestion(selected: import.lensMode, onSelected: import.setLensMode));
    }
    return lines;
  }

  Widget _slotTile(PhotoImport import, int i) {
    final slot = import.slots[i];
    final meter = import.meterAt(i).round();
    final past = i >= import.expectedCount;
    final menu = PopupMenuButton<String>(
      key: ValueKey('menu-$i'),
      onSelected: (action) => action == 'gap' ? import.insertGap(i) : import.drop(i),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'gap', child: Text('Insert gap before')),
        PopupMenuItem(value: 'drop', child: Text('Remove')),
      ],
    );
    return switch (slot) {
      GapSlot() => ListTile(
          key: ObjectKey(slot),
          leading: const SizedBox(width: 56, child: Icon(Icons.not_interested)),
          title: Text('$meter m · No photo (gap)'),
          trailing: menu,
        ),
      PhotoSlot(:final photo) => ListTile(
          key: ValueKey(photo.relativePath),
          leading: SizedBox(
            width: 56,
            height: 56,
            child: Image.file(
              File(import.store.absolutePath(photo.relativePath)),
              fit: BoxFit.cover,
              cacheWidth: 112,
              errorBuilder: (_, _, _) => const Icon(Icons.image_outlined),
            ),
          ),
          title: Text(
            '$meter m · ${photo.originalName}',
            style: past ? const TextStyle(color: AppColors.bleached) : null,
          ),
          subtitle: Text(_describe(import, photo)),
          trailing: menu,
        ),
    };
  }

  String _describe(PhotoImport import, ImportedPhoto photo) {
    final m = photo.metadata;
    final t = m.capturedAt?.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return [
      if (t != null) '${two(t.hour)}:${two(t.minute)}:${two(t.second)}',
      if (m.model != null || m.make != null) m.model ?? m.make!,
      if (isUnder5Mp(m)) 'Under 5 MP',
      if (isSizeUnknown(m)) 'Size unknown',
      if (import.fisheyeSuspected(photo)) 'Fisheye?',
    ].join(' · ');
  }
}

class _CheckLine extends StatelessWidget {
  const _CheckLine({required this.text, required this.bad});
  final String text;
  final bool bad;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(bad ? Icons.warning_amber : Icons.info_outline, color: bad ? AppColors.bleached : null, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ],
        ),
      );
}

/// GoPros don't record their lens mode in EXIF, so it's asked once per
/// import. Anything but Linear keeps the fisheye flag on every GoPro photo.
class _LensQuestion extends StatelessWidget {
  const _LensQuestion({required this.selected, required this.onSelected});
  final LensMode? selected;
  final ValueChanged<LensMode> onSelected;

  static const _labels = {
    LensMode.linear: 'Linear',
    LensMode.wide: 'Wide',
    LensMode.superView: 'SuperView',
    LensMode.unknown: 'Not sure',
  };

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Which GoPro lens mode was used? Linear is recommended: Wide and SuperView '
                'bend the frame (fisheye).'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                for (final e in _labels.entries)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: selected == e.key,
                    onSelected: (_) => onSelected(e.key),
                  ),
              ],
            ),
          ],
        ),
      );
}
