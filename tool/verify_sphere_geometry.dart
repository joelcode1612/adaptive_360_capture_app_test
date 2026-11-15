// Verification harness for the 3DoF sphere geometry.
//
// `flutter test` cannot run on this host: the `opencv_dart` build hook compiles
// a native library and the sandbox blocks the toolchain it invokes. The
// rotation chain, however, is pure Dart — so this script exercises the *real*
// production functions (`levelStartFrame`, `sphereTargetCameraDirection`,
// `reticleErrorDeg`, `buildSphereTargets`) and prints the numbers instead of
// only asserting them.
//
// `dart run` also triggers the native hook, so the VM is pointed at a package
// config that contains only this app package. Create it once:
//
//   .dart_tool/sphere_verify_package_config.json
//   {"configVersion":2,"packages":[{"name":"adaptive_360_capture_app",
//    "rootUri":"../","packageUri":"lib/","languageVersion":"3.6"}]}
//
// then:
//
//   dart --packages=.dart_tool/sphere_verify_package_config.json \
//        tool/verify_sphere_geometry.dart
//
// Every scenario in the specification's §10 verification table that can be
// decided without a physical sensor is covered here. Sensor accuracy, real
// camera intrinsics and the shutter itself still require a device; the script
// says so rather than implying otherwise.
import 'dart:math' as math;

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_math.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _passed++;
    print('  PASS  $name${detail.isEmpty ? '' : '  — $detail'}');
  } else {
    _failed++;
    print('  FAIL  $name${detail.isEmpty ? '' : '  — $detail'}');
  }
}

void closeTo(
  String name,
  double actual,
  double expected,
  double tolerance, [
  String unit = '°',
]) {
  final delta = (actual - expected).abs();
  check(
    name,
    delta <= tolerance,
    '${actual.toStringAsFixed(3)}$unit vs '
    '${expected.toStringAsFixed(3)}$unit '
    '(Δ${delta.toStringAsFixed(4)})',
  );
}

void main() {
  // Android's rotation vector reports East–North–Up: +X east, +Y north, +Z up.
  const Vec3 enuUp = Vec3(0, 0, 1);

  // Phone held level, facing north, portrait upright.
  final levelNorth = Quat.fromMatrix3(<double>[
    1, 0, 0, //
    0, 0, -1, //
    0, 1, 0, //
  ]);

  /// Elevation above the real horizon, measured against ENU's `+Z`.
  double elevation(Vec3 v) =>
      math.asin(clampDouble(v.normalized.z, -1, 1)) * radToDeg;

  /// The camera-frame direction of a target for a given device pose.
  Vec3 cameraDirection(Quat device, Vec3 startDirection, Quat start) =>
      sphereTargetCameraDirection(
        deviceToWorld: device,
        startDeviceToWorld: start,
        startDirection: startDirection,
      );

  final targets = buildSphereTargets();
  final front = targets.first.direction;

  print('\n=== 1. Layout ===');
  check('38 targets', targets.length == kSphereTargetCount,
      '${targets.length}');
  check(
    'middle ring is ids 1-12 at pitch 0',
    targets.take(12).every((SphereTargetSpec t) => t.pitchDeg == 0),
  );
  check('zenith is id 13', targets[12].isZenith && targets[12].targetId == 13);
  check(
    'upper ring is ids 14-25 at +35',
    targets
        .sublist(13, 25)
        .every((SphereTargetSpec t) => t.pitchDeg == kSphereRingPitchDeg),
  );
  check(
    'lower ring is ids 26-37 at -35',
    targets
        .sublist(25, 37)
        .every((SphereTargetSpec t) => t.pitchDeg == -kSphereRingPitchDeg),
  );
  check('nadir is id 38', targets.last.isNadir && targets.last.targetId == 38);
  closeTo(
    'adjacent middle targets are 30° apart',
    angleBetweenDeg(targets[0].direction, targets[1].direction),
    30,
    1e-9,
  );

  print('\n=== 2. Gravity-aligned calibration (the reported bug) ===');
  {
    final level = levelStartFrame(levelNorth, worldUp: enuUp)!;
    final dir = cameraDirection(levelNorth, front, level);
    closeTo('level start: target 1 sits on the reticle', reticleErrorDeg(dir), 0, 1e-6);
    closeTo('level start: middle ring is the horizon',
        elevation(level.rotate(sphereDirection(0, 0))), 0, 1e-9);
  }

  {
    // The user presses Start while holding the phone 30° down.
    final tilted = (levelNorth * Quat.axisAngle(-30, Vec3.unitX)).normalized;
    final level = levelStartFrame(tilted, worldUp: enuUp)!;
    final dir = cameraDirection(tilted, front, level);
    closeTo(
      'start tilted 30° down: target 1 is 30° ABOVE the reticle',
      reticleErrorDeg(dir),
      30,
      1e-6,
    );
    check('start tilted 30° down: target 1 is in front, not behind',
        dir.z < 0, 'z=${dir.z.toStringAsFixed(3)}');
    closeTo(
      'start tilted 30° down: middle ring is still the horizon',
      elevation(level.rotate(sphereDirection(0, 0))),
      0,
      1e-9,
    );
  }

  {
    // The old implementation levelled against +Y on +Z-up sensor data.
    final tilted = (levelNorth * Quat.axisAngle(-30, Vec3.unitX)).normalized;
    final wrong = levelStartFrame(tilted)!;
    final wrongElevation = elevation(wrong.rotate(sphereDirection(0, 0)));
    check(
      'REGRESSION GUARD: the old +Y-up levelling put the ring on the floor',
      (wrongElevation + 90).abs() < 1e-6,
      'ring elevation ${wrongElevation.toStringAsFixed(1)}°',
    );
  }

  {
    // Tilted down AND rolled in the hand.
    final tilted =
        (levelNorth *
                Quat.axisAngle(-30, Vec3.unitX) *
                Quat.axisAngle(12, Vec3.unitZ))
            .normalized;
    final level = levelStartFrame(tilted, worldUp: enuUp)!;
    final rings = <double>[
      elevation(level.rotate(sphereDirection(0, 0))),
      elevation(level.rotate(sphereDirection(120, kSphereRingPitchDeg))),
      elevation(level.rotate(sphereDirection(-60, -kSphereRingPitchDeg))),
      elevation(level.rotate(sphereDirection(0, 90))),
      elevation(level.rotate(sphereDirection(0, -90))),
    ];
    closeTo('rolled start: middle ring stays level', rings[0], 0, 1e-9);
    closeTo('rolled start: upper ring stays at +35', rings[1], 35, 1e-9);
    closeTo('rolled start: lower ring stays at -35', rings[2], -35, 1e-9);
    closeTo('rolled start: zenith stays at +90', rings[3], 90, 1e-9);
    closeTo('rolled start: nadir stays at -90', rings[4], -90, 1e-9);
  }

  print('\n=== 3. Horizontal rotation keeps the middle ring level ===');
  {
    final level = levelStartFrame(levelNorth, worldUp: enuUp)!;
    var worstRise = 0.0;
    var worstError = 0.0;
    for (var turn = 0; turn <= 360; turn += 15) {
      // A right turn is a negative rotation about world up.
      final device = (Quat.axisAngle(-turn.toDouble(), enuUp) * levelNorth)
          .normalized;
      final dir = cameraDirection(device, front, level);
      // `dir` is in the camera frame, so its `y` component is screen height.
      // A horizon target must stay on the horizon line however far the phone
      // has turned — that is the "targets drift above/below the room" symptom.
      worstRise = math.max(worstRise, dir.y.abs());
      // The target must sweep left by exactly the turn, up to 180°, then back.
      final expected = turn <= 180 ? turn.toDouble() : 360.0 - turn;
      worstError = math.max(
        worstError,
        (reticleErrorDeg(dir) - expected).abs(),
      );
    }
    check(
      'sweeping 0°…360° never lifts the horizon off the horizon',
      worstRise < 1e-9,
      'worst vertical drift ${worstRise.toStringAsExponential(2)}',
    );
    check(
      'the target tracks the turn exactly',
      worstError < 1e-6,
      'worst bearing error ${worstError.toStringAsExponential(2)}°',
    );
  }

  print('\n=== 4. Sequential guidance: the next target is beside this one ===');
  {
    final level = levelStartFrame(levelNorth, worldUp: enuUp)!;
    final second = targets[1].direction;

    // Facing target 1.
    final atOne = cameraDirection(levelNorth, second, level);
    closeTo('target 2 is one 30° step away from target 1',
        reticleErrorDeg(atOne), 30, 1e-6);
    check(
      'target 2 appears to the RIGHT of the reticle',
      atOne.x > 0,
      'camera x=${atOne.x.toStringAsFixed(3)}',
    );
    check(
      'target 2 is in front of the camera plane',
      atOne.z < 0,
      'camera z=${atOne.z.toStringAsFixed(3)}',
    );

    // Turning right 30° brings it to the centre.
    final turned =
        (Quat.axisAngle(-30, enuUp) * levelNorth).normalized;
    closeTo(
      'turning right 30° centres target 2',
      reticleErrorDeg(cameraDirection(turned, second, level)),
      0,
      1e-6,
    );
    closeTo(
      'the turn moves target 1 to the left by 30°',
      reticleErrorDeg(cameraDirection(turned, front, level)),
      30,
      1e-6,
    );

    // And target 3 is then the one beside it, on the same side.
    final third = targets[2].direction;
    final atTwo = cameraDirection(turned, third, level);
    closeTo('target 3 is a further 30° step', reticleErrorDeg(atTwo), 30, 1e-6);
    check('target 3 is again to the right', atTwo.x > 0);
  }

  print('\n=== 5. Tilting to the upper and lower rings ===');
  {
    final level = levelStartFrame(levelNorth, worldUp: enuUp)!;
    // A positive rotation about world East lifts the optical axis; the sign
    // matters, and getting it wrong is how a "tilt up" test silently tests a
    // tilt down.
    final up = (Quat.axisAngle(kSphereRingPitchDeg, Vec3.unitX) * levelNorth)
        .normalized;
    closeTo(
      'tilting up 35° centres the upper-ring target above the start heading',
      reticleErrorDeg(
        cameraDirection(up, sphereDirection(0, kSphereRingPitchDeg), level),
      ),
      0,
      1e-6,
    );
    final down =
        (Quat.axisAngle(-kSphereRingPitchDeg, Vec3.unitX) * levelNorth)
            .normalized;
    closeTo(
      'tilting down 35° centres the lower-ring target',
      reticleErrorDeg(
        cameraDirection(down, sphereDirection(0, -kSphereRingPitchDeg), level),
      ),
      0,
      1e-6,
    );
    // The horizon is 35° away at that point, which is why the ring step is 35°.
    closeTo(
      'at the upper ring the horizon sits 35° below centre',
      reticleErrorDeg(cameraDirection(up, front, level)),
      35,
      1e-6,
    );
    check(
      'the horizon is below centre when tilted up',
      cameraDirection(up, front, level).y < 0,
    );
  }

  print('\n=== 6. 360° round trip ===');
  {
    final level = levelStartFrame(levelNorth, worldUp: enuUp)!;
    var q = levelNorth;
    for (var i = 0; i < 24; i++) {
      q = (Quat.axisAngle(-15, enuUp) * q).normalized;
    }
    closeTo(
      'after a full turn the original target is back on the reticle',
      reticleErrorDeg(cameraDirection(q, front, level)),
      0,
      1e-6,
    );
  }

  print('\n=== 7. Capture route continuity ===');
  {
    var maxStep = 0.0;
    var maxFrom = 0;
    var maxTo = 0;
    for (var i = 0; i < targets.length - 1; i++) {
      final step = angleBetweenDeg(
        targets[i].direction,
        targets[i + 1].direction,
      );
      if (step > maxStep) {
        maxStep = step;
        maxFrom = targets[i].targetId;
        maxTo = targets[i + 1].targetId;
      }
    }
    check(
      'no guided step exceeds 90°',
      maxStep <= 90.001,
      'worst $maxFrom → $maxTo = ${maxStep.toStringAsFixed(1)}°',
    );
    check('target 1 is the compulsory first capture', targets.first.targetId == 1);
    closeTo(
      'middle → zenith is the unavoidable 90° pole step',
      angleBetweenDeg(targets[11].direction, targets[12].direction),
      90,
      1e-6,
    );
  }

  print('\n=== 8. Stitching overlap stays sufficient ===');
  {
    // The stitcher does not need *consecutive* frames to overlap — it needs
    // every direction of the sphere to be covered. What must not happen is a
    // frame with no neighbour inside its own frustum, which is what leaves a
    // seam nobody can hide.
    //
    // The test is frustum-aware, not a flat angle: a pole's nearest neighbour
    // is *vertical*, where a 3:4 portrait frame is widest (65° vfov), so
    // judging it against the 51° horizontal fov would reject a perfectly
    // overlapped zenith. Reach is computed in tangent space along the bearing
    // to the neighbour — the same rule the coverage report uses.
    const hfov = 51.08; // 65° vfov at 3:4 portrait
    double reachDeg(SphereTargetSpec from, SphereTargetSpec to) {
      final basisRight = from.direction.cross(const Vec3(0, 0, 1));
      final right = basisRight.length < 1e-6
          ? const Vec3(1, 0, 0)
          : basisRight.normalized;
      final up = from.direction.cross(right).normalized;
      final d = to.direction;
      final bearing = math.atan2(d.dot(up), d.dot(right));
      final halfW = math.tan(hfov * math.pi / 360);
      final halfH = math.tan(kSphereAssumedVerticalFovDeg * math.pi / 360);
      final c = math.cos(bearing).abs();
      final s = math.sin(bearing).abs();
      final r = math.min(
        c < 1e-9 ? double.infinity : halfW / c,
        s < 1e-9 ? double.infinity : halfH / s,
      );
      return math.atan(r) * 180 / math.pi;
    }

    var tightestMargin = double.infinity;
    var worstId = 0;
    var worstDetail = '';
    for (final target in targets) {
      // This frame's best overlap margin over all neighbours; the worst
      // frame on the sphere is the one whose best margin is smallest.
      var bestMargin = double.negativeInfinity;
      var bestAngle = 180.0;
      for (final other in targets) {
        if (identical(other, target)) continue;
        final angle = angleBetweenDeg(target.direction, other.direction);
        final combined = reachDeg(target, other) + reachDeg(other, target);
        final margin = combined - angle;
        if (margin > bestMargin) {
          bestMargin = margin;
          bestAngle = angle;
        }
      }
      if (bestMargin < tightestMargin) {
        tightestMargin = bestMargin;
        worstId = target.targetId;
        worstDetail = 'nearest ${bestAngle.toStringAsFixed(1)}°';
      }
    }
    check(
      'every frame overlaps at least one neighbour inside its frustum',
      tightestMargin > 0,
      'tightest is target $worstId: $worstDetail, margin '
      '${tightestMargin.toStringAsFixed(1)}° of combined reach',
    );
    closeTo(
      'a 30° ring step keeps 40% overlap',
      estimatedOverlapFraction(30),
      0.4,
      1e-9,
      '',
    );
    closeTo(
      'a 35° ring transition keeps 30% overlap',
      estimatedOverlapFraction(35),
      0.3,
      1e-9,
      '',
    );
  }

  print('\n$_passed passed, $_failed failed.');
  if (_failed > 0) {
    throw StateError('$_failed geometry check(s) failed');
  }
  print(
    'Not decidable without a device: sensor accuracy, real camera '
    'intrinsics, the shutter, and the stitched panorama.',
  );
}
