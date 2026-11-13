import 'photo_import_order.dart';
import 'photo_metadata.dart';

/// Issue #5: the checks on an imported photo transect (alignment doc §9).
/// They flag; they don't block -- the diver decides, and the flags are saved
/// with each frame so the export shows them.

/// TB 2017-05's minimum camera resolution: 5 MP. Shared with the in-app
/// capture review (#4).
const kMinPixels = 5000000;

bool isUnder5Mp(PhotoMetadata m) {
  final px = m.pixelCount;
  return px != null && px < kMinPixels;
}

/// The header couldn't be read, so the 5 MP check couldn't run.
bool isSizeUnknown(PhotoMetadata m) => m.pixelCount == null;

/// One photo per meter from the 0 m mark, the same meters as in-app capture
/// (#4): 51 on a 50 m tape.
int expectedFrameCount(double tapeLengthMeters) => tapeLengthMeters.floor() + 1;

/// How far the photo count may stray from [expectedFrameCount] before the
/// import screen asks the diver to check for a missed or doubled set.
/// Three either way covers a skipped meter or two and the odd test shot.
const kFrameCountTolerance = 3;

bool frameCountFarOff(int photos, double tapeLengthMeters) =>
    (photos - expectedFrameCount(tapeLengthMeters)).abs() > kFrameCountTolerance;

/// The action-camera lens mode the diver reports at import. GoPros don't
/// record it in standard EXIF, so it's asked once per import.
enum LensMode { linear, wide, superView, unknown }

bool isActionCamera(PhotoMetadata m) => m.make?.toLowerCase().contains('gopro') ?? false;

/// 35 mm-equivalent focal lengths at or below this are fisheye territory.
/// Kept below a phone's ultra-wide (13 mm on an iPhone, which corrects its
/// own distortion) so a phone photo is never flagged by this alone.
const kFisheyeFocal35mm = 12;

/// A fisheye image is suspected: a GoPro unless the diver says it was shot
/// in Linear (Wide and SuperView are fisheye-like, and Coralscapes was
/// filmed Linear), or any camera with a very short focal length.
bool suspectFisheye(PhotoMetadata m, {LensMode? lensMode}) {
  if (isActionCamera(m)) return lensMode != LensMode.linear;
  final f = m.focalLength35mm;
  return f != null && f > 0 && f <= kFisheyeFocal35mm;
}

/// Distinct make + model pairs among photos that report a camera. More than
/// one usually means two people's photos were picked together.
int cameraCount(List<ImportedPhoto> photos) => {
      for (final p in photos)
        if (p.metadata.make != null || p.metadata.model != null) '${p.metadata.make}|${p.metadata.model}',
    }.length;
