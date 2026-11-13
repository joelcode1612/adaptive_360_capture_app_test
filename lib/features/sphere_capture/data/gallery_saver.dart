import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Puts the finished panorama where the phone's Gallery can see it.
///
/// The app's own copies live in app-private storage and in
/// `Android/data/.../SiteWise360/`; neither shows up in Photos, and the second
/// is deleted with the app. The Kotlin host inserts the JPEG into MediaStore
/// under `Pictures/SiteWise360/<stationId>/panorama.jpg`, which is a normal,
/// user-visible picture.
class GallerySaver {
  const GallerySaver();

  static const MethodChannel _channel = MethodChannel('adaptive360/media');

  /// Returns the MediaStore content URI (Android 10+) or the file path
  /// (older releases), or `null` when the save failed.
  ///
  /// Failure is deliberately not an exception: the panorama is still valid on
  /// disk, and a Gallery insert must not turn a successful stitch into a
  /// reported failure.
  Future<String?> savePanorama({
    required String sourcePath,
    required String stationId,
  }) async {
    try {
      final saved = await _channel.invokeMethod<String>('saveImage', {
        'sourcePath': sourcePath,
        'folder': 'SiteWise360/$stationId',
        'fileName': 'panorama.jpg',
      });
      if (saved != null) {
        debugPrint('GALLERY_SAVE: panorama saved at $saved');
      }
      return saved;
    } on PlatformException catch (error) {
      debugPrint('GALLERY_SAVE: failed ${error.code}: ${error.message}');
      return null;
    } on MissingPluginException {
      debugPrint('GALLERY_SAVE: no MediaStore channel on this platform');
      return null;
    }
  }
}
