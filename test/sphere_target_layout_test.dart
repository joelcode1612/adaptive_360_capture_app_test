import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_projection.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';

void main() {
  final targets = buildSphereTargets();

  group('38-target spherical layout', () {
    test('has 38 targets with unique 1-based ids in capture order', () {
      expect(targets, hasLength(kSphereTargetCount));
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

    test('upper ring is ids 14-25 at +45, sweeping back to yaw 0', () {
      final upper = targets.sublist(13, 25);
      expect(
        upper.every((SphereTargetSpec t) => t.pitchDeg == kSphereRingPitchDeg),
        isTrue,
      );
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

    test('zenith is id 13 after the middle ring', () {
      final zenith = targets[12];
      expect(zenith.targetId, 13);
      expect(zenith.isZenith, isTrue);
      expect(zenith.pitchDeg, 90);
      expect(zenith.direction.y, closeTo(1, 1e-12));
      expect(zenith.ringLabel, 'Zenith');
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

    test('adjacent ring targets are 30 degrees apart', () {
      for (var i = 0; i < 12; i++) {
        final a = targets[i].direction;
        final b = targets[(i + 1) % 12].direction;
        expect(angleBetweenDeg(a, b), closeTo(30, 1e-9));
      }
    });

    test('every guided step is at most 90 degrees', () {
      // 30° within a ring, 45° between rings, 90° at the pole and at the
      // hemisphere transition (upper +45° to lower −45°). The stitcher matches
      // every pair independently, so the 90° steps are guidance, not gaps.
      for (var i = 0; i < targets.length - 1; i++) {
        final step = angleBetweenDeg(
          targets[i].direction,
          targets[i + 1].direction,
        );
        expect(
          step,
          lessThanOrEqualTo(90.001),
          reason:
              'step ${targets[i].targetId} -> ${targets[i + 1].targetId} '
              'is ${step.toStringAsFixed(1)}°',
        );
      }
    });
  });
}
