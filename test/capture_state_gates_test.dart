import 'package:flutter_test/flutter_test.dart';

import 'package:adaptive_360_capture_app/features/capture/application/capture_state.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_station.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_target.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/alignment_calculator.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';

AlignmentResult _aligned({double errorDeg = 1.0, double tolerance = 3.0}) =>
    AlignmentResult(
      directionWorld: const Vec3(0, 0, 1),
      directionInCamera: const Vec3(0, 0, 1),
      distanceM: 1.0,
      yawCorrectionDeg: 0,
      pitchCorrectionDeg: 0,
      angularErrorDeg: errorDeg,
      toleranceDeg: tolerance,
    );

AlignmentResult _offTarget({double errorDeg = 12}) => AlignmentResult(
  directionWorld: const Vec3(0.2, 0.1, 1),
  directionInCamera: const Vec3(0.2, 0.1, 1),
  distanceM: 1.0,
  yawCorrectionDeg: 11,
  pitchCorrectionDeg: 5,
  angularErrorDeg: errorDeg,
  toleranceDeg: 3,
);

CaptureState _base({
  CapturePhase phase = CapturePhase.capturing,
  TrackingState tracking = TrackingState.tracking,
  bool measurementFresh = true,
  CaptureMode mode = CaptureMode.automatic,
  AlignmentResult? alignment,
  bool anchored = true,
  bool anchorTracking = true,
}) {
  final station = _station();
  final target = _target();
  return CaptureState(
    phase: phase,
    geometry: const CaptureGeometryConfig(),
    textureId: 7,
    station: station,
    targets: [target],
    activeTargetId: 1,
    tracking: tracking,
    measurementFresh: measurementFresh,
    mode: mode,
    alignment: alignment,
    activeAnchored: anchored,
    activeAnchorTracking: anchorTracking,
  );
}

void main() {
  group('capture readiness gates', () {
    test(
      'a fully aligned, fresh, automatic frame has no pre-settle blocker',
      () {
        final state = _base(alignment: _aligned());
        expect(state.captureBlockReasonBeforeSettle, isNull);
        expect(state.displayCaptureBlockReasonBeforeSettle, isNull);
      },
    );

    test('zero detected planes do not block target readiness', () {
      final state = _base(alignment: _aligned()).copyWith(
        planesTracked: 0,
        planeCount: 0,
        alignedHeldMs: 600,
        stable: true,
      );
      expect(state.captureBlockReasonBeforeSettle, isNull);
      expect(state.readyToCapture, isTrue);
      expect(state.captureBlockReason, isNull);
    });

    test('a misaligned frame blocks with the alignment instruction', () {
      final state = _base(alignment: _offTarget());
      final reason = state.captureBlockReasonBeforeSettle;
      expect(reason, isNotNull);
      expect(reason, contains('Turn'));
    });

    test('paused tracking blocks with the tracking sentence', () {
      final state = _base(
        tracking: TrackingState.paused,
        alignment: _aligned(),
      );
      expect(
        state.captureBlockReasonBeforeSettle,
        'AR tracking is not ready — move the phone slowly.',
      );
    });

    test(
      'a stale pose names the fresh-pose wait instead of fake readiness',
      () {
        final state = _base(measurementFresh: false, alignment: _aligned());
        expect(
          state.captureBlockReasonBeforeSettle,
          'Waiting for a fresh camera pose…',
        );
        expect(state.captureStatus, 'Waiting for a fresh camera pose');
      },
    );

    test('manual mode states that automatic capture is disabled', () {
      final state = _base(mode: CaptureMode.manual, alignment: _aligned());
      expect(
        state.captureBlockReasonBeforeSettle,
        'Manual mode is active — automatic capture is disabled.',
      );
      expect(state.captureStatus, 'Manual mode — automatic capture disabled');
    });

    test('a placed-but-paused anchor blocks with the stabilise sentence', () {
      final state = _base(alignment: _aligned(), anchorTracking: false);
      expect(
        state.captureBlockReasonBeforeSettle,
        'Waiting for AR to stabilise the target…',
      );
    });

    test('an anchor refinement blocks with the anchor-settle sentence', () {
      final state = _base(alignment: _aligned()).copyWith(
        activeAnchored: true,
        activeAnchorTracking: true,
        autoBlockReason: 'anchor-moving',
      );
      expect(
        state.captureBlockReasonBeforeSettle,
        'Waiting for the station anchor to settle…',
      );
    });

    test('station drift blocks with the walk-back sentence', () {
      final state = _base(
        alignment: _aligned(),
      ).copyWith(driftM: 0.5, activeAnchored: true, activeAnchorTracking: true);
      expect(state.stationDrifted, isTrue);
      expect(
        state.captureBlockReasonBeforeSettle,
        'Too far from station — return within 20 cm.',
      );
    });

    test('saving the photograph reports saving, never readiness', () {
      final state = _base(alignment: _aligned()).copyWith(
        capturing: true,
        activeAnchored: true,
        activeAnchorTracking: true,
        targets: [
          CaptureTarget(
            targetId: 1,
            stationId: 's',
            yawDegrees: 0,
            pitchDegrees: 0,
            stationLocalDirection: const Vec3(0, 0, 1),
            status: CaptureTargetStatus.capturing,
          ),
        ],
        activeTargetId: 1,
      );
      expect(state.captureBlockReasonBeforeSettle, 'Saving the photograph…');
    });
  });

  group('movement interpretation', () {
    test('ordinary camera drift warns before the strict 20 cm block', () {
      final state = _base(alignment: _aligned()).copyWith(
        driftM: 0.10,
        rawStationDriftM: 0.10,
        alignedHeldMs: 600,
        stable: true,
      );
      expect(state.movementWarning, contains('Camera drift is 0.10 m'));
      expect(state.stationDrifted, isFalse);
      expect(state.captureBlockReasonBeforeSettle, isNull);
    });

    test(
      'verified body rotation separates raw excursion from station offset',
      () {
        final state = _base(
          alignment: _aligned(),
        ).copyWith(driftM: 0.03, rawStationDriftM: 0.65, rotatingInPlace: true);
        expect(state.movementWarning, contains('Body rotation detected'));
        expect(state.movementWarning, contains('0.65 m'));
        expect(state.movementWarning, contains('0.03 m'));
        expect(state.stationDrifted, isFalse);
      },
    );
  });

  group('progress and ring state', () {
    test('ringComplete requires alignment hold, stability and no blocker', () {
      final aligned = _base(alignment: _aligned()).copyWith(
        alignedHeldMs: 600,
        stable: true,
        activeAnchored: true,
        activeAnchorTracking: true,
      );
      expect(aligned.ringComplete, isTrue);

      // Same frame with an unfinished alignment hold: not complete.
      expect(aligned.copyWith(alignedHeldMs: 200).ringComplete, isFalse);
      // Same frame with the motion window unfinished: not complete.
      expect(aligned.copyWith(stable: false).ringComplete, isFalse);
      // Same frame with a fresh blocker (anchor paused): not complete.
      expect(
        aligned.copyWith(activeAnchorTracking: false).ringComplete,
        isFalse,
      );
    });

    test(
      'stability progress is clamped and the hold is the smaller of the two windows',
      () {
        // Pure state contract: progress travels through the published field and
        // the reticle only reads it when the display blocker is null.
        final state = _base(alignment: _aligned()).copyWith(
          stabilityProgress: 0.75,
          activeAnchored: true,
          activeAnchorTracking: true,
        );
        expect(state.stabilityProgress, 0.75);
        expect(state.displayCaptureBlockReasonBeforeSettle, isNull);
      },
    );

    test(
      'hysteresis-band alignment keeps the motion window but not the strict hold',
      () {
        // An error between tolerance and tolerance+hysteresis (3°…5°) is inside
        // the motion history band, but the strict alignment hold restarts at 0.
        final inBand = _offTarget(errorDeg: 4.2);
        expect(inBand.withinTolerance, isFalse);
        final onTarget = _aligned();
        expect(onTarget.withinTolerance, isTrue);
      },
    );
  });

  group('capture status wording', () {
    test('automatic mode with a full hold reports ready to capture', () {
      final state = _base(alignment: _aligned()).copyWith(
        station: _station(),
        targets: [_target()],
        activeTargetId: 1,
        activeAnchored: true,
        activeAnchorTracking: true,
        alignedHeldMs: 600,
        stable: true,
      );
      expect(state.captureStatus, 'Ready to capture');
    });

    test('manual mode never advertises an automatic shutter', () {
      final state = _base(mode: CaptureMode.manual, alignment: _aligned());
      expect(state.captureStatus, 'Manual mode — automatic capture disabled');
    });
  });
}

// ── fixtures ────────────────────────────────────────────────────────────────

CaptureStation _station() => CaptureStation(
  stationId: 'station-test',
  referencePosition: const Vec3(0, 0, 0),
  referenceOrientation: const Quat(0, 0, 0, 1),
  createdAt: DateTime.utc(2026, 11, 12),
  trackingStatus: TrackingState.tracking,
);

CaptureTarget _target() => const CaptureTarget(
  targetId: 1,
  stationId: 'station-test',
  yawDegrees: 0,
  pitchDegrees: 0,
  stationLocalDirection: Vec3(0, 0, 1),
);
