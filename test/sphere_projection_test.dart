import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_projection.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

void main() {
  final front = buildSphereTargets().first.direction;
  const identity = Quat.identity;

  Vec3 cameraDirection(Quat device) => sphereTargetCameraDirection(
    deviceToWorld: device,
    startDeviceToWorld: identity,
    startDirection: front,
  );

  group('q⁻¹ · (q₀ · v) rotation', () {
    test('identity keeps the front target on the reticle', () {
      expect(reticleErrorDeg(cameraDirection(identity)), closeTo(0, 1e-9));
    });

    test('turning right 45° moves the fixed target 45° to the left', () {
      // A right turn is a negative rotation about world +Y (right-handed).
      final device = Quat.axisAngle(-45, Vec3.unitY);
      final direction = cameraDirection(device);
      expect(reticleErrorDeg(direction), closeTo(45, 1e-6));
      expect(direction.x, lessThan(0));
    });

    test('turning left 45° moves the target 45° to the right', () {
      final device = Quat.axisAngle(45, Vec3.unitY);
      final direction = cameraDirection(device);
      expect(reticleErrorDeg(direction), closeTo(45, 1e-6));
      expect(direction.x, greaterThan(0));
    });

    test('tilting up 30° puts the horizon target 30° below centre', () {
      final device = Quat.axisAngle(30, Vec3.unitX);
      final direction = cameraDirection(device);
      expect(reticleErrorDeg(direction), closeTo(30, 1e-6));
      expect(direction.y, lessThan(0));
    });

    test('zenith is 90° away at rest and centred after tilting up 90°', () {
      final zenith = buildSphereTargets()[24].direction;
      final atRest = sphereTargetCameraDirection(
        deviceToWorld: identity,
        startDeviceToWorld: identity,
        startDirection: zenith,
      );
      expect(reticleErrorDeg(atRest), closeTo(90, 1e-6));

      final tilted = sphereTargetCameraDirection(
        deviceToWorld: Quat.axisAngle(90, Vec3.unitX),
        startDeviceToWorld: identity,
        startDirection: zenith,
      );
      expect(reticleErrorDeg(tilted), closeTo(0, 1e-6));
    });

    test('nadir is centred after tilting down 90°', () {
      final nadir = buildSphereTargets()[25].direction;
      final tilted = sphereTargetCameraDirection(
        deviceToWorld: Quat.axisAngle(-90, Vec3.unitX),
        startDeviceToWorld: identity,
        startDirection: nadir,
      );
      expect(reticleErrorDeg(tilted), closeTo(0, 1e-6));
    });

    test('the inverse rotation round-trips', () {
      final q =
          (Quat.axisAngle(37, Vec3.unitY) * Quat.axisAngle(-12, Vec3.unitX))
              .normalized;
      final v = sphereDirection(63, -21);
      final roundTrip = q.conjugate.rotate(q.rotate(v));
      expect(roundTrip.maxAbsDiff(v), lessThan(1e-12));
    });

    test('a non-identity start orientation is respected', () {
      // The user pressed Start while already facing 30° to the right. The
      // target sphere is anchored to that pose, so at Start the front target
      // must still be centred.
      final start = Quat.axisAngle(-30, Vec3.unitY);
      final direction = sphereTargetCameraDirection(
        deviceToWorld: start,
        startDeviceToWorld: start,
        startDirection: front,
      );
      expect(reticleErrorDeg(direction), closeTo(0, 1e-9));
    });
  });

  group('pinhole projection', () {
    const projection = SphereProjection(width: 400, height: 800);

    test('a centred direction projects to the viewport centre', () {
      final point = projection.project(front);
      expect(point, isNotNull);
      expect(point!.dx, closeTo(200, 1e-9));
      expect(point.dy, closeTo(400, 1e-9));
    });

    test('a direction to the right projects right of centre', () {
      final point = projection.project(sphereDirection(10, 0));
      expect(point, isNotNull);
      expect(point!.dx, greaterThan(200));
      expect(point.dy, closeTo(400, 1e-9));
    });

    test('a direction above projects above centre', () {
      final point = projection.project(sphereDirection(0, 10));
      expect(point, isNotNull);
      expect(point!.dy, lessThan(400));
      expect(point.dx, closeTo(200, 1e-9));
    });

    test('a direction behind the camera has no projection', () {
      expect(projection.project(const Vec3(0, 0, 1)), isNull);
    });

    test('the tolerance radius matches the 5° cone', () {
      final expected =
          (800 / 2) /
          math.tan(65 * math.pi / 360) *
          math.tan(kSphereAlignmentToleranceDeg * math.pi / 180);
      expect(projection.toleranceRadiusPx, closeTo(expected, 1e-9));
      expect(projection.toleranceRadiusPx, greaterThan(0));
    });
  });

  group('overlap estimate', () {
    test('falls from full overlap to none at the horizontal field of view', () {
      expect(estimatedOverlapFraction(0), closeTo(1, 1e-9));
      expect(estimatedOverlapFraction(25), closeTo(0.5, 1e-9));
      expect(estimatedOverlapFraction(50), closeTo(0, 1e-9));
      expect(estimatedOverlapFraction(60), 0);
    });

    test('a 30° ring step leaves 40% at a 50° field of view', () {
      expect(estimatedOverlapFraction(30), closeTo(0.4, 1e-9));
      expect(estimatedOverlapFraction(45), closeTo(0.1, 1e-9));
    });
  });

  group('angleBetweenDeg', () {
    test('is 0 for equal directions and 180 for opposites', () {
      expect(angleBetweenDeg(front, front), closeTo(0, 1e-9));
      expect(angleBetweenDeg(front, -front), closeTo(180, 1e-9));
    });

    test('matches the known 45° ring spacing', () {
      expect(
        angleBetweenDeg(sphereDirection(0, 0), sphereDirection(45, 0)),
        closeTo(45, 1e-9),
      );
      expect(
        angleBetweenDeg(sphereDirection(0, 0), sphereDirection(0, 30)),
        closeTo(30, 1e-9),
      );
    });
  });
}
