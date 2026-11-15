import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/stitch/stitch_neighbor_planner.dart';

/// The station layout this app actually builds: ids 1–8 are the middle ring
/// (45° yaw spacing), 9–16 upper (+45°), 17–24 lower (−45°), 25 zenith and
/// 26 nadir. Every expectation below is stated against those facts.
void main() {
  final specs = buildCaptureSphere();
  CaptureTargetSpec specFor(int id) =>
      specs.firstWhere((CaptureTargetSpec s) => s.targetId == id);

  group('StitchNeighborPlanner', () {
    test('the first capture has no candidates', () {
      const planner = StitchNeighborPlanner();
      final planned = planner.plan(
        forTarget: specFor(1),
        allSpecs: specs,
        capturedIds: const <int>{},
      );
      expect(planned, isEmpty,
          reason: 'no photograph means nothing to match against — PENDING, '
              'not FAIL');
    });

    test('neighbouring ring and pole-aligned targets qualify', () {
      const planner = StitchNeighborPlanner();
      // From target 1 (front): target 2 is 45° around the ring, target 9 is
      // the upper-ring frame straight above it — both share content.
      final planned = planner.plan(
        forTarget: specFor(1),
        allSpecs: specs,
        capturedIds: const <int>{2, 9},
      );
      expect(planned.map((PlannedNeighbor p) => p.targetId).toSet(), <int>{2, 9});
      expect(planned.every((PlannedNeighbor p) => (p.angleDeg - 45).abs() < 0.5),
          isTrue);
    });

    test('targets with no shared content are rejected', () {
      const planner = StitchNeighborPlanner();
      // Target 5 is the back of the sphere (180°); the zenith is 90° up.
      // Neither shares content with a middle-ring frame at a 53.7° hfov.
      final planned = planner.plan(
        forTarget: specFor(1),
        allSpecs: specs,
        capturedIds: const <int>{5, 25},
      );
      expect(planned, isEmpty);
    });

    test('the zenith plans against the upper ring, not the middle or nadir',
        () {
      const planner = StitchNeighborPlanner();
      final planned = planner.plan(
        forTarget: specFor(25),
        allSpecs: specs,
        capturedIds: const <int>{9, 12, 16, 1, 26},
      );
      final ids = planned.map((PlannedNeighbor p) => p.targetId).toSet();
      expect(ids, <int>{9, 12, 16},
          reason: 'upper ring is 45° below the zenith; the middle ring is '
              '90° and the nadir 180°');
      expect(ids.contains(26), isFalse);
    });

    test('candidates are nearest-first and capped at three', () {
      const planner = StitchNeighborPlanner();
      // From the zenith, the whole upper ring qualifies (8 candidates at
      // 45°) — the cap must cut them to three, in spec order among equals.
      final planned = planner.plan(
        forTarget: specFor(25),
        allSpecs: specs,
        capturedIds: <int>{for (var i = 9; i <= 16; i++) i},
      );
      expect(planned.length, 3);
      expect(
        planned.map((PlannedNeighbor p) => p.targetId),
        <int>[9, 10, 11],
      );
      for (final PlannedNeighbor p in planned) {
        expect(p.angleDeg, closeTo(45, 0.5));
      }
    });

    test('planned ids are a subset of captured ids', () {
      const planner = StitchNeighborPlanner();
      final planned = planner.plan(
        forTarget: specFor(5),
        allSpecs: specs,
        capturedIds: const <int>{4, 6, 13, 21},
      );
      expect(planned, isNotEmpty);
      for (final PlannedNeighbor p in planned) {
        expect(<int>{4, 6, 13, 21}.contains(p.targetId), isTrue,
            reason: 'the planner must never hand the worker a target whose '
                'photograph was not saved');
      }
    });
  });
}
