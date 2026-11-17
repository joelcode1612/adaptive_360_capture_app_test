// Verifies that the attitude filter establishes the horizon on its first usable
// accelerometer sample instead of easing toward it.
//
//   dart --packages=.dart_tool/sphere_verify_package_config.json \
//        tool/verify_attitude_startup.dart
//
// The filter is pure maths, so this runs on the plain VM. The contract being
// checked is the one the capture screen depends on: after **one** gravity
// sample, the estimate must agree with gravity, whatever tilt the phone was
// held at when the screen opened.

import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/attitude_fusion.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

var passed = 0;
var failed = 0;

void check(String label, bool condition, [String detail = '']) {
  if (condition) {
    passed++;
    print('  PASS  $label${detail.isEmpty ? '' : ' — $detail'}');
  } else {
    failed++;
    print('  FAIL  $label${detail.isEmpty ? '' : ' — $detail'}');
  }
}

/// The gravity a device held at [attitude] would measure, in its own frame.
Vec3 gravityFor(Quat attitude) => attitude.conjugate.rotate(Vec3.unitY);

/// Degrees by which the estimate fails to map the measured gravity onto world up.
///
/// This is the only meaningful error for this filter. Comparing
/// `expectedGravityDevice` with world up would be comparing a *device-frame*
/// vector against a *world-frame* one — they are supposed to differ, by exactly
/// the tilt of the phone.
double horizonErrorDeg(AttitudeFusion fusion, Vec3 measuredGravity) {
  final applied = fusion.deviceToWorld.rotate(measuredGravity.normalized);
  final dot = applied.dot(Vec3.unitY).clamp(-1.0, 1.0);
  final radians = math.acos(dot);
  return radians * 180 / math.pi;
}

void main() {
  print('\n1. a tilted start is levelled by the first gravity sample');
  // A phone held 20° up and rolled 10° when the screen opened.
  final tilted = Quat.fromYawPitch(0, 20) * Quat.axisAngle(10, Vec3.unitZ);
  final fusion = AttitudeFusion();
  fusion.step(
    accelMs2: gravityFor(tilted) * 9.80665,
    gyroRadSec: Vec3.zero,
    dtSeconds: 0.02,
  );
  final error = horizonErrorDeg(fusion, gravityFor(tilted));
  check(
    'horizon error after one sample is negligible',
    error < 0.05,
    '${error.toStringAsFixed(4)}°',
  );
  check(
    'the sample was used, not rejected',
    fusion.lastSampleUsedGravity,
  );

  print('\n2. the old behaviour would still be far off after one sample');
  // beta = 0.05 leaves 95% of the error after a single step. Confirm the snap
  // is a snap and not a coincidence of a small starting tilt.
  final bigTilt = Quat.fromYawPitch(0, 45);
  final big = AttitudeFusion();
  big.step(
    accelMs2: gravityFor(bigTilt) * 9.80665,
    gyroRadSec: Vec3.zero,
    dtSeconds: 0.02,
  );
  final bigError = horizonErrorDeg(big, gravityFor(bigTilt));
  check(
    'a 45° start is also levelled in one sample',
    bigError < 0.05,
    '${bigError.toStringAsFixed(4)}°',
  );

  print('\n3. a gyro-only step cannot snap the horizon');
  final gyroOnly = AttitudeFusion();
  gyroOnly.step(
    accelMs2: Vec3.zero,
    gyroRadSec: const Vec3(0.1, 0, 0),
    dtSeconds: 0.02,
  );
  check(
    'no gravity, no correction',
    !gyroOnly.lastSampleUsedGravity,
  );
  // The next real sample must still be the one that establishes the horizon.
  gyroOnly.step(
    accelMs2: gravityFor(tilted) * 9.80665,
    gyroRadSec: Vec3.zero,
    dtSeconds: 0.02,
  );
  check(
    'the first real sample still snaps',
    horizonErrorDeg(gyroOnly, gravityFor(tilted)) < 0.05,
    '${horizonErrorDeg(gyroOnly, gravityFor(tilted)).toStringAsFixed(4)}°',
  );

  print('\n4. a sample outside the gravity window is ignored');
  final bad = AttitudeFusion();
  bad.step(
    accelMs2: const Vec3(0, 30, 0),
    gyroRadSec: Vec3.zero,
    dtSeconds: 0.02,
  );
  check('rejected as not-gravity', !bad.lastSampleUsedGravity);
  bad.step(
    accelMs2: gravityFor(tilted) * 9.80665,
    gyroRadSec: Vec3.zero,
    dtSeconds: 0.02,
  );
  check(
    'the next valid sample still snaps',
    horizonErrorDeg(bad, gravityFor(tilted)) < 0.05,
  );

  print('\n5. reset() re-arms the snap');
  final reused = AttitudeFusion();
  reused.step(
    accelMs2: gravityFor(tilted) * 9.80665,
    gyroRadSec: Vec3.zero,
    dtSeconds: 0.02,
  );
  reused.reset();
  reused.step(
    accelMs2: gravityFor(tilted) * 9.80665,
    gyroRadSec: Vec3.zero,
    dtSeconds: 0.02,
  );
  check(
    'after reset, one sample levels it again',
    horizonErrorDeg(reused, gravityFor(tilted)) < 0.05,
    '${horizonErrorDeg(reused, gravityFor(tilted)).toStringAsFixed(4)}°',
  );

  print('\n6. an upright phone keeps heading 0 (no yaw introduced)');
  final upright = AttitudeFusion();
  upright.step(
    accelMs2: const Vec3(0, 9.80665, 0),
    gyroRadSec: Vec3.zero,
    dtSeconds: 0.02,
  );
  final forward = upright.deviceToWorld.rotate(const Vec3(0, 0, -1));
  check(
    'the optical axis stays on the horizon',
    forward.y.abs() < 1e-6,
    'y=${forward.y.toStringAsFixed(9)}',
  );
  check(
    'and points along −Z, i.e. heading 0',
    forward.z < -0.999,
    'z=${forward.z.toStringAsFixed(6)}',
  );

  print('\n$passed passed, $failed failed');
  if (failed > 0) {
    throw StateError('$failed attitude check(s) failed');
  }
}
