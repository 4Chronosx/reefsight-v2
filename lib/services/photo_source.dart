import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import 'photo_import.dart';

/// Issue #5: the real [PhotoSource]. The Photos library through
/// `image_picker` with full metadata (EXIF time and camera are what the
/// import orders by); the Files app through `file_picker`, which hands over
/// the original file byte for byte -- the fallback if the library route
/// ever strips EXIF or converts the format. Both return the plugin's own
/// copy, which `PhotoTransectStore.importCopy` copies again into app
/// storage, so the diver's originals are never touched.
class PluginPhotoSource implements PhotoSource {
  const PluginPhotoSource();

  @override
  Future<List<PickedPhoto>> pickFromLibrary() async {
    final files = await ImagePicker().pickMultiImage(requestFullMetadata: true);
    return [for (final f in files) PickedPhoto(path: f.path, name: f.name)];
  }

  /// `FileType.custom`, not `FileType.image`: on iOS, file_picker opens the
  /// Photos gallery for `image`/`media`/`video` and only goes through
  /// `UIDocumentPicker` (the Files app) for `custom`/`any`.
  static const _extensions = ['jpg', 'jpeg', 'heic', 'heif', 'png'];

  @override
  Future<List<PickedPhoto>> pickFromFiles() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _extensions,
      allowMultiple: true,
    );
    return [
      for (final f in result?.files ?? const <PlatformFile>[])
        if (f.path != null) PickedPhoto(path: f.path!, name: f.name),
    ];
  }
}
