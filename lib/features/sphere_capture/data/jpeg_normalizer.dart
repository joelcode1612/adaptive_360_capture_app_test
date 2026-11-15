import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

// The pure size/EXIF parsing lives in its own file so it is testable without
// the native library; it is re-exported for every existing importer.
import 'package:adaptive_360_capture_app/features/sphere_capture/data/jpeg_size.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/normalized_jpeg.dart';
export 'package:adaptive_360_capture_app/features/sphere_capture/data/jpeg_size.dart'
    show exifOrientation, readJpegSize;
// `NormalizedJpeg` and `isFourThree` are pure value/geometry helpers. They live
// in `domain/normalized_jpeg.dart` so the capture controller and its SQLite
// persistence can name the type without importing the native library; every
// existing importer keeps working through this re-export.
export 'package:adaptive_360_capture_app/features/sphere_capture/domain/normalized_jpeg.dart'
    show NormalizedJpeg, isFourThree;

/// Enforces the specification's 4:3 still.
///
/// Most Android devices already return a 4:3 JPEG at `ResolutionPreset.max`,
/// in which case the bytes are passed through untouched. When a device returns
/// 16:9 or another aspect, the frame is centre-cropped — never stretched —
/// because a stretched panorama would break the stitching geometry. If the
/// crop cannot be performed (decoder unavailable, corrupt buffer), the
/// original photograph is kept and [NormalizedJpeg.warning] says so: losing
/// the photograph to satisfy a cosmetic ratio would be the worse trade.
class JpegNormalizer {
  const JpegNormalizer({
    this.targetAspect = 4 / 3,
    this.aspectTolerance = 0.02,
    this.quality = 92,
  });

  final double targetAspect;

  /// How far the measured aspect may be from 4:3 before cropping.
  final double aspectTolerance;

  final int quality;

  Future<NormalizedJpeg> normalize(Uint8List bytes) async {
    final size = readJpegSize(bytes);
    if (size == null) {
      return NormalizedJpeg(
        bytes: bytes,
        width: 0,
        height: 0,
        warning:
            'The JPEG dimensions could not be read, so 4:3 was not '
            'enforced for this photograph.',
      );
    }
    // A portrait-locked rear camera normally reports 3072×4096 (3:4), which
    // is the same 4:3 frame rotated by 90°. Cropping a portrait frame down to
    // a landscape 4:3 would throw away the vertical field the panorama needs.
    if (isFourThree(size.width, size.height, tolerance: aspectTolerance)) {
      return NormalizedJpeg(
        bytes: bytes,
        width: size.width,
        height: size.height,
      );
    }

    // Keep the frame's existing orientation: a portrait 9:16 frame becomes a
    // portrait 3:4 frame, not a landscape one.
    var cropWidth = size.width;
    var cropHeight = size.height;
    if (size.width >= size.height) {
      final wanted = (size.height * targetAspect).round();
      if (wanted <= size.width) {
        cropWidth = wanted;
      } else {
        cropHeight = (size.width / targetAspect).round();
      }
    } else {
      final wanted = (size.width * targetAspect).round();
      if (wanted <= size.height) {
        cropHeight = wanted;
      } else {
        cropWidth = (size.height / targetAspect).round();
      }
    }
    final left = ((size.width - cropWidth) / 2).round();
    final top = ((size.height - cropHeight) / 2).round();

    cv.Mat? mat;
    cv.Mat? cropped;
    cv.Rect? rect;
    try {
      mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      if (mat.isEmpty) {
        return NormalizedJpeg(
          bytes: bytes,
          width: size.width,
          height: size.height,
          warning:
              'The JPEG could not be decoded for cropping; the original '
              '${size.width}×${size.height} frame was kept.',
        );
      }
      rect = cv.Rect(left, top, cropWidth, cropHeight);
      cropped = mat.region(rect);
      final (ok, encoded) = cv.imencode(
        '.jpg',
        cropped,
        params: cv.VecI32.fromList(<int>[cv.IMWRITE_JPEG_QUALITY, quality]),
      );
      if (!ok || encoded.isEmpty) {
        return NormalizedJpeg(
          bytes: bytes,
          width: size.width,
          height: size.height,
          warning:
              'The 4:3 crop could not be encoded; the original '
              '${size.width}×${size.height} frame was kept.',
        );
      }
      return NormalizedJpeg(
        bytes: encoded,
        width: cropWidth,
        height: cropHeight,
        cropped: true,
        sourceWidth: size.width,
        sourceHeight: size.height,
        cropOffsetX: left,
        cropOffsetY: top,
      );
    } catch (error) {
      return NormalizedJpeg(
        bytes: bytes,
        width: size.width,
        height: size.height,
        warning:
            'The 4:3 crop failed ($error); the original '
            '${size.width}×${size.height} frame was kept.',
      );
    } finally {
      cropped?.dispose();
      rect?.dispose();
      mat?.dispose();
    }
  }
}
