import 'dart:math' as math;
import 'dart:typed_data';

/// A JPEG with the dimensions that are actually on disk.
///
/// Split out of `jpeg_normalizer.dart` for the same reason `jpeg_size.dart`
/// was: this is a pure value type, and the capture controller stores it in
/// SQLite. Keeping it here means the controller — and every test that drives
/// the controller — does not have to link the native OpenCV library just to
/// name the type of a normalised frame.
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

  /// Top-left of the crop rectangle in source pixels — `0, 0` when the frame
  /// needed no crop. The stitcher reconstructs the principal point from these,
  /// so projection stays correct even for a non-centred crop.
  final int cropOffsetX;
  final int cropOffsetY;

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
    this.cropOffsetX = 0,
    this.cropOffsetY = 0,
  }) : sourceWidth = sourceWidth ?? width,
       sourceHeight = sourceHeight ?? height;
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
