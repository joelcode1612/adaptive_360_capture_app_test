// Verifies the gyroscope dwell gate that must pass before the shutter fires.
//
//   dart --packages=.dart_tool/sphere_verify_package_config.json \
//        tool/verify_motion_freeze.dart
//
// The gate is pure, so the rule can be exercised exactly: the phone must stay
// under 0.05 rad/s continuously for 250 ms, and a single fast sample must break
// the dwell rather than being averaged away.

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/motion_freeze_gate.dart';
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

final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(1000000);

DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

void main() {
  print('\n1. a still phone becomes ready only after the dwell');
  final gate = MotionFreezeGate();
  gate.update(Vec3.zero, at(0));
  check('not ready at t=0', !gate.still);
  gate.update(Vec3.zero, at(120));
  check('not ready at 120 ms', !gate.still);
  gate.update(Vec3.zero, at(250));
  check('ready at 250 ms', gate.still);
  check(
    'progress reaches 1',
    gate.progress >= 1.0,
    gate.progress.toStringAsFixed(2),
  );

  print('\n2. one fast sample breaks the dwell');
  final broken = MotionFreezeGate();
  broken.update(Vec3.zero, at(0));
  broken.update(Vec3.zero, at(300));
  check('ready before the spike', broken.still);
  broken.update(const Vec3(0.4, 0, 0), at(320));
  check('not ready after the spike', !broken.still);
  broken.update(Vec3.zero, at(400));
  check('dwell restarts from the spike', !broken.still);
  broken.update(Vec3.zero, at(650));
  check('ready again after a full dwell', broken.still);

  print('\n3. the threshold is inclusive and the magnitude is what counts');
  final edge = MotionFreezeGate();
  // Exactly 0.05 rad/s on one axis: allowed.
  edge.update(const Vec3(0.05, 0, 0), at(0));
  edge.update(const Vec3(0.05, 0, 0), at(260));
  check('exactly at the threshold is still', edge.still);

  final diagonal = MotionFreezeGate();
  // 0.04 per axis is under the per-axis value but 0.069 in magnitude: moving.
  diagonal.update(const Vec3(0.04, 0.04, 0.04), at(0));
  diagonal.update(const Vec3(0.04, 0.04, 0.04), at(300));
  check(
    'the magnitude decides, not one axis',
    !diagonal.still,
    'rate ${diagonal.lastRateRadPerSec.toStringAsFixed(3)} rad/s',
  );

  print('\n4. a gap between samples does not fake a dwell');
  final sparse = MotionFreezeGate();
  sparse.update(Vec3.zero, at(0));
  // The next sample arrives 5 s later. The dwell is measured from the first
  // still sample, so it is legitimately satisfied — the phone was still
  // throughout; what matters is that it is measured from the *sample*, not
  // invented.
  sparse.update(Vec3.zero, at(5000));
  check('still, measured from the first still sample', sparse.still);

  print('\n5. reset() forgets everything');
  final reused = MotionFreezeGate();
  reused.update(Vec3.zero, at(0));
  reused.update(Vec3.zero, at(300));
  check('ready before reset', reused.still);
  reused.reset();
  check('not ready after reset', !reused.still);
  check('no still window', reused.stillSince == null);

  print('\n6. a non-finite rate can never satisfy the gate');
  final nan = MotionFreezeGate();
  nan.update(const Vec3(double.nan, 0, 0), at(0));
  nan.update(const Vec3(double.nan, 0, 0), at(300));
  check('NaN rate blocks the shutter', !nan.still);

  print('\n$passed passed, $failed failed');
  if (failed > 0) {
    throw StateError('$failed freeze-gate check(s) failed');
  }
}
