import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../services/geo_fix.dart';
import '../services/geo_fix_controller.dart';

/// Shown under a manual fix that's more than 50 km from Cordova (sub-plan
/// 12 step 3). A hint, never a rejection.
const farFromCordovaHint =
    'Far from Cordova. Check for swapped lat/lon or a missing minus sign.';

/// Sub-plan 12 steps 3-4: one GPS fix's status line and actions, shared by
/// Setup's "Entry position" card and Summary's exit fix. Shows
/// `Acquiring…`, the fix (`±8 m · 10.3256° N, 123.9468° E`), or the
/// failure reason; offers Retry and **Enter manually** (decision 4: manual
/// is always available). Card chrome is the caller's.
///
/// With [onConfirm] set (Summary), a fix is only a candidate until the
/// diver taps [confirmLabel] -- the exit fix is write-once, so nothing is
/// stored by just acquiring.
class GeoFixPanel extends StatelessWidget {
  const GeoFixPanel({
    super.key,
    required this.controller,
    this.idleLabel = 'Get GPS position',
    this.allowGps = true,
    this.gpsUnavailableNote,
    this.confirmLabel = 'Save',
    this.onConfirm,
    this.saving = false,
  });

  final GeoFixController controller;

  /// The GPS button before anything has been tried.
  final String idleLabel;

  /// `false` hides the GPS buttons and leaves manual entry only -- Summary,
  /// for a dive that ended too long ago for the phone's current position
  /// to be the exit position.
  final bool allowGps;

  /// Shown in place of a status when [allowGps] is `false` and nothing has
  /// been entered yet.
  final String? gpsUnavailableNote;

  final String confirmLabel;
  final ValueChanged<GeoFix>? onConfirm;

  /// Disables the confirm button while the caller is storing the fix.
  final bool saving;

  Future<void> _enterManually(BuildContext context, GeoFix? current) async {
    final fix = await showManualFixDialog(context, initial: current);
    if (fix != null) controller.setManual(fix);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<GeoFixState>(
      valueListenable: controller,
      builder: (context, state, _) {
        final fix = state.fix;
        final failure = state.failure;
        final muted = TextStyle(
          fontSize: 13,
          color: AppColors.onSurface.withValues(alpha: 0.7),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (fix != null) ...[
              Text(
                formatFix(fix),
                key: const ValueKey('geo-fix-value'),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              if (fix.source == GeoFixSource.manual && !isNearCordova(fix.lat, fix.lon))
                Text(farFromCordovaHint, style: TextStyle(fontSize: 12, color: Colors.amber.shade800)),
            ],
            if (state.acquiring)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Acquiring…'),
                  ],
                ),
              )
            else if (failure != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(failure.reason, style: muted),
              )
            else if (fix == null && !allowGps && gpsUnavailableNote != null)
              Text(gpsUnavailableNote!, style: muted),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (allowGps && !state.acquiring)
                  TextButton.icon(
                    icon: const Icon(Icons.my_location_rounded, size: 18),
                    label: Text(state.idle ? idleLabel : 'Retry'),
                    onPressed: controller.acquire,
                  ),
                TextButton.icon(
                  icon: const Icon(Icons.edit_location_alt_outlined, size: 18),
                  label: Text(fix?.source == GeoFixSource.manual ? 'Edit' : 'Enter manually'),
                  onPressed: () => _enterManually(context, fix),
                ),
                if (onConfirm != null && fix != null)
                  ElevatedButton(
                    onPressed: saving ? null : () => onConfirm!(fix),
                    child: Text(confirmLabel),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Manual entry in decimal degrees (sub-plan 12 step 3): latitude -90..90,
/// longitude -180..180, Save disabled until both are valid. A point far
/// from Cordova gets [farFromCordovaHint] but can still be saved. Returns
/// `null` on cancel.
Future<GeoFix?> showManualFixDialog(BuildContext context, {GeoFix? initial}) {
  return showDialog<GeoFix>(
    context: context,
    builder: (context) => _ManualFixDialog(initial: initial),
  );
}

class _ManualFixDialog extends StatefulWidget {
  const _ManualFixDialog({this.initial});

  final GeoFix? initial;

  @override
  State<_ManualFixDialog> createState() => _ManualFixDialogState();
}

class _ManualFixDialogState extends State<_ManualFixDialog> {
  late final _lat = TextEditingController(text: widget.initial?.lat.toString() ?? '');
  late final _lon = TextEditingController(text: widget.initial?.lon.toString() ?? '');

  @override
  void dispose() {
    _lat.dispose();
    _lon.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final latError = latitudeError(_lat.text);
    final lonError = longitudeError(_lon.text);
    final valid = latError == null && lonError == null;
    final far = valid &&
        !isNearCordova(double.parse(_lat.text.trim()), double.parse(_lon.text.trim()));
    const keyboard = TextInputType.numberWithOptions(signed: true, decimal: true);
    return AlertDialog(
      title: const Text('Enter position'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Decimal degrees, e.g. from the boat GPS. South and west are negative.',
            style: TextStyle(fontSize: 13),
          ),
          TextField(
            key: const ValueKey('manual-lat'),
            controller: _lat,
            keyboardType: keyboard,
            decoration: InputDecoration(
              labelText: 'Latitude',
              hintText: '10.2536',
              errorText: _lat.text.isEmpty ? null : latError,
            ),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            key: const ValueKey('manual-lon'),
            controller: _lon,
            keyboardType: keyboard,
            decoration: InputDecoration(
              labelText: 'Longitude',
              hintText: '123.9497',
              errorText: _lon.text.isEmpty ? null : lonError,
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (far)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                farFromCordovaHint,
                style: TextStyle(fontSize: 12, color: Colors.amber.shade800),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: valid
              ? () => Navigator.of(context).pop(
                    GeoFix(
                      lat: double.parse(_lat.text.trim()),
                      lon: double.parse(_lon.text.trim()),
                      at: DateTime.now(),
                      source: GeoFixSource.manual,
                    ),
                  )
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
