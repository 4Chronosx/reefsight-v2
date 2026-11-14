import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/device_info.dart';
import '../services/share_package.dart';

/// Loads what could be shared (a station, or one unassigned survey).
typedef ShareSourceLoader = Future<ShareSource> Function();

/// Writes the package and opens the share sheet. Injected in tests, which
/// have no share sheet.
typedef SharePackageRunner = Future<void> Function(ShareSource source, ShareOptions options, Rect? origin);

/// Writes the zip to the temporary directory, refusing it when the phone
/// hasn't room ([PlatformDeviceInfo]; unchecked where that reads `null`),
/// and opens the share sheet.
Future<void> runSharePackage(ShareSource source, ShareOptions options, Rect? origin) async {
  final zip = await writeShareZip(
    source,
    options,
    outputDirectory: await getTemporaryDirectory(),
    freeBytes: await const PlatformDeviceInfo().freeBytes(),
  );
  await shareZip(zip, subject: 'ReefSight ${p.basenameWithoutExtension(zip)}', origin: origin);
}

/// Issue #9: Share / Save. Loads the source, lets the diver pick transects
/// and content in [SharePackageSheet], then packs and shares. With
/// [onlySessionId] the sheet starts with that transect alone. Errors end
/// in a SnackBar, as the laptop export's do.
Future<void> shareSurveyPackage(
  BuildContext context, {
  required ShareSourceLoader load,
  int? onlySessionId,
  SharePackageRunner? run,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final box = context.findRenderObject() as RenderBox?;
  final origin = box != null && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;
  try {
    final source = await load();
    if (!context.mounted) return;
    final options = await showModalBottomSheet<ShareOptions>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SharePackageSheet(source: source, initial: source.defaultOptions(onlySessionId: onlySessionId)),
    );
    if (options == null) return;
    // Up until the share sheet opens: a station with photos takes a while.
    messenger.showSnackBar(const SnackBar(content: Text('Packing…'), duration: Duration(minutes: 5)));
    try {
      await (run ?? runSharePackage)(source, options, origin);
    } finally {
      messenger.hideCurrentSnackBar();
    }
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('Share failed: ${_reason(error)}')));
  }
}

String _reason(Object error) => switch (error) {
      StateError(:final message) => message,
      ArgumentError(:final message) => '$message',
      _ => '$error',
    };

/// The content picker: which transects (a station's), whether photos,
/// colony photos and video go in, and the total size. Summaries always go.
/// Pops the chosen [ShareOptions].
class SharePackageSheet extends StatefulWidget {
  const SharePackageSheet({super.key, required this.source, required this.initial});

  final ShareSource source;
  final ShareOptions initial;

  @override
  State<SharePackageSheet> createState() => _SharePackageSheetState();
}

class _SharePackageSheetState extends State<SharePackageSheet> {
  late ShareOptions _options = widget.initial;

  ShareSource get _source => widget.source;

  void _toggleTransect(int id, bool on) {
    final ids = {..._options.sessionIds};
    on ? ids.add(id) : ids.remove(id);
    setState(() => _options = _options.copyWith(sessionIds: ids));
  }

  @override
  Widget build(BuildContext context) {
    final none = _options.sessionIds.isEmpty;
    final bytes = none ? 0 : _source.bytesFor(_options);
    final missing = none ? const <String>[] : _source.missingPhotos(_options);
    final summary = !none && _source.includesStationSummary(_options);
    final hint = TextStyle(color: Colors.grey.shade700, fontSize: 12, height: 1.4);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Share / Save', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              none ? 'Choose at least one transect.' : '${_source.rootName(_options)}.zip',
              key: const Key('share-zip-name'),
              style: hint,
            ),
            if (_source.station != null && _source.transects.length > 1) ...[
              const SizedBox(height: 12),
              const Text('Transects', style: TextStyle(fontWeight: FontWeight.bold)),
              for (final t in _source.transects)
                CheckboxListTile(
                  key: Key('share-transect-${t.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(t.folder),
                  value: _options.sessionIds.contains(t.id),
                  onChanged: (v) => _toggleTransect(t.id, v ?? false),
                ),
            ],
            const SizedBox(height: 12),
            const Text('Content', style: TextStyle(fontWeight: FontWeight.bold)),
            const CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text('Summaries (CSV)'),
              value: true,
              onChanged: null,
            ),
            if (_source.hasPhotos)
              CheckboxListTile(
                key: const Key('share-photos'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Photos and frames'),
                value: _options.photos,
                onChanged: (v) => setState(() => _options = _options.copyWith(photos: v ?? false)),
              ),
            if (_source.hasColonyPhotos)
              CheckboxListTile(
                key: const Key('share-colony-photos'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Colony photos'),
                value: _options.colonyPhotos,
                onChanged: (v) => setState(() => _options = _options.copyWith(colonyPhotos: v ?? false)),
              ),
            if (_source.hasVideo)
              CheckboxListTile(
                key: const Key('share-video'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Video'),
                subtitle: const Text('Large: up to about a gigabyte per transect'),
                value: _options.video,
                onChanged: (v) => setState(() => _options = _options.copyWith(video: v ?? false)),
              ),
            const SizedBox(height: 8),
            Text('Total: about ${describeBytes(bytes)}', key: const Key('share-size')),
            if (bytes > kLargeShareBytes)
              Text('Over ${describeBytes(kLargeShareBytes)}: Drive and email may not take it. '
                  'AirDrop or Save to Files on the phone is safer.', style: hint),
            if (_source.station != null && _source.summary != null && !summary && !none)
              Text('The station summary is left out: it needs every transect.', style: hint),
            if (missing.isNotEmpty)
              Text('${missing.length} photo file(s) are missing from the phone. Leave photos out to share the rest.',
                  style: hint.copyWith(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('share-go'),
              onPressed: none || missing.isNotEmpty ? null : () => Navigator.of(context).pop(_options),
              icon: const Icon(Icons.ios_share),
              label: const Text('Share'),
            ),
          ],
        ),
      ),
    );
  }
}
