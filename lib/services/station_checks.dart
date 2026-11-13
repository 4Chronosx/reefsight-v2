import 'station.dart';
import 'transect_session.dart';

/// Issue #2: the TB 2019-04 checks and display rules the station screens
/// show. Flags are warnings, never blocks: a deep or non-standard transect
/// is still data, just reported as such (`docs/reefsight-v2-blueprint.md`
/// §6). The station summary (#8) reuses them.

/// "The deepest is no more than 6 m below mean sea level" (TB 2019-04).
const kMaxDepthM = 6.0;

/// TB 2019-04's transects are 50 m.
const kStandardTapeM = 50.0;

/// 3-5 transects per station; five recommended for monitoring.
const kMinTransects = 3;
const kMaxTransects = 5;

const kFlagStationTooDeep = 'Station deeper than 6 m (TB 2019-04 maximum)';
const kFlagFewTransects = 'Fewer than 3 transects (TB 2019-04 minimum)';
const kFlagTransectTooDeep = 'Deeper than 6 m';

bool depthOverLimit(double? depthM) => depthM != null && depthM > kMaxDepthM;

bool tapeNotStandard(double tapeM) => (tapeM - kStandardTapeM).abs() > 1e-9;

String _meters(double m) => m == m.roundToDouble() ? m.toStringAsFixed(0) : m.toString();

List<String> stationFlags(Station station, int transectCount) => [
      if (depthOverLimit(station.depthMaxM)) kFlagStationTooDeep,
      if (transectCount < kMinTransects) kFlagFewTransects,
    ];

List<String> transectFlags(TransectSession transect) => [
      if (depthOverLimit(transect.depthStartM) || depthOverLimit(transect.depthEndM))
        kFlagTransectTooDeep,
      if (tapeNotStandard(transect.tapeLengthMeters))
        'Tape is ${_meters(transect.tapeLengthMeters)} m, not 50 m',
    ];

/// The number Setup preselects: [next] (`TransectDatabase.nextTransectNumber`,
/// which never reuses a deleted number) while it's free and within T1-T5,
/// else the lowest free number, else `null` -- the station is full.
int? defaultTransectNumber(Set<int> used, int next) {
  if (next <= kMaxTransects && !used.contains(next)) return next;
  for (var n = 1; n <= kMaxTransects; n++) {
    if (!used.contains(n)) return n;
  }
  return null;
}

/// One status line per transect on the station screen. Colony count is the
/// existing Live flow; photo and preliminary transects are created at setup
/// and wait for their capture flows (#4, #13), then for analysis.
String transectStatus(TransectSession transect, SurveyType type) {
  if (type == SurveyType.colonyCount) {
    return transect.endedAt == null ? 'In progress' : 'Complete';
  }
  return switch (transect.analysisStatus) {
    AnalysisStatus.pending => 'Analysis pending',
    AnalysisStatus.running => 'Analysis running',
    AnalysisStatus.done => 'Analysis done',
    AnalysisStatus.failed => 'Analysis failed',
    null => transect.endedAt == null ? 'Awaiting capture' : 'Captured',
  };
}

String surveyTypeLabel(SurveyType type) => switch (type) {
      SurveyType.photoTransect => 'Photo transect',
      SurveyType.preliminaryVideo => 'Preliminary (video)',
      SurveyType.colonyCount => 'Colony count (research)',
    };

String surveyTypeHint(SurveyType type) => switch (type) {
      SurveyType.photoTransect => 'Official: one still per meter, scored with 10 random points.',
      SurveyType.preliminaryVideo => 'Live video, reported as PRELIMINARY.',
      SurveyType.colonyCount =>
        'Colony tracking and bleaching, reported separately from the bulletins.',
    };

String frameModeLabel(FrameMode mode) => switch (mode) {
      FrameMode.physical => 'Physical frame',
      FrameMode.virtual => 'Virtual frame',
      FrameMode.importedMixed => 'Imported photos',
    };

String reefZoneLabel(ReefZone zone) => switch (zone) {
      ReefZone.reefFlat => 'Reef flat',
      ReefZone.reefCrest => 'Reef crest',
      ReefZone.upperSlope => 'Upper slope',
      ReefZone.lowerSlope => 'Lower slope',
    };
