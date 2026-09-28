import 'package:flutter/material.dart';

import '../glove_button.dart';

/// Confirm sheet before ending a transect (sub-plan 6, ui-ux-overhaul, step
/// 6): "Tapping [End Transect] opens a confirm sheet ('End transect? N
/// colonies recorded') with two large buttons, Keep surveying and End.
/// Tapping twice by accident underwater must not end a dive." Also driven
/// by the `PopScope` back/edge-swipe guard (`live_transect_screen.dart`), so
/// both paths to ending a transect go through the same confirmation and the
/// same downstream `_endTransect()` -- this function only decides whether
/// to proceed, never touches session state itself (sub-plan decision 5).
Future<bool> showEndTransectSheet(
  BuildContext context, {
  required int colonyCount,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'End transect? $colonyCount '
              '${colonyCount == 1 ? 'colony' : 'colonies'} recorded.',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            GloveButton(
              label: 'Keep surveying',
              inWater: true,
              onPressed: () => Navigator.of(context).pop(false),
            ),
            const SizedBox(height: 12),
            GloveButton(
              label: 'End transect',
              destructive: true,
              inWater: true,
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ),
    ),
  );
  return result ?? false;
}
