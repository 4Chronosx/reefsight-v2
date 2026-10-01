import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/services/bleaching_classifier.dart';
import 'package:reefsight_mobile/services/health_aggregator.dart';
import 'package:reefsight_mobile/tracking/bot_sort_tracker.dart';
import 'package:reefsight_mobile/tracking/tracker_detection.dart';
import 'package:reefsight_mobile/widgets/live/diagnostics_overlay.dart';
import 'package:reefsight_mobile/widgets/live/end_transect_sheet.dart';
import 'package:reefsight_mobile/widgets/live/live_error_banner.dart';
import 'package:reefsight_mobile/widgets/live/recording_indicator.dart';
import 'package:reefsight_mobile/widgets/live/tally_hud.dart';

// Sub-plan 6 (ui-ux-overhaul), step 8: "Live screen widget tests can't run
// `YOLOView` headlessly. Test the extracted HUD, banner, and confirm-sheet
// widgets in isolation at a landscape test surface size." Also covers:
// "Tapping End Transect once shows the confirm sheet and doesn't end the
// session" -- exercised here as "resolves only on an explicit choice, never
// on the opening tap that got it on screen."

Widget _wrapLandscape(WidgetTester tester, Widget child) {
  tester.view.physicalSize = const Size(2400, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  testWidgets('TallyHud shows seen/healthy/bleached counts and elapsed time',
      (tester) async {
    await tester.pumpWidget(
      _wrapLandscape(
        tester,
        const TallyHud(
          seenCount: 5,
          healthyCount: 3,
          bleachedCount: 2,
          elapsed: Duration(minutes: 2, seconds: 5),
        ),
      ),
    );

    expect(find.text('02:05'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('RecordingIndicator shows REC + elapsed when recording, no error',
      (tester) async {
    await tester.pumpWidget(
      _wrapLandscape(
        tester,
        const RecordingIndicator(isRecording: true, elapsed: Duration(seconds: 42)),
      ),
    );

    expect(find.text('REC 00:42'), findsOneWidget);
  });

  testWidgets('RecordingIndicator turns amber and shows an issue message on error',
      (tester) async {
    await tester.pumpWidget(
      _wrapLandscape(
        tester,
        const RecordingIndicator(
          isRecording: true,
          elapsed: Duration.zero,
          errorMessage: 'disk full',
        ),
      ),
    );

    expect(find.text('Recording issue'), findsOneWidget);
    expect(find.text('REC 00:00'), findsNothing);
  });

  testWidgets('LiveErrorBanner shows the message and expands detail on tap',
      (tester) async {
    await tester.pumpWidget(
      _wrapLandscape(
        tester,
        const LiveErrorBanner(
          message: 'Segmentation model error',
          detail: 'raw exception text',
        ),
      ),
    );

    expect(find.text('Segmentation model error'), findsOneWidget);
    expect(find.text('raw exception text'), findsNothing);

    await tester.tap(find.text('Segmentation model error'));
    await tester.pump();

    expect(find.text('raw exception text'), findsOneWidget);
  });

  testWidgets('DiagnosticsOverlay lists per-track health label and size',
      (tester) async {
    final tracker = BoTSortTracker();
    final tracks = tracker.update([
      TrackerDetection(x1: 0, y1: 0, x2: 20, y2: 20, score: 0.9),
    ]);
    final trackId = tracks.single.trackId;

    // Two confident samples: sub-plan 10's minimum before a label shows.
    final aggregator = HealthAggregator()
      ..record(trackId, const ColonyHealth(label: 'CORAL_BL', confidence: 0.8))
      ..record(trackId, const ColonyHealth(label: 'CORAL_BL', confidence: 0.8));

    await tester.pumpWidget(
      _wrapLandscape(
        tester,
        DiagnosticsOverlay(
          segProcessingMs: 12.3,
          tracks: tracks,
          healthAggregator: aggregator,
          sizesPx: {trackId: 456},
        ),
      ),
    );

    expect(find.textContaining('seg: 12.3ms'), findsOneWidget);
    expect(find.textContaining('#$trackId: CORAL_BL (456px²)'), findsOneWidget);
  });

  testWidgets('DiagnosticsOverlay shows the live-loop line only when given',
      (tester) async {
    Widget overlay({String? loopSummary}) => _wrapLandscape(
      tester,
      DiagnosticsOverlay(
        segProcessingMs: 12.3,
        tracks: const [],
        healthAggregator: HealthAggregator(),
        sizesPx: const {},
        loopSummary: loopSummary,
      ),
    );

    await tester.pumpWidget(overlay());
    expect(find.textContaining('upd/s'), findsNothing);

    await tester.pumpWidget(overlay(loopSummary: 'ev/s 8.0  upd/s 8.0'));
    expect(find.text('ev/s 8.0  upd/s 8.0'), findsOneWidget);
  });

  testWidgets(
      'end-transect sheet resolves true only after "End transect" is tapped, '
      'not merely by opening it', (tester) async {
    bool? result;

    await tester.pumpWidget(
      _wrapLandscape(
        tester,
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showEndTransectSheet(context, colonyCount: 3);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('End transect? 3 colonies recorded.'), findsOneWidget);
    // The sheet opening alone must not have decided anything yet -- this is
    // the "tapping End Transect once ... doesn't end the session" guarantee.
    expect(result, isNull);

    await tester.tap(find.text('End transect'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
  });

  testWidgets('end-transect sheet resolves false on "Keep surveying"',
      (tester) async {
    bool? result;

    await tester.pumpWidget(
      _wrapLandscape(
        tester,
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showEndTransectSheet(context, colonyCount: 1);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Keep surveying'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });
}
