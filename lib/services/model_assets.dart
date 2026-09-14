/// Bundled model asset paths.
///
/// iOS Flutter assets must be `.mlpackage.zip` (the plugin unpacks it into
/// app storage before loading) — see `ultralytics_yolo`'s Model Integration
/// Guide, "Bundled Flutter asset on iOS". Placed here by
/// `machine-learning-pipeline/notebooks/23_coreml_export.ipynb`; not present
/// until that notebook has been run (see `mobile/sub-plans/01-scaffold-and-models.md`).
class ModelAssets {
  const ModelAssets._();

  static const String coralvosPrimarySegmentation =
      'assets/models/coralvos_primary.mlpackage.zip';

  static const String nmfsOsiBleachingClassifier =
      'assets/models/nmfs_osi_bleaching.mlpackage.zip';
}
