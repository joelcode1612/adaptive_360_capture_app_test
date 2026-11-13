import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// The 3DoF rotation mathematics behind the sphere-follows-phone architecture.
///
/// ## The one equation
///
/// A target direction is frozen in the **start device frame** `S`. The device
/// quaternion `q` maps the current device frame to the world, and `q₀` is its
/// value at Start, so:
///
/// ```
/// v_camera = q⁻¹ · (q₀ · v_S)
/// ```
///
/// `q₀ · v_S` is the target's world direction (fixed, which is what keeps a
/// target pointing at the same part of the room as the user turns), and `q⁻¹`
/// brings it back into the current device frame for projection. This is the
/// specification's "apply the inverse quaternion", written so the frozen world
/// direction is explicit rather than implied.
///
/// **No translation term exists anywhere in this file**, by design. Walking
/// changes neither `q` nor `q₀`, so the sphere follows the phone exactly and
/// cannot drift: there is no position estimate to accumulate error.

/// Rotates one frozen start-frame direction into the current camera frame.
Vec3 sphereTargetCameraDirection({
  required Quat deviceToWorld,
  required Quat startDeviceToWorld,
  required Vec3 startDirection,
}) {
  final world = startDeviceToWorld.rotate(startDirection);
  return deviceToWorld.conjugate.rotate(world).normalized;
}

/// The angle between two directions, in degrees, stable at 0° and 180°.
double angleBetweenDeg(Vec3 a, Vec3 b) {
  final x = a.normalized;
  final y = b.normalized;
  final cross = x.cross(y).length;
  final dot = clampDouble(x.dot(y), -1, 1);
  return math.atan2(cross, dot) * radToDeg;
}

/// How far a camera-frame direction is from the fixed centre reticle.
///
/// The reticle looks along the device's `−Z`, so the error is the angle to
/// `(0, 0, −1)`: `atan2(√(x²+y²), −z)`. This is a 3-D angle, independent of
/// the field of view and of where the marker happens to be drawn — the
/// auto-capture gate must never depend on a cosmetic projection.
double reticleErrorDeg(Vec3 cameraDirection) {
  final v = cameraDirection.normalized;
  final horizontal = math.sqrt(v.x * v.x + v.y * v.y);
  return math.atan2(horizontal, -v.z) * radToDeg;
}

/// How much of the previous frame a new capture is expected to share.
///
/// Two frames of horizontal field [horizontalFovDeg] whose centres are
/// [separationDeg] apart overlap by `fov − separation` degrees, i.e. the
/// fraction returned here. It is an estimate for guidance, not a stitching
/// guarantee — but with rotation-only capture it is the dominant term, and a
/// value near zero is exactly the "no duplicate content" case a stitcher
/// cannot recover from.
double estimatedOverlapFraction(
  double separationDeg, {
  double horizontalFovDeg = 50,
}) {
  if (horizontalFovDeg <= 0) return 0;
  return (1 - separationDeg / horizontalFovDeg).clamp(0.0, 1.0);
}

/// The pinhole projection of camera-frame directions onto the viewport.
///
/// The camera looks along `−Z`, `+X` is screen-right and `+Y` screen-up, so
/// `u = W/2 + (x / −z)·fx` and `v = H/2 − (y / −z)·fy`. `fx`/`fy` come from a
/// nominal **vertical** field of view and the viewport aspect ratio.
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
  /// 65° is a typical rear-camera vertical FOV in portrait. See the class doc
  /// for why an estimate is sufficient.
  final double verticalFovDeg;

  const SphereProjection({
    required this.width,
    required this.height,
    this.verticalFovDeg = 65,
  });

  double get _tanHalfVertical => math.tan(verticalFovDeg * degToRad / 2);

  double get _tanHalfHorizontal => _tanHalfVertical * (width / height);

  /// Focal length in pixels along the screen's vertical axis.
  double get focalLengthY => (height / 2) / _tanHalfVertical;

  /// The on-screen radius of the alignment cone around the reticle.
  double get toleranceRadiusPx =>
      focalLengthY * math.tan(kSphereAlignmentToleranceDeg * degToRad);

  /// Projects a camera-frame direction, or `null` when it is not in front.
  Offset? project(Vec3 cameraDirection) {
    final v = cameraDirection.normalized;
    final depth = -v.z;
    // At or behind the image plane there is no finite projection. The small
    // epsilon keeps a target exactly at 90° from producing a huge coordinate
    // that a painter would then draw at the edge as if it were in view.
    if (depth <= 1e-4 || width <= 0 || height <= 0) return null;
    final x = (v.x / depth) / _tanHalfHorizontal;
    final y = (v.y / depth) / _tanHalfVertical;
    return Offset(width / 2 + x * (width / 2), height / 2 - y * (height / 2));
  }

  /// Whether a projected point is inside the viewport, with an optional
  /// [margin] in pixels so a marker half-off the edge is still drawn.
  bool isOnScreen(Offset point, {double margin = 0}) =>
      point.dx >= -margin &&
      point.dx <= width + margin &&
      point.dy >= -margin &&
      point.dy <= height + margin;
}
