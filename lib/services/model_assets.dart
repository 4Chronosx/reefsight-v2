/// Bundled model asset paths.
///
/// iOS Flutter assets must be `.mlpackage.zip` (the plugin unpacks it into
/// app storage before loading) — see `ultralytics_yolo`'s Model Integration
/// Guide, "Bundled Flutter asset on iOS". Placed here by
/// `machine-learning-pipeline/notebooks/23_coreml_export.ipynb`; not present
/// until that notebook has been run (see `mobile/sub-plans/01-scaffold-and-models.md`).
class ModelAssets {
  const ModelAssets._();

  /// Stage B colony segmentation. The filename deliberately carries no run
  /// name: notebook 23's `STAGE_B_SOURCE` picks which trained arm is exported
  /// here (`coralscapes_v3` since 2026-10-02, `coralvos_primary` before), so
  /// swapping models never needs a Dart change.
  static const String stageBSegmentation =
      'assets/models/stage_b_seg.mlpackage.zip';

  static const String nmfsOsiBleachingClassifier =
      'assets/models/nmfs_osi_bleaching.mlpackage.zip';
}
