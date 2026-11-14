import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reefsight_mobile/screens/station_detail_screen.dart';
import 'package:reefsight_mobile/services/share_package.dart';
import 'package:reefsight_mobile/services/station.dart';
import 'package:reefsight_mobile/services/transect_database.dart';
import 'package:reefsight_mobile/services/transect_session.dart';

// Issue #9: Share / Save on the station screen -- the whole station from the
// app bar, one transect from its row, and the picker in between. The runner
// that writes the zip and opens the share sheet is injected (no share sheet
// under `flutter test`); the zip itself is share_package_db_test.dart's.

void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  late TransectDatabase db;
  late Directory documents;
  late int stationId;
  late int t1;
  late int t2;
  late List<ShareOptions> shared;

  setUp(() async {
    db = await TransectDatabase.openInMemoryForTest(ignoreClose: true);
    documents = await Directory.systemTemp.createTemp('share_sheet_');
    stationId = await db.insertStation(Station(
      code: 'ALG-S1',
      surveyType: SurveyType.photoTransect,
      frameMode: FrameMode.physical,
      surveyedOn: DateTime(2026, 11, 15),
      createdAt: DateTime.utc(2026, 11, 14),
    ));
    TransectSession transect(int n) => TransectSession(
          startedAt: DateTime.utc(2026, 11, 15, n),
          tapeLengthMeters: 50,
          stationId: stationId,
          transectNumber: n,
        );
    t1 = await db.insertSession(transect(1));
    t2 = await db.insertSession(transect(2));
    shared = [];
  });
  tearDown(() async {
    await db.closeForTest();
    await documents.delete(recursive: true);
  });

  Future<void> pumpStation(WidgetTester tester, {SharePackageRunnerForTest? run}) async {
    _useTallSurface(tester);
    await tester.pumpWidget(MaterialApp(
      home: StationDetailScreen(
        stationId: stationId,
        openDatabase: () async => db,
        documentsPath: () async => documents.path,
        sharePackage: run ?? (source, options, origin) async => shared.add(options),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// The source loads with real file I/O, outside the fake clock.
  Future<void> openSheet(WidgetTester tester, Finder button) async {
    await tester.tap(button);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
  }

  String zipName(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('share-zip-name'))).data!;

  testWidgets('the app bar shares the whole station, or the transects left ticked', (tester) async {
    await pumpStation(tester);
    await openSheet(tester, find.byTooltip('Share / Save'));

    expect(zipName(tester), 'ALG-S1_2026-11-15.zip');
    expect(tester.widget<CheckboxListTile>(find.byKey(Key('share-transect-$t1'))).value, isTrue);
    expect(tester.widget<CheckboxListTile>(find.byKey(Key('share-transect-$t2'))).value, isTrue);
    expect(find.text('Video'), findsNothing);

    await tester.tap(find.byKey(Key('share-transect-$t2')));
    await tester.pump();
    expect(zipName(tester), 'ALG-S1_2026-11-15_T1.zip');

    await tester.tap(find.byKey(const Key('share-go')));
    await tester.pumpAndSettle();
    expect(shared.single.sessionIds, {t1});
    expect(shared.single.video, isFalse);
  });

  testWidgets("a transect row's share starts with that transect alone", (tester) async {
    await pumpStation(tester);
    await openSheet(tester, find.byKey(const Key('share-T2')));
    expect(zipName(tester), 'ALG-S1_2026-11-15_T2.zip');
    await tester.tap(find.byKey(const Key('share-go')));
    await tester.pumpAndSettle();
    expect(shared.single.sessionIds, {t2});
  });

  testWidgets('nothing ticked cannot be shared', (tester) async {
    await pumpStation(tester);
    await openSheet(tester, find.byTooltip('Share / Save'));
    await tester.tap(find.byKey(Key('share-transect-$t1')));
    await tester.tap(find.byKey(Key('share-transect-$t2')));
    await tester.pump();
    expect(zipName(tester), 'Choose at least one transect.');
    expect(tester.widget<FilledButton>(find.byKey(const Key('share-go'))).onPressed, isNull);
  });

  testWidgets('a failed share says why', (tester) async {
    await pumpStation(tester, run: (_, _, _) async => throw StateError('Not enough free space'));
    await openSheet(tester, find.byTooltip('Share / Save'));
    await tester.tap(find.byKey(const Key('share-go')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Share failed: Not enough free space'), findsOneWidget);
  });
}

typedef SharePackageRunnerForTest = Future<void> Function(ShareSource, ShareOptions, Rect?);
