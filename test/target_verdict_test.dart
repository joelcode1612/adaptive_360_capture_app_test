import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_target.dart';
import 'package:adaptive_360_capture_app/features/capture/presentation/widgets/target_verdict.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

void main() {
  CaptureTarget target({
    int id = 9,
    CaptureTargetStatus status = CaptureTargetStatus.pending,
    String? anchorId,
    Vec3? anchorPos,
    String? imagePath,
    String? message,
  }) => CaptureTarget(
    targetId: id,
    stationId: 's1',
    yawDegrees: 0,
    pitchDegrees: 0,
    stationLocalDirection: Vec3.unitZ,
    status: status,
    anchorIdentifier: anchorId,
    anchorWorldPosition: anchorPos,
    imagePath: imagePath,
    message: message,
  );

  final anchored = target(
    anchorId: 'shared-station-anchor',
    anchorPos: const Vec3(0, 0, 3),
  );

  group('markerless target readiness', () {
    test('a placed target is actionable without any surface probe', () {
      final result = targetVerdict(anchored, referenceAvailable: true);
      expect(result.verdict, TargetVerdict.ready);
      expect(result.verdict.isActionable, isTrue);
      expect(result.detail, contains('station-local target geometry'));
    });

    test('the selected target remains active with the shared reference', () {
      final result = targetVerdict(
        target(
          status: CaptureTargetStatus.active,
          anchorId: 'shared-station-anchor',
          anchorPos: const Vec3(0, 0, 3),
        ),
        referenceAvailable: true,
      );
      expect(result.verdict, TargetVerdict.active);
      expect(result.verdict.isActionable, isTrue);
    });

    test(
      'reference loss blocks remaining targets without losing their IDs',
      () {
        final result = targetVerdict(anchored, referenceAvailable: false);
        expect(result.verdict, TargetVerdict.referenceLost);
        expect(result.verdict.isActionable, isFalse);
        expect(result.detail, contains('verified shared station reference'));
        expect(anchored.targetId, 9);
      },
    );

    test('a missing placement is never advertised as ready', () {
      final result = targetVerdict(target(), referenceAvailable: true);
      expect(result.verdict, TargetVerdict.referenceLost);
      expect(result.verdict.isActionable, isFalse);
    });
  });

  group('saved and failed captures', () {
    test('a captured target names its saved photograph', () {
      final result = targetVerdict(
        target(
          status: CaptureTargetStatus.captured,
          imagePath: '/data/user/0/app/capture/s1/frames/t09.jpg',
        ),
        referenceAvailable: false,
      );
      expect(result.verdict, TargetVerdict.saved);
      expect(result.detail, 'photo t09.jpg');
    });

    test('a failed attempt carries its actual recorded reason', () {
      final result = targetVerdict(
        target(status: CaptureTargetStatus.failed, message: 'Disk full.'),
        referenceAvailable: true,
      );
      expect(result.verdict, TargetVerdict.failed);
      expect(result.detail, 'Disk full.');
    });

    test('only placed active/ready targets are actionable', () {
      expect(TargetVerdict.saved.isActionable, isFalse);
      expect(TargetVerdict.failed.isActionable, isFalse);
      expect(TargetVerdict.referenceLost.isActionable, isFalse);
      expect(TargetVerdict.ready.isActionable, isTrue);
      expect(TargetVerdict.active.isActionable, isTrue);
    });
  });
}
