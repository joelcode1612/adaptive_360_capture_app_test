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

  /// The frame's dimensions **before** any 4:3 crop.
  ///
  /// The stitcher derives its focal length from these, because a centred crop
  /// does not change the focal length in pixels — only the field of view and
  /// the principal point. Using the cropped height instead would silently
  /// narrow the assumed lens on any device that returns a non-4:3 still.
  final int sourceWidth;
  final int sourceHeight;

  /// A sentence for the diagnostics line when the 4:3 requirement could not be
  /// met, or `null` when it was.
  final String? warning;

  const NormalizedJpeg({
    required this.bytes,
    required this.width,
    required this.height,
    this.cropped = false,
    this.warning,
    int? sourceWidth,
    int? sourceHeight,
  }) : sourceWidth = sourceWidth ?? width,
       sourceHeight = sourceHeight ?? height;
}

/// Reads the pixel dimensions out of a JPEG's SOF marker.
///
/// Deliberately not a decode: the shutter fires 38 times per station, and
/// decoding a 12 MP image just to learn its size would add hundreds of
/// milliseconds per photograph. Returns `null` for anything that is not a
/// baseline/progressive JPEG with a readable frame header.
///
/// ## EXIF orientation
///
/// The dimensions returned are **as displayed**, not as stored. Android's
/// camera writes the JPEG in sensor orientation (landscape) and records a
/// rotation in EXIF; OpenCV's `imread` applies that rotation, so the stitcher
/// sees a portrait image while the SOF marker still says landscape. Returning
/// the raw SOF size therefore described a 3024 × 4032 photograph as
/// 4032 × 3024, and the stitcher — which derives its focal length from the
/// recorded height — used the *width* as the vertical field of view and
/// under-estimated the lens by 25%. Every frame was then projected too small
/// and the coverage audit reported holes that were not really there.
///
/// Reading the orientation tag is what makes the recorded size agree with the
/// decoded image, so `sourceImageHeight` means what the stitcher assumes it
/// means.
({int width, int height})? readJpegSize(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  final orientation = _exifOrientation(bytes);
  final swapAxes =
      orientation != null && orientation >= 5 && orientation <= 8;
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
      return swapAxes ? (width: height, height: width) : (width: width, height: height);
    }
    i += 2 + length;
  }
  return null;
}

/// The EXIF orientation tag (0x0112) of [bytes], or `null` when absent.
///
/// Only the first APP1 segment is inspected: the orientation tag lives in IFD0
/// of the primary image, and a thumbnail's IFD1 — which could carry a different
/// value — is never reached because the search stops at the first match.
int? _exifOrientation(Uint8List bytes) {
  var i = 2;
  while (i + 4 <= bytes.length) {
    if (bytes[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = bytes[i + 1];
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
    // Entropy-coded data starts here; no more metadata can follow.
    if (marker == 0xDA) return null;
    if (marker == 0xE1) {
      final start = i + 4;
      final end = i + 2 + length;
      if (end > bytes.length) return null;
      if (end - start >= 6 &&
          bytes[start] == 0x45 &&
          bytes[start + 1] == 0x78 &&
          bytes[start + 2] == 0x69 &&
          bytes[start + 3] == 0x66) {
        return _tiffOrientation(bytes, start + 6, end);
      }
    }
    i += 2 + length;
  }
  return null;
}

/// Reads tag 0x0112 out of a TIFF header embedded at [base].
int? _tiffOrientation(Uint8List b, int base, int end) {
  if (base + 8 > end) return null;
  final littleEndian = b[base] == 0x49 && b[base + 1] == 0x49;
  int u16(int o) => littleEndian
      ? (b[o] | (b[o + 1] << 8))
      : ((b[o] << 8) | b[o + 1]);
  int u32(int o) => littleEndian
      ? (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24))
      : ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]);
  if (u16(base + 2) != 42) return null;
  final ifd = base + u32(base + 4);
  if (ifd + 2 > end) return null;
  final count = u16(ifd);
  for (var k = 0; k < count; k++) {
    final entry = ifd + 2 + k * 12;
    if (entry + 12 > end) return null;
    if (u16(entry) != 0x0112) continue;
    // Type 3 is SHORT, which is the only type the tag is defined with.
    if (u16(entry + 2) != 3) return null;
    final value = u16(entry + 8);
    return value >= 1 && value <= 8 ? value : null;
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
        sourceWidth: size.width,
        sourceHeight: size.height,
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
