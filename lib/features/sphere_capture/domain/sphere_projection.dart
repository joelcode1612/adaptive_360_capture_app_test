import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_math.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// The rotation maths lives in `sphere_math.dart` and is re-exported here, so
/// every existing importer keeps one entry point while the pure part stays
/// runnable without an engine. Only [SphereProjection] needs `dart:ui`.
export 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_math.dart';

/// The pinhole projection of camera-frame directions onto the viewport.
///
/// The camera looks along `−Z`, `+X` is screen-right and `+Y` screen-up, so
/// `u = W/2 + (x / −z)·fx` and `v = H/2 − (y / −z)·fy`. `fx`/`fy` come from a
/// nominal **vertical** field of view and the viewport aspect ratio.
///
/// ## Why the viewport aspect is the right one, even though the preview is
/// cropped
///
/// `CameraPreview` is laid out at the sensor's portrait aspect and scaled with
/// `BoxFit.cover`. A phone viewport is much taller than 4:3, so the scale is
/// driven by the height and the preview is **cropped horizontally** — the
/// vertical field of view fills the screen exactly. That is precisely the
/// assumption below: `tan(h/2) = tan(v/2)·(W/H)`. If a device ever had a
/// viewport wider than the preview the horizontal would fill instead and this
/// would need the preview's aspect; the app is portrait-locked, so it cannot.
///
/// The field of view is nominal because the `camera` plugin does not report
/// intrinsics. That is acceptable here and only here: alignment is decided by
/// [reticleErrorDeg], which is exact, and the projection only decides where a
/// marker is drawn. A wrong FOV moves peripheral markers slightly; it cannot
/// move the reticle or change when the shutter fires.
class SphereProjection {
  final double width;
  final double height;

  /// Vertical field of view of the displayed preview, in degrees.
  ///
  /// Defaults to [kSphereAssumedVerticalFovDeg], declared with the layout so
  /// the isolate that stitches can read it without importing `dart:ui`.
  final double verticalFovDeg;

  const SphereProjection({
    required this.width,
    required this.height,
    this.verticalFovDeg = kSphereAssumedVerticalFovDeg,
  });

  double get _tanHalfVertical => math.tan(verticalFovDeg * degToRad / 2);

  /// Focal length in pixels along the screen's vertical axis.
  double get focalLengthY => (height / 2) / _tanHalfVertical;

  /// The on-screen radius of the alignment cone around the reticle.
  double get toleranceRadiusPx =>
      focalLengthY * math.tan(kSphereAlignmentToleranceDeg * degToRad);

  /// Projects a camera-frame direction, or `null` when it is not in front.
  ///
  /// Delegates to the pure [projectToViewport] so the drawn marker and the
  /// tested maths cannot diverge.
  Offset? project(Vec3 cameraDirection) {
    final p = projectToViewport(
      cameraDirection,
      width: width,
      height: height,
      verticalFovDeg: verticalFovDeg,
    );
    return p == null ? null : Offset(p.x, p.y);
  }

  /// Whether a projected point is inside the viewport, with an optional
  /// [margin] in pixels so a marker half-off the edge is still drawn.
  bool isOnScreen(Offset point, {double margin = 0}) =>
      point.dx >= -margin &&
      point.dx <= width + margin &&
      point.dy >= -margin &&
      point.dy <= height + margin;
}
