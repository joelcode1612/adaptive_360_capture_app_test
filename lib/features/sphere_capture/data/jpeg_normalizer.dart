import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

/// A JPEG with the dimensions that are actually on disk.
class NormalizedJpeg {
  final Uint8List bytes;

  /// Measured from the JPEG's own SOF marker, not assumed from the preset.
  final int width;
  final int height;

  /// Whether a crop was applied to reach 4:3.
  final bool cropped;

  /// A sentence for the diagnostics line when the 4:3 requirement could not be
  /// met, or `null` when it was.
  final String? warning;

  const NormalizedJpeg({
    required this.bytes,
    required this.width,
    required this.height,
    this.cropped = false,
    this.warning,
  });
}

/// Reads the pixel dimensions out of a JPEG's SOF marker.
///
/// Deliberately not a decode: the shutter fires 38 times per station, and
/// decoding a 12 MP image just to learn its size would add hundreds of
/// milliseconds per photograph. Returns `null` for anything that is not a
/// baseline/progressive JPEG with a readable frame header.
({int width, int height})? readJpegSize(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  var i = 2;
  while (i + 9 < bytes.length) {
    if (bytes[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = bytes[i + 1];
    // Standalone markers carry no length field.
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7) ||
        marker == 0xFF) {
      i += 2;
      continue;
    }
    if (i + 3 >= bytes.length) return null;
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (length < 2) return null;
    final isStartOfFrame =
        (marker >= 0xC0 && marker <= 0xC3) ||
        (marker >= 0xC5 && marker <= 0xC7) ||
        (marker >= 0xC9 && marker <= 0xCB) ||
        (marker >= 0xCD && marker <= 0xCF);
    if (isStartOfFrame) {
      if (i + 8 >= bytes.length) return null;
      final height = (bytes[i + 5] << 8) | bytes[i + 6];
      final width = (bytes[i + 7] << 8) | bytes[i + 8];
      if (width <= 0 || height <= 0) return null;
      return (width: width, height: height);
    }
    i += 2 + length;
  }
  return null;
}

/// Whether [width] × [height] is 4:3 in either orientation.
///
/// Pure so it can be tested without loading the native OpenCV library: a
/// portrait-locked rear camera reports 3072×4096, which is a 4:3 frame turned
/// 90°, not a frame that needs cropping.
bool isFourThree(int width, int height, {double tolerance = 0.02}) {
  if (width <= 0 || height <= 0) return false;
  final longSide = math.max(width, height);
  final shortSide = math.min(width, height);
  return (longSide / shortSide - 4 / 3).abs() <= tolerance;
}

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
