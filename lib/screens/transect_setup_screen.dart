import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import 'live_transect_screen.dart';

/// New for sub-plan 5 -- replaces `live_transect_screen.dart`'s old inline
/// `AlertDialog` prompt for tape length with a proper screen, adapted from
/// v1's `transect_setup_screen.dart` layout but collecting only what this
/// project's data model actually uses: the physical tape length (density
/// denominator, per `ReefSight_Specification.md`'s "Density, positioning,
/// and sync" -- never GPS-derived) plus site/observer metadata for the
/// report (sub-plan 5 task 2). v1's GPS start/end-point pickers are dropped
/// -- this project has no per-quadrat GPS model to feed them (see
/// `mobile/sub-plans/05-ui-and-reporting.md` plan's scoping note).
class TransectSetupScreen extends StatefulWidget {
  const TransectSetupScreen({super.key});

  @override
  State<TransectSetupScreen> createState() => _TransectSetupScreenState();
}

class _TransectSetupScreenState extends State<TransectSetupScreen> {
  final _tapeLengthController = TextEditingController(text: '10');
  final _siteController = TextEditingController();
  final _observerController = TextEditingController();

  double? get _parsedTapeLength =>
      double.tryParse(_tapeLengthController.text);

  bool get _isValid {
    final parsed = _parsedTapeLength;
    return parsed != null && parsed > 0;
  }

  @override
  void dispose() {
    _tapeLengthController.dispose();
    _siteController.dispose();
    _observerController.dispose();
    super.dispose();
  }

  void _startTransect() {
    if (!_isValid) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LiveTransectScreen(
          tapeLengthMeters: _parsedTapeLength!,
          siteName: _siteController.text.trim().isEmpty
              ? null
              : _siteController.text.trim(),
          observerName: _observerController.text.trim().isEmpty
              ? null
              : _observerController.text.trim(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Transect setup'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Enter the physical marked transect tape length -- this is '
              'the density denominator, not a GPS-derived distance.',
              style: TextStyle(color: AppColors.onSurface, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _tapeLengthController,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 20),
              decoration: InputDecoration(
                labelText: 'Tape length (meters)',
                filled: true,
                fillColor: AppColors.surface,
                border: const OutlineInputBorder(),
                errorText: _isValid ? null : 'Enter a positive number',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _siteController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Site name (optional)',
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _observerController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Observer name (optional)',
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 32),
            // Large, glove-friendly tap target (DIVEVOLK SeaTouch housing,
            // Spec's "Diver interaction" note).
            SizedBox(
              height: 56,
              child: ElevatedButton(
                onPressed: _isValid ? _startTransect : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  'Start transect',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
