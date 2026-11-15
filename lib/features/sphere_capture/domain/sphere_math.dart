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
/// **`q₀` is the *levelled* start pose, not the raw first sample.** The layout
/// defines the middle ring as the horizon, which is only true in a frame whose
/// up axis is the world's; `levelStartFrame` in `sphere_target.dart` keeps the start heading and drops
/// the pitch and roll the phone happened to have when Start was pressed. The
/// raw sample would tilt the whole sphere by that angle — every marker offset
/// by the same amount, which reads as "the targets are not stuck on the room".
///
/// **No translation term exists anywhere in this file**, by design. Walking
/// changes neither `q` nor `q₀`, so the sphere follows the phone exactly and
/// cannot drift: there is no position estimate to accumulate error.
///
/// This file is pure Dart — no `dart:ui`, no Flutter — so the whole rotation
/// chain can be executed and checked without a device or an engine. The
/// viewport pinhole model lives in `sphere_projection.dart`, which re-exports
/// everything here.
library;

import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

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
