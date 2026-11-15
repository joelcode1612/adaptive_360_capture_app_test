// Camera-intrinsics transformation for the 38-target sphere flow.
//
// Pure Dart — no Flutter, no OpenCV — so the focal-length bookkeeping is
// executable and testable on the plain VM (`tool/verify_sphere_projection.dart`).
//
// ## The coordinate systems
//
// A photograph passes through three coordinate systems before the stitcher
// samples it:
//
// 1. **Source** — the uncropped, as-displayed (EXIF-applied) frame the camera
//    produced, e.g. 3072 × 4096 portrait. `sourceImageWidth/Height` in the
//    capture record.
// 2. **Saved** — the file on disk: the source frame after the normalizer's
//    centred 3:4 crop, when one was needed, otherwise identical to the source.
//    `imageWidth/Height` in the capture record, plus the crop offsets.
// 3. **Decoded** — what the stitcher's `cv.imread` actually returns. The
//    stitcher decodes reduced (`IMREAD_REDUCED_COLOR_4/2`) to bound memory, so
//    the decoded image is the saved image scaled by ½ or ¼.
//
// A pinhole focal length is a property of the **lens**, in the coordinate
// system of the image it is expressed in. Cropping moves the principal point
// and changes the field of view, but never the focal length in pixels.
// Rescaling by a factor s multiplies the focal length by s. Getting this
// wrong was the defect this file fixes: the stitcher divided the *source*
// height by 2·tan(vfov/2) and then sampled a *quarter-scale* decoded image
// with that focal, overstating it 4× — every frame's angular footprint
// collapsed to about a quarter of its true size and the coverage audit
// reported holes across most of the sphere.
library;

import 'dart:math' as math;

/// The focal length in pixels for an image of [imageHeight] pixels tall that
/// spans [verticalFovDeg] degrees vertically: `f = (H/2) / tan(vfov/2)`.
double focalFromHeight(double imageHeight, double verticalFovDeg) {
  if (imageHeight <= 0) {
    throw ArgumentError.value(imageHeight, 'imageHeight', 'must be positive');
  }
  return (imageHeight / 2) / math.tan(verticalFovDeg * math.pi / 360);
}

/// Horizontal field of view in degrees for [widthPx] pixels at [focalPx].
///
/// Never hard-coded: it is always derived from the image dimensions and the
/// same focal length the projection uses, so a 3:4 portrait frame and its
/// quarter-scale decode always agree.
double horizontalFovFromPixels(double widthPx, double focalPx) {
  if (focalPx <= 0) {
    throw ArgumentError.value(focalPx, 'focalPx', 'must be positive');
  }
  return 2 * math.atan(widthPx / 2 / focalPx) * 180 / math.pi;
}

/// Vertical field of view in degrees for [heightPx] pixels at [focalPx].
double verticalFovFromPixels(double heightPx, double focalPx) {
  if (focalPx <= 0) {
    throw ArgumentError.value(focalPx, 'focalPx', 'must be positive');
  }
  return 2 * math.atan(heightPx / 2 / focalPx) * 180 / math.pi;
}

/// The projection parameters for one decoded frame, ready for the stitcher.
class DecodedProjection {
  /// Focal length in pixels **in the decoded image's coordinate system**.
  final double focalPx;

  /// Principal point in decoded pixels. For a centred crop this is the
  /// decoded image's centre; the general form tracks the recorded crop
  /// offsets so an off-centre crop would still project correctly.
  final double cx;
  final double cy;

  /// Decoded-image width and height the parameters were derived for.
  final int width;
  final int height;

  /// Effective field of view of the decoded image, in degrees — derived from
  /// the focal length and dimensions, never assumed independently.
  final double horizontalFovDeg;
  final double verticalFovDegDeg;

  /// decodedHeight ÷ savedHeight — the reduced-decode scale (1 for a full
  /// decode). Exposed so tests can assert the scaling explicitly.
  final double decodeScale;

  const DecodedProjection({
    required this.focalPx,
    required this.cx,
    required this.cy,
    required this.width,
    required this.height,
    required this.horizontalFovDeg,
    required this.verticalFovDegDeg,
    required this.decodeScale,
  });
}

/// Transforms the assumed lens through source → crop → decode into the
/// decoded coordinate system.
///
/// * The **focal length** is computed once on the *source* frame — the lens
///   property — then multiplied by `decodedHeight / savedHeight`, the only
///   transform that scales pixels. A centred 3:4 crop therefore changes
///   nothing; a reduced decode divides by 2 or 4; both happen correctly even
///   when combined.
/// * The **principal point** is the source frame's centre, shifted by the
///   recorded crop offsets and scaled — for the normalizer's centred crops
///   this lands exactly on the decoded centre, which is the sanity check
///   Test C asserts.
/// * Invalid or missing metadata degrades safely: non-positive dimensions
///   fall back to the next available value and a nonsensical input returns
///   `null` rather than dividing by zero.
///
/// [savedWidth]/[savedHeight] are the on-disk JPEG's dimensions
/// (`imageWidth/Height` in the record); [sourceWidth]/[sourceHeight] the
/// uncropped frame (`sourceImageWidth/Height`); [cropOffsetX]/[cropOffsetY]
/// the top-left of the crop in source pixels (0 when uncropped).
DecodedProjection? decodedProjection({
  required int decodedWidth,
  required int decodedHeight,
  required int savedWidth,
  required int savedHeight,
  required int sourceWidth,
  required int sourceHeight,
  required double verticalFovDeg,
  int cropOffsetX = 0,
  int cropOffsetY = 0,
}) {
  if (decodedWidth <= 0 || decodedHeight <= 0) return null;
  if (verticalFovDeg <= 0 || verticalFovDeg >= 180) return null;

  // Degrade in stages: source → saved → decoded. Every real record has all
  // three, but a record written before a field existed must still stitch.
  final effSourceH = sourceHeight > 0
      ? sourceHeight
      : (savedHeight > 0 ? savedHeight : decodedHeight);
  final effSourceW = sourceWidth > 0
      ? sourceWidth
      : (savedWidth > 0 ? savedWidth : decodedWidth);
  final effSavedH = savedHeight > 0 ? savedHeight : decodedHeight;

  // The lens focal, expressed in full-resolution source pixels.
  final focalSource = focalFromHeight(
    effSourceH.toDouble(),
    verticalFovDeg,
  );
  // Reduced decoding is a pure resize of the saved image.
  final scale = decodedHeight / effSavedH;
  final focal = focalSource * scale;

  final cx = (effSourceW / 2 - cropOffsetX) * scale;
  final cy = (effSourceH / 2 - cropOffsetY) * scale;

  return DecodedProjection(
    focalPx: focal,
    cx: cx,
    cy: cy,
    width: decodedWidth,
    height: decodedHeight,
    horizontalFovDeg: horizontalFovFromPixels(
      decodedWidth.toDouble(),
      focal,
    ),
    verticalFovDegDeg: verticalFovFromPixels(decodedHeight.toDouble(), focal),
    decodeScale: scale,
  );
}
