import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/equirect_bounds.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_projection.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

void main() {
  final targets = buildSphereTargets();

  group('38-target spherical layout', () {
    test('has 38 targets with unique 1-based ids in capture order', () {
      expect(targets, hasLength(kSphereTargetCount));
      expect(kSphereTargetCount, 38);
      expect(
        targets.map((SphereTargetSpec t) => t.targetId).toList(),
        List<int>.generate(kSphereTargetCount, (int i) => i + 1),
      );
    });

    test('middle ring is ids 1-12 at pitch 0, every 30 degrees', () {
      final middle = targets.sublist(0, 12);
      expect(middle.every((SphereTargetSpec t) => t.pitchDeg == 0), isTrue);
      expect(middle.map((SphereTargetSpec t) => t.yawDeg).toList(), <double>[
        0,
        30,
        60,
        90,
        120,
        150,
        180,
        -150,
        -120,
        -90,
        -60,
        -30,
      ]);
      expect(middle.first.ringLabel, 'Middle Ring (0°)');
      expect(middle.first.progressLabel, 'Target 1 / 38 — Middle Ring (0°)');
    });

    test('zenith is id 13, between the two hemispheres', () {
      final zenith = targets[12];
      expect(zenith.targetId, 13);
      expect(zenith.isZenith, isTrue);
      expect(zenith.pitchDeg, 90);
      expect(zenith.direction.y, closeTo(1, 1e-12));
      expect(zenith.ringLabel, 'Zenith');
    });

    test('upper ring is ids 14-25 at +45, sweeping back to yaw 0', () {
      final upper = targets.sublist(13, 25);
      expect(
        upper.every((SphereTargetSpec t) => t.pitchDeg == kSphereRingPitchDeg),
        isTrue,
      );
      expect(kSphereRingPitchDeg, 45);
      expect(upper.map((SphereTargetSpec t) => t.yawDeg).toList(), <double>[
        -30,
        -60,
        -90,
        -120,
        -150,
        180,
        150,
        120,
        90,
        60,
        30,
        0,
      ]);
    });

    test('lower ring is ids 26-37 at -45', () {
      final lower = targets.sublist(25, 37);
      expect(
        lower.every((SphereTargetSpec t) => t.pitchDeg == -kSphereRingPitchDeg),
        isTrue,
      );
      expect(lower.map((SphereTargetSpec t) => t.yawDeg).toList(), <double>[
        0,
        30,
        60,
        90,
        120,
        150,
        180,
        -150,
        -120,
        -90,
        -60,
        -30,
      ]);
    });

    test('nadir closes the sequence at id 38', () {
      final nadir = targets.last;
      expect(nadir.targetId, 38);
      expect(nadir.isNadir, isTrue);
      expect(nadir.pitchDeg, -90);
      expect(nadir.direction.y, closeTo(-1, 1e-12));
      expect(nadir.ringLabel, 'Nadir');
    });

    test('every direction is a unit vector at radius 1.0', () {
      for (final target in targets) {
        expect(
          target.direction.length,
          closeTo(kSphereRadiusM, 1e-12),
          reason: 'target ${target.targetId}',
        );
      }
    });

    test('the front target looks along -Z and +yaw is to the right', () {
      final front = targets.first.direction;
      expect(front.x, closeTo(0, 1e-12));
      expect(front.y, closeTo(0, 1e-12));
      expect(front.z, closeTo(-1, 1e-12));

      final right = targets[1].direction;
      expect(right.x, greaterThan(0));
      expect(right.z, lessThan(0));
    });

    test('adjacent ring targets are one 30-degree step apart in azimuth', () {
      // The azimuth step is 30° on every ring; the great-circle angle is
      // smaller on a tilted ring by cos(pitch): 2·asin(sin 15° · cos 45°) =
      // 21.06°, versus a flat 30° at the horizon.
      const tiltedStep = 21.060614246646696;
      for (var ring = 0; ring < 3; ring++) {
        final base = ring == 2 ? 25 : ring == 1 ? 13 : 0;
        final expected = ring == 0 ? 30.0 : tiltedStep;
        for (var i = 0; i < 12; i++) {
          final a = targets[base + i].direction;
          final b = targets[base + (i + 1) % 12].direction;
          expect(angleBetweenDeg(a, b), closeTo(expected, 1e-9));
        }
      }
    });

    test('every guided step is at most 120 degrees', () {
      // 30° within a ring, 45° between rings, 90° from the middle ring to the
      // zenith and 120° from the last lower-ring target to the nadir. The
      // controller guides by id order, so these are real arrow instructions.
      for (var i = 0; i < targets.length - 1; i++) {
        final step = angleBetweenDeg(
          targets[i].direction,
          targets[i + 1].direction,
        );
        expect(
          step,
          lessThanOrEqualTo(120.001),
          reason:
              'step ${targets[i].targetId} -> ${targets[i + 1].targetId} '
              'is ${step.toStringAsFixed(1)}°',
        );
      }
    });
  });

  group('level start frame', () {
    // A phone held the way someone actually presses Start: turned 40°, tilted
    // down 20°, rolled 10° in the hand.
    final tilted =
        (Quat.axisAngle(40, Vec3.unitY) *
                Quat.axisAngle(-20, Vec3.unitX) *
                Quat.axisAngle(10, Vec3.unitZ))
            .normalized;
    final level = levelStartFrame(tilted)!;

    double elevation(Vec3 v) =>
        math.asin(clampDouble(v.normalized.y, -1, 1)) * radToDeg;
    double heading(Vec3 v) =>
        math.atan2(v.normalized.x, -v.normalized.z) * radToDeg;

    test('the middle ring is the horizon, not the phone tilt', () {
      // The raw pose put this at the tilt angle; levelling removes it.
      expect(
        elevation(tilted.rotate(sphereDirection(0, 0))),
        closeTo(-20, 0.1),
      );
      expect(elevation(level.rotate(sphereDirection(0, 0))), closeTo(0, 1e-9));
    });

    test('the upper and lower rings are 45 degrees above and below', () {
      expect(
        elevation(level.rotate(sphereDirection(0, kSphereRingPitchDeg))),
        closeTo(45, 1e-9),
      );
      expect(
        elevation(level.rotate(sphereDirection(0, -kSphereRingPitchDeg))),
        closeTo(-45, 1e-9),
      );
    });

    test('the zenith is straight up and the heading is kept', () {
      expect(
        elevation(level.rotate(sphereDirection(0, 90))),
        closeTo(90, 1e-9),
      );
      expect(
        heading(level.rotate(sphereDirection(0, 0))),
        closeTo(heading(tilted.rotate(sphereDirection(0, 0))), 1e-9),
      );
    });

    test('a near-vertical start is rejected, not guessed', () {
      final ceiling = Quat.axisAngle(80, Vec3.unitX);
      expect(hasStableHeading(ceiling), isFalse);
      expect(levelStartFrame(ceiling), isNull);
      // A normal pose still calibrates.
      expect(hasStableHeading(tilted), isTrue);
      expect(levelStartFrame(tilted), isNotNull);
    });
  });

  group('Android ENU levelling', () {
    // Android's rotation vector reports East–North–Up: +X east, +Y north,
    // **+Z up**. Every quaternion below is in that frame, which is the frame
    // the device actually delivers and the frame the old `+Y`-up levelling
    // silently misread.
    const Vec3 enuUp = Vec3(0, 0, 1);

    // Phone held level, facing north, portrait upright:
    // device x → East, y → Up, z → −North.
    final levelNorth = Quat.fromMatrix3(<double>[
      1, 0, 0, //
      0, 0, -1, //
      0, 1, 0, //
    ]);

    double elevationEnu(Vec3 v) =>
        math.asin(clampDouble(v.normalized.z, -1, 1)) * radToDeg;

    Vec3 horizontalEnu(Vec3 v) => Vec3(v.x, v.y, 0).normalized;

    test('a level pose is already level', () {
      final level = levelStartFrame(levelNorth, worldUp: enuUp)!;
      expect(
        elevationEnu(level.rotate(sphereDirection(0, 0))),
        closeTo(0, 1e-9),
      );
    });

    test('a start 30° down keeps the middle ring on the horizon', () {
      // Tilt down about the device's own X axis, which is East here.
      final tilted = (levelNorth * Quat.axisAngle(-30, Vec3.unitX)).normalized;
      // The raw pose points 30° below the horizon...
      expect(
        elevationEnu(tilted.rotate(sphereDirection(0, 0))),
        closeTo(-30, 1e-9),
      );
      // ...and levelling removes it.
      final level = levelStartFrame(tilted, worldUp: enuUp)!;
      expect(
        elevationEnu(level.rotate(sphereDirection(0, 0))),
        closeTo(0, 1e-9),
      );
    });

    test('every ring keeps its 0 / ±45 / ±90 elevation', () {
      // Start tilted down and rolled in the hand; the rings must not inherit
      // either. This is the property the device recording showed broken.
      final tilted =
          (levelNorth *
                  Quat.axisAngle(-30, Vec3.unitX) *
                  Quat.axisAngle(12, Vec3.unitZ))
              .normalized;
      final level = levelStartFrame(tilted, worldUp: enuUp)!;
      expect(
        elevationEnu(level.rotate(sphereDirection(0, 0))),
        closeTo(0, 1e-9),
      );
      expect(
        elevationEnu(
          level.rotate(sphereDirection(120, kSphereRingPitchDeg)),
        ),
        closeTo(45, 1e-9),
      );
      expect(
        elevationEnu(
          level.rotate(sphereDirection(-60, -kSphereRingPitchDeg)),
        ),
        closeTo(-45, 1e-9),
      );
      expect(
        elevationEnu(level.rotate(sphereDirection(0, 90))),
        closeTo(90, 1e-9),
      );
      expect(
        elevationEnu(level.rotate(sphereDirection(0, -90))),
        closeTo(-90, 1e-9),
      );
    });

    test('the start heading is preserved, not rotated', () {
      final tilted = (levelNorth * Quat.axisAngle(-30, Vec3.unitX)).normalized;
      final level = levelStartFrame(tilted, worldUp: enuUp)!;
      expect(
        (horizontalEnu(tilted.rotate(sphereDirection(0, 0))) -
                horizontalEnu(level.rotate(sphereDirection(0, 0))))
            .length,
        lessThan(1e-9),
      );
    });

    test('levelling with +Y up on ENU data puts the ring on the floor', () {
      // The exact regression: the old implementation hard-coded `+Y` as up.
      // On real sensor data that drops the *north* component instead of the
      // vertical one, so the "horizon" ring ends up pointing at the floor.
      final tilted = (levelNorth * Quat.axisAngle(-30, Vec3.unitX)).normalized;
      final wrong = levelStartFrame(tilted)!;
      expect(
        elevationEnu(wrong.rotate(sphereDirection(0, 0))),
        closeTo(-90, 1e-6),
      );
    });

    test('a ceiling start is rejected in the ENU frame too', () {
      // Camera aimed straight up: device −Z → world +Z.
      final ceiling = (levelNorth * Quat.axisAngle(90, Vec3.unitX)).normalized;
      expect(hasStableHeading(ceiling, worldUp: enuUp), isFalse);
      expect(levelStartFrame(ceiling, worldUp: enuUp), isNull);
      expect(hasStableHeading(levelNorth, worldUp: enuUp), isTrue);
    });
  });

  group('equirectangular frame bounds', () {
    const int w = 3072;
    const int h = 4096;
    final focal =
        (h / 2) / math.tan(kSphereAssumedVerticalFovDeg * math.pi / 360);

    // The stitcher's `cameraToSphere` is the rotation that takes the camera's
    // own frame into the sphere frame. `fromYawPitch(-yaw, -pitch)` maps
    // `(0,0,−1)` onto `sphereDirection(yaw, pitch)`, which is the direction the
    // frame was taken at.
    ({double minLon, double maxLon, double minLat, double maxLat, bool fullWidth})
    boundsFor(double yaw, double pitch) => equirectFrameBounds(
      Quat.fromYawPitch(-yaw, -pitch),
      w,
      h,
      focal,
      w / 2,
      h / 2,
    );

    double lonOf(Vec3 dir) => math.atan2(dir.x, -dir.z);
    double latOf(Vec3 dir) => math.asin(clampDouble(dir.normalized.y, -1, 1));

    /// Whether a world direction falls inside the interval the stitcher will
    /// actually project — the check that matters, not merely that the function
    /// returned a tuple.
    bool covers(
      ({
        double minLon,
        double maxLon,
        double minLat,
        double maxLat,
        bool fullWidth,
      })
      b,
      Vec3 dir,
    ) {
      final lat = latOf(dir);
      if (lat < b.minLat || lat > b.maxLat) return false;
      if (b.fullWidth) return true;
      var lon = lonOf(dir);
      final centre = (b.minLon + b.maxLon) / 2;
      while (lon - centre > math.pi) {
        lon -= 2 * math.pi;
      }
      while (lon - centre < -math.pi) {
        lon += 2 * math.pi;
      }
      return lon >= b.minLon && lon <= b.maxLon;
    }

    test('a forward frame is contiguous and covers its own axis', () {
      final b = boundsFor(0, 0);
      expect(b.fullWidth, isFalse);
      expect(b.maxLon, greaterThan(b.minLon));
      expect(covers(b, sphereDirection(0, 0)), isTrue);
    });

    test('+90 and -90 are contiguous and cover their own axis', () {
      for (final yaw in <double>[90, -90]) {
        final b = boundsFor(yaw, 0);
        expect(b.fullWidth, isFalse, reason: 'yaw $yaw');
        expect(b.maxLon, greaterThan(b.minLon), reason: 'yaw $yaw');
        expect(covers(b, sphereDirection(yaw, 0)), isTrue, reason: 'yaw $yaw');
      }
    });

    test('180 degrees does not produce a reversed interval', () {
      final b = boundsFor(180, 0);
      expect(b.fullWidth, isFalse);
      // The defect: independent unwrapping could leave maxLon < minLon, which
      // made the column loop run zero times and silently dropped the frame.
      expect(b.maxLon, greaterThan(b.minLon));
      expect(covers(b, sphereDirection(180, 0)), isTrue);
    });

    test('a frame straddling the seam still covers both sides of it', () {
      final b = boundsFor(175, 0);
      expect(b.maxLon, greaterThan(b.minLon));
      // Contiguous around its own centre, not the whole circle.
      expect(b.maxLon - b.minLon, lessThan(math.pi));
      // Both the +π side and the −π side of the seam belong to it.
      expect(covers(b, sphereDirection(175, 0)), isTrue);
      expect(covers(b, sphereDirection(185, 0)), isTrue);
      expect(covers(b, sphereDirection(-175, 0)), isTrue);
    });

    test('zenith and nadir cover every longitude', () {
      expect(boundsFor(0, 90).fullWidth, isTrue);
      expect(boundsFor(0, -90).fullWidth, isTrue);
    });

    test('no target direction produces a reversed or empty interval', () {
      for (final t in targets) {
        final b = boundsFor(t.yawDeg, t.pitchDeg);
        expect(
          b.maxLon,
          greaterThan(b.minLon),
          reason: 'target ${t.targetId} (${t.ringLabel})',
        );
        expect(
          b.maxLat,
          greaterThan(b.minLat),
          reason: 'target ${t.targetId} (${t.ringLabel})',
        );
        expect(
          covers(b, t.direction),
          isTrue,
          reason: 'target ${t.targetId} must be inside its own bounds',
        );
      }
    });

    test('a direction inside the frame is inside the bounds', () {
      // 10° to the right of the optical axis, in camera coordinates.
      final probe = Quat.fromYawPitch(0, 0).rotate(
        Vec3(math.tan(10 * math.pi / 180), 0, -1).normalized,
      );
      expect(covers(boundsFor(0, 0), probe), isTrue);
    });
  });
}
