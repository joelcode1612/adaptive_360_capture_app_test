import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/capture/application/capture_state.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/motion/shot_phase.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_station.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_target.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/alignment_calculator.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/station_frame.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';

import 'capture_flow_test.dart' show bootHarness, calibratedHarness, Harness;
import 'capture_targets_test.dart' show orientationFor;

/// World-space target placement: the brief's §8, §9 and §11 requirements as
/// tests.
///
/// The bug this suite guards against is the original one — a target that
/// followed the camera or was placed wherever a raycast happened to hit. These
/// tests assert the opposite on every axis that matters: the position is
/// `station + radius × direction`, it survives the user walking away, and no
/// amount of missing surfaces stops it.
void main() {
  /// A state that satisfies every gate except the one under test. Shared by
  /// the "no surfaces" group and the station-drift group, because both are
  /// about a *single* condition standing between a ready state and the
  /// shutter — the assertion that matters is that the reason names it and
  /// nothing else changes.
  CaptureState readyState({int planesTracked = 0, double driftM = 0}) =>
      CaptureState(
        geometry: const CaptureGeometryConfig(),
        phase: CapturePhase.capturing,
        textureId: 1,
        tracking: TrackingState.tracking,
        measurementFresh: true,
        driftM: driftM,
        station: CaptureStation(
          stationId: 's1',
          referencePosition: Vec3.zero,
          referenceOrientation: Quat.identity,
          createdAt: DateTime.utc(2026, 1, 1),
          trackingStatus: TrackingState.tracking,
        ),
        targets: const <CaptureTarget>[
          CaptureTarget(
            targetId: 1,
            stationId: 's1',
            yawDegrees: 0,
            pitchDegrees: 45,
            stationLocalDirection: Vec3.unitZ,
            anchorIdentifier: 'a1',
            anchorWorldPosition: Vec3.zero,
            anchorSurfaceType: 'WORLD',
          ),
        ],
        activeTargetId: 1,
        activeAnchored: true,
        activeAnchorTracking: true,
        activeSurfaceType: 'WORLD',
        alignment: const AlignmentResult(
          directionWorld: Vec3.unitZ,
          directionInCamera: Vec3.unitZ,
          distanceM: 1.5,
          yawCorrectionDeg: 0,
          pitchCorrectionDeg: 0,
          angularErrorDeg: 0,
          toleranceDeg: 3,
        ),
        stable: true,
        // The aim has been inside the strict cone for the whole capture hold.
        // Without it the state is "still centring", which is a different gate
        // from the one any test in this group is about.
        alignedHeldMs: const CaptureGeometryConfig()
            .stabilityWindow
            .inMilliseconds
            .toDouble(),
        planesTracked: planesTracked,
        planeCount: planesTracked,
        // The controller latches the warning when the raw distance crosses the
        // limit, and the visible sentence reads the latch rather than the raw
        // number. A fixture that set only `driftM` would model a state the
        // controller never publishes.
        stationDriftWarningActive:
            driftM > const CaptureGeometryConfig().stationDriftWarningM,
      );

  group('the placed position', () {
    test(
      'is station + radius × direction for a station at the origin',
      () async {
        final harness = await calibratedHarness();
        final target = harness.controller.state.targets.first;
        final station = harness.controller.state.station!;
        final radius = const CaptureGeometryConfig().targetRadiusM;
        final spec = buildCaptureSphere().first;

        // The persisted station carries the calibrated pose; the frame is the
        // same pose in the placement maths' own type.
        final frame = StationFrame(
          origin: station.referencePosition,
          orientation: station.referenceOrientation,
        );
        final expected =
            frame.origin +
            frame.localToWorld(spec.direction).normalized * radius;
        expect(target.anchorWorldPosition, isNotNull);
        expect(target.anchorWorldPosition!.x, closeTo(expected.x, 1e-9));
        expect(target.anchorWorldPosition!.y, closeTo(expected.y, 1e-9));
        expect(target.anchorWorldPosition!.z, closeTo(expected.z, 1e-9));
      },
    );

    test('uses the station\u2019s own axes, not the world axes', () async {
      // A station calibrated facing world +X, standing a metre up. If placement
      // used the world axes (or the camera pose) instead of the station frame,
      // target 1 would land straight ahead along world +Z.
      final harness = await bootHarness();
      await harness.emit(
        position: const Vec3(0, 1, 0),
        orientation: orientationFor(const Vec3(1, 0, 0)),
      );
      await harness.controller.calibrateStation(stationId: 's-rot');
      await Harness.flush();

      final target = harness.controller.state.targets.first;
      final station = harness.controller.state.station!;
      final spec = buildCaptureSphere().first;
      final radius = const CaptureGeometryConfig().targetRadiusM;
      final frame = StationFrame(
        origin: station.referencePosition,
        orientation: station.referenceOrientation,
      );
      final expected =
          frame.origin + frame.localToWorld(spec.direction).normalized * radius;

      expect(target.anchorWorldPosition!.x, closeTo(expected.x, 1e-9));
      expect(target.anchorWorldPosition!.y, closeTo(expected.y, 1e-9));
      expect(target.anchorWorldPosition!.z, closeTo(expected.z, 1e-9));
      // The world-axes answer would put it a metre off; anything but the
      // station-frame answer is visible here.
      expect(target.anchorWorldPosition!.x, greaterThan(0.5));
    });
  });

  group('the target stays put', () {
    test('walking away and turning does not move or re-create it', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);
      await Harness.flush();

      final placed =
          harness.controller.state.targets.first.anchorWorldPosition!;
      final anchorId = harness.controller.state.targets.first.anchorIdentifier;
      final creations = harness.gateway.anchorCreations;
      final refreshes = harness.gateway.refreshCalls;

      // Walk three metres to the side, turn around, and then look back.
      await harness.emit(
        position: const Vec3(3, 1.5, -2),
        orientation: orientationFor(const Vec3(0, 0, -1)),
      );
      await Harness.flush();

      final target = harness.controller.state.targets.first;
      expect(
        target.anchorWorldPosition,
        placed,
        reason:
            'the anchor pose is ARCore\u2019s, never re-derived from the camera',
      );
      expect(target.anchorIdentifier, anchorId);
      expect(
        harness.gateway.anchorCreations,
        creations,
        reason: 'placement is not recomputed per frame',
      );
      // Refreshes are allowed — ARCore refines an anchor in place — but they
      // may not invent a new one.
      expect(harness.gateway.refreshCalls, greaterThanOrEqualTo(refreshes));
      expect(harness.gateway.anchorCreations, creations);
    });
  });

  group('readiness does not depend on surfaces', () {
    test('zero planes, everything else ready → the shutter is live', () {
      final state = readyState();
      expect(state.planesTracked, 0);
      expect(state.readyToCapture, isTrue);
      expect(state.captureBlockReason, isNull);
    });

    test('the block reason never names a plane or a surface', () {
      for (final state in <CaptureState>[
        readyState(),
        readyState().copyWith(activeAnchored: false),
        readyState().copyWith(tracking: TrackingState.paused),
        readyState().copyWith(clearStation: true),
      ]) {
        final reason = state.captureBlockReason;
        if (reason == null) continue;
        expect(reason.toLowerCase(), isNot(contains('plane')));
        expect(reason.toLowerCase(), isNot(contains('surface')));
        expect(reason.toLowerCase(), isNot(contains('wall')));
      }
    });
  });

  // ── the invisible-marker regression ────────────────────────────────────
  //
  // The bug: the arrow aimed at the stored anchor position (always correct)
  // while the native renderer refused to draw the marker because ARCore had
  // not tracked the anchor yet — and Dart never read the tracking state it was
  // already being sent. A placed-but-untracked anchor must read as "waiting",
  // never as drawn.
  group('anchor tracking decides whether the marker is drawn', () {
    /// One pose with the injected clock a refresh-interval further on, so
    /// `_refreshAnchorIfDue` fires exactly once per call — then the pose that
    /// carries its answer.
    ///
    /// The second pose is not padding. The refresh is asynchronous, and the
    /// native host attaches the anchor's pose to a frame as it is *delivered*:
    /// the frame that triggered the refresh was already built from the previous
    /// answer. A test that asserted on the triggering frame would be reading
    /// the state ARCore reported half a second ago.
    Future<void> refresh(Harness harness) async {
      harness.now = harness.now.add(const Duration(milliseconds: 600));
      await harness.emit();
      await Harness.flush();
      await harness.emit();
    }

    test(
      'a placed-but-paused anchor is a wait, not an anchored target',
      () async {
        // Calibration demands a *tracked* shared station anchor, so the pause
        // arrives afterwards — which is what the device does anyway: ARCore
        // pauses a world anchor when its own tracking degrades, and resumes it
        // by itself.
        final harness = await calibratedHarness();
        await harness.controller.selectTarget(1);
        await Harness.flush();
        harness.gateway.anchorTracking = TrackingState.paused;
        await refresh(harness);

        // Placed: the position exists and the arrow can use it.
        expect(harness.controller.state.activeAnchored, isTrue);
        // Not tracked: the UI says "waiting" instead of claiming the marker is
        // authoritative, and the native scene is withdrawn entirely. A dimmed
        // marker would still be drawn from `anchor.pose` every AR frame, so it
        // could visibly slide while guidance and capture were correctly
        // blocked. Every placement, the station frame and the target rows are
        // retained — only the drawing stops.
        expect(harness.controller.state.activeAnchorTracking, isFalse);
        expect(
          harness.gateway.lastScene,
          isEmpty,
          reason: 'an untracked anchor is not drawn at all, not dimmed',
        );
        expect(
          harness.controller.state.activeTarget!.anchorWorldPosition,
          isNotNull,
          reason: 'the placement survives the pause',
        );
        expect(
          harness.controller.state.message,
          'Waiting for AR to stabilise the target…',
        );
        expect(
          harness.controller.state.instruction,
          'Waiting for AR to stabilise the target…',
        );
        expect(harness.controller.state.readyToCapture, isFalse);
        expect(
          harness.controller.state.captureBlockReason,
          contains('stabilise'),
        );
      },
    );

    test(
      'tracking arriving later clears the wait and arms the shutter',
      () async {
        final harness = await calibratedHarness();
        await harness.controller.selectTarget(1);
        await Harness.flush();
        harness.gateway.anchorTracking = TrackingState.paused;
        await refresh(harness);
        expect(harness.controller.state.activeAnchorTracking, isFalse);

        // ARCore catches up.
        harness.gateway.anchorTracking = TrackingState.tracking;
        await refresh(harness);

        expect(harness.controller.state.activeAnchorTracking, isTrue);
        expect(harness.controller.state.message, isNull);
        // Aimed and steady, the hold now earns a photograph through the real
        // gate — which is the only "armed" the automatic product has.
        await harness.holdForAutomaticShutter();
        expect(harness.controller.state.capturedCount, 1);
      },
    );

    test('a per-pose pause blocks the shutter on that very pose', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);
      await Harness.flush();
      // A short hold: long enough to be aimed and tracked, short enough that
      // the automatic shutter has not yet earned the photograph. The pose
      // event below is the subject, not the shot.
      await harness.emitStable(count: 5);
      expect(harness.controller.state.activeAnchorTracking, isTrue);
      final station = harness.controller.state.station!;
      // All 26 nodes hang off ONE station anchor, so the pose reported here is
      // the station's, not the selected node's.
      final anchorAt = station.referencePosition;

      // ARCore pauses the anchor between two 2 Hz refreshes. The gate must
      // follow the pose event, not the refresh: otherwise the shutter stays
      // armed for up to half a second on a pose ARCore does not trust.
      await harness.emit(
        activeAnchorPose: (
          orientation: Quat.identity,
          position: anchorAt,
          tracking: TrackingState.paused,
        ),
      );
      expect(harness.controller.state.activeAnchored, isTrue);
      expect(harness.controller.state.activeAnchorTracking, isFalse);
      expect(harness.controller.state.readyToCapture, isFalse);
      // The same pose withdraws the marker: an untrusted anchor pose is not
      // drawn, so it cannot slide across the screen while capture is blocked.
      expect(harness.gateway.lastScene, isEmpty);
      // Losing the shared station anchor is a continuity boundary, so the line
      // names the verification rather than an ordinary target wait.
      expect(harness.controller.state.trackingRecovering, isTrue);
      expect(
        harness.controller.state.instruction,
        'Verifying the station reference — keep the phone at the station.',
      );
      expect(
        harness.controller.state.captureBlockReason,
        contains('Verifying the station reference'),
      );

      // And the very next pose that reports tracking restores the anchor's
      // authority; the shutter then re-arms through a fresh verified hold.
      await harness.emit(
        activeAnchorPose: (
          orientation: Quat.identity,
          position: anchorAt,
          tracking: TrackingState.tracking,
        ),
      );
      expect(harness.controller.state.activeAnchorTracking, isTrue);
      await harness.holdForAutomaticShutter(count: 40);
      expect(harness.controller.state.capturedCount, 1);
    });

    test('a camera pause hides the target and revokes its authority', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);
      await Harness.flush();
      // Deliberately short of the 600 ms window: this test is about a pause,
      // and a full hold here would spend the target on a photograph.
      await harness.emitStable(count: 5);

      final placed =
          harness.controller.state.activeTarget!.anchorWorldPosition!;
      final anchorId = harness.controller.state.activeTarget!.anchorIdentifier!;
      final station = harness.controller.state.station!;
      final positions = <int, Vec3?>{
        for (final target in harness.controller.state.targets)
          target.targetId: target.anchorWorldPosition,
      };
      final creations = harness.gateway.anchorCreations;
      expect(harness.gateway.lastScene, isNotEmpty);

      // The field recording's frame: ARCore loses the camera pose on a
      // featureless wall while still reporting the world anchor as tracked.
      // The anchor is fine, but the view is a last-known estimate — the
      // marker may not keep claiming to be authoritative through it. The
      // shared anchor sits at the station origin; every node is an offset on
      // it, so the reported pose is the station's, not this node's.
      await harness.emit(
        tracking: TrackingState.paused,
        activeAnchorPose: (
          orientation: Quat.identity,
          position: station.referencePosition,
          tracking: TrackingState.tracking,
        ),
      );

      final paused = harness.controller.state;
      // The anchor's own report is not carried through a camera tracking
      // break. ARCore can rebase its world origin across the gap, so the
      // station reference has to be verified again before any marker may
      // claim to be authoritative — even though the anchor itself never left
      // TRACKING.
      expect(paused.activeAnchorTracking, isFalse);
      expect(paused.trackingRecovering, isTrue);
      expect(paused.readyToCapture, isFalse);
      expect(paused.captureBlockReason, contains('AR tracking'));
      expect(
        harness.gateway.lastScene,
        isEmpty,
        reason:
            'a paused view has no live camera to draw into, so the scene is '
            'cleared rather than left claiming to be authoritative',
      );
      expect(
        harness.gateway.anchorCreations,
        creations,
        reason: 'a camera pause must not churn anchors',
      );
      expect(paused.activeTarget!.anchorWorldPosition, placed);
      expect(paused.activeTarget!.anchorIdentifier, anchorId);
      // A camera pause is not a recalibration: the station and the other 25
      // placed directions are frozen exactly where calibration put them.
      expect(paused.station!.referencePosition, station.referencePosition);
      expect(
        paused.station!.referenceOrientation,
        station.referenceOrientation,
      );
      expect(paused.targets.length, positions.length);
      for (final target in paused.targets) {
        expect(target.anchorWorldPosition, positions[target.targetId]);
      }

      // The shutter refuses while the view is paused, however long the pose
      // is held: the gate is re-evaluated on every frame.
      await harness.emitStable(tracking: TrackingState.paused);
      await Harness.flush();
      expect(harness.gateway.stillRequests, 0);
      expect(harness.controller.state.capturedCount, 0);
      expect(harness.controller.state.lastSavedPath, isNull);

      // Tracking returns: the scene comes back on that pose, and the shutter
      // re-arms only once the aim has been held through a verified window.
      await harness.emit();
      expect(harness.controller.state.activeAnchorTracking, isTrue);
      expect(harness.gateway.lastScene, isNotEmpty);
      await harness.holdForAutomaticShutter(count: 40);
      expect(harness.controller.state.capturedCount, 1);
    });

    test(
      'a tracked anchor aims from its live pose, a paused one aims from nothing',
      () async {
        final harness = await calibratedHarness();
        await harness.controller.selectTarget(1);
        await Harness.flush();
        final placed =
            harness.controller.state.activeTarget!.anchorWorldPosition!;
        final station = harness.controller.state.station!;
        // The shared anchor has been refined 5 cm sideways — the scale ARCore
        // really corrects by, and inside the 8 cm discontinuity threshold. Every
        // node rides on it, so the target the guidance should aim at slides by
        // the same offset: the reported pose is the *station's*, and the node is
        // its station-local offset away from it.
        const refinement = Vec3(0.05, 0, 0);
        final anchorMoved = station.referencePosition + refinement;
        final moved = placed + refinement;

        // Tracking: the live anchor pose is the position the renderer draws, so
        // it is the one the guidance aims at — not the frozen placement.
        await harness.emit(
          activeAnchorPose: (
            orientation: Quat.identity,
            position: anchorMoved,
            tracking: TrackingState.tracking,
          ),
        );
        final tracked = harness.controller.state.alignment!;
        final expectedTracked = moved.normalized;
        expect(tracked.directionWorld.x, closeTo(expectedTracked.x, 1e-9));
        expect(tracked.directionWorld.y, closeTo(expectedTracked.y, 1e-9));
        expect(tracked.directionWorld.z, closeTo(expectedTracked.z, 1e-9));
        expect(
          (tracked.directionWorld - placed.normalized).length,
          greaterThan(1e-3),
          reason: 'the refinement is visible in the aim, not merely stored',
        );

        // Paused: the anchor's last pose is stale. The frozen placement is kept
        // as the record of where calibration put the node, but it is not aimed
        // with — losing the shared reference is a continuity boundary, so the
        // arrow is withdrawn until the station is verified again.
        await harness.emit(
          activeAnchorPose: (
            orientation: Quat.identity,
            position: anchorMoved,
            tracking: TrackingState.paused,
          ),
        );
        final paused = harness.controller.state;
        expect(paused.alignment, isNull);
        expect(paused.trackingRecovering, isTrue);
        expect(paused.readyToCapture, isFalse);
        expect(paused.activeTarget!.anchorWorldPosition, placed);
      },
    );

    test(
      'a stale prior-anchor event cannot steer the selected target',
      () async {
        final harness = await calibratedHarness();
        await harness.controller.selectTarget(1);
        await Harness.flush();

        final active = harness.controller.state.activeTarget!;
        final placed = active.anchorWorldPosition!;
        final anchorId = active.anchorIdentifier!;
        final station = harness.controller.state.station!;
        // All 26 nodes ride on the one shared station anchor, so "the previous
        // target's anchor" is the same identifier. The report worth refusing is
        // one that names some *other* anchor — a native frame queued before
        // this station existed.
        const staleAnchorId = 'anchor-from-a-previous-station';
        final stalePosition = placed + const Vec3(0.75, 0, 0);

        await harness.emit(
          activeAnchorPose: (
            orientation: Quat.identity,
            position: stalePosition,
            tracking: TrackingState.tracking,
          ),
          reportedActiveAnchorId: staleAnchorId,
        );

        final state = harness.controller.state;
        expect(state.activeAnchorTracking, isFalse);
        expect(state.activeTarget!.anchorIdentifier, anchorId);
        expect(state.activeTarget!.anchorWorldPosition, placed);
        // A pose that cannot name the station anchor is not a measurement of
        // it. Guidance is withheld and the reference enters recovery rather
        // than being steered by a stranger's coordinate.
        expect(state.alignment, isNull);
        expect(state.trackingRecovering, isTrue);
        expect(state.readyToCapture, isFalse);

        // The real station anchor reporting again restores the aim, and it aims
        // from this station's geometry — not from the stale offset.
        await harness.emit(
          activeAnchorPose: (
            orientation: Quat.identity,
            position: station.referencePosition,
            tracking: TrackingState.tracking,
          ),
        );
        await harness.emitStable(count: 20);
        final restored = harness.controller.state.alignment!;
        final expected = placed.normalized;
        expect(restored.directionWorld.x, closeTo(expected.x, 1e-9));
        expect(restored.directionWorld.y, closeTo(expected.y, 1e-9));
        expect(restored.directionWorld.z, closeTo(expected.z, 1e-9));
      },
    );

    test('an anchor ARCore dropped invalidates the station reference', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);
      await Harness.flush();
      expect(harness.controller.state.activeAnchored, isTrue);
      final before = harness.gateway.anchorCreations;
      final photographs = harness.controller.state.capturedCount;

      // Tracking lost long enough that ARCore dropped the anchor. There is only
      // one: it *is* the station's spatial reference, so losing it cannot be
      // repaired by quietly re-placing a node at a remembered world coordinate.
      // The station has to be calibrated again against a fresh ARCore frame.
      final stationAnchorId =
          harness.controller.state.activeTarget!.anchorIdentifier!;
      harness.gateway.dropAnchor(stationAnchorId);
      await refresh(harness);
      await Harness.flush();

      final state = harness.controller.state;
      expect(
        harness.gateway.anchorCreations,
        before,
        reason: 'a dropped station anchor is not silently re-created',
      );
      expect(state.station?.stationId, 's1');
      expect(harness.controller.requiresReferenceReestablishment, isTrue);
      expect(state.targets, hasLength(kCaptureTargetCount));
      expect(state.readyToCapture, isFalse);
      expect(state.captureBlockReason, contains('AR tracking'));
      expect(state.capturedCount, photographs);
      expect(harness.gateway.raycastCalls, 0);

      // Verified re-establishment is the one honest repair, and it places
      // exactly one new shared anchor for all 26 nodes under the retained
      // logical station and target identities.
      await harness.controller.recalibrateAndContinue('s1');
      await Harness.flush();
      expect(harness.controller.state.station, isNotNull);
      expect(harness.gateway.anchorCreations, before + 1);
      expect(harness.controller.state.targets.length, kCaptureTargetCount);
    });

    test('a persistently paused anchor is waited on, not re-placed', () async {
      final harness = await calibratedHarness();
      harness.gateway.anchorTracking = TrackingState.paused;
      await harness.controller.selectTarget(1);
      await Harness.flush();
      final placed = harness.gateway.anchorCreations;

      // Many refresh periods with ARCore still reporting the anchor paused:
      // the policy is to wait, not to churn anchors or declare failure. A
      // world anchor that ARCore paused has not lost its position.
      for (var i = 0; i < 24; i++) {
        await refresh(harness);
      }

      expect(
        harness.gateway.anchorCreations,
        placed,
        reason: 'a paused anchor is still a placed anchor',
      );
      expect(harness.controller.state.activeAnchored, isTrue);
      expect(harness.controller.state.activeAnchorTracking, isFalse);
      expect(harness.controller.state.readyToCapture, isFalse);
      expect(
        harness.controller.state.message,
        'Waiting for AR to stabilise the target…',
      );

      // The wait ends when ARCore resumes tracking — no re-placement needed.
      harness.gateway.anchorTracking = TrackingState.tracking;
      await refresh(harness);
      expect(harness.controller.state.activeAnchorTracking, isTrue);
      expect(harness.controller.state.message, isNull);
    });

    test(
      'a paused refresh cannot unfreeze the placement or arm the shutter',
      () async {
        final harness = await calibratedHarness();
        await harness.controller.selectTarget(1);
        await Harness.flush();

        final placed =
            harness.controller.state.activeTarget!.anchorWorldPosition!;
        final anchorId =
            harness.controller.state.activeTarget!.anchorIdentifier!;
        final station = harness.controller.state.station!;
        final creations = harness.gateway.anchorCreations;
        // A refinement, not a relocation: 2 cm is the scale ARCore actually
        // corrects its map by. It is well inside the 8 cm discontinuity
        // threshold and the 20 cm station circle, so the only question this
        // test asks is *when* the pose may be adopted — not whether a half-metre
        // jump should be tolerated. It is still 40× the assertion tolerance, so
        // "adopted" and "not adopted" cannot be confused.
        const refinement = Vec3(0.02, 0, 0);

        // ARCore pauses the anchor, and its last-known pose sits 2 cm from where
        // this app placed the station. Two refresh periods — each longer than
        // the 500 ms interval — must not aim with that pose: a paused sample is
        // last-known geometry, not a measurement of the present.
        harness.gateway.anchorTracking = TrackingState.paused;
        harness.gateway.refinedAnchorPositions[anchorId] =
            station.referencePosition + refinement;
        await refresh(harness);
        await refresh(harness);

        final paused = harness.controller.state;
        expect(
          harness.gateway.refreshCalls,
          greaterThanOrEqualTo(2),
          reason: 'the interval elapsed; the refresh was not skipped',
        );
        expect(paused.activeTarget!.anchorIdentifier, anchorId);
        expect(
          paused.activeTarget!.anchorWorldPosition,
          placed,
          reason:
              'the placement is frozen at calibration; the renderer follows '
              'the anchor, not this number',
        );
        expect(paused.activeAnchorTracking, isFalse);
        // The guidance aims at the frozen placement, not at the paused pose.
        final aim = paused.alignment!.directionWorld;
        final expectedAim = placed.normalized;
        expect(aim.x, closeTo(expectedAim.x, 1e-9));
        expect(aim.y, closeTo(expectedAim.y, 1e-9));
        expect(aim.z, closeTo(expectedAim.z, 1e-9));
        expect(paused.readyToCapture, isFalse);
        expect(
          harness.gateway.anchorCreations,
          creations,
          reason: 'waiting on a paused anchor must not churn anchors',
        );

        // A full stable window aimed at the frozen placement is still not
        // evidence that ARCore holds the anchor, and the shutter refuses.
        await harness.emitStable(count: 20);
        expect(harness.controller.state.activeAnchorTracking, isFalse);
        expect(harness.controller.state.readyToCapture, isFalse);
        await Harness.flush();
        expect(harness.gateway.stillRequests, 0);
        expect(harness.controller.state.capturedCount, 0);

        // Tracking returns. The frozen placement is *still* the placement — it
        // is a record of where calibration put the node — but the guidance now
        // aims at the refined live station, which is what the renderer draws.
        // The hold is deliberately short of the window: the aim is the subject
        // here, and a full hold would spend the target on a photograph.
        harness.gateway.anchorTracking = TrackingState.tracking;
        await refresh(harness);
        await harness.emitStable(count: 5);
        final resumed = harness.controller.state;
        expect(resumed.activeAnchorTracking, isTrue);
        expect(resumed.activeTarget!.anchorWorldPosition, placed);
        final refinedAim = resumed.alignment!.directionWorld;
        final expectedRefined = (placed + refinement).normalized;
        expect(refinedAim.x, closeTo(expectedRefined.x, 1e-9));
        expect(refinedAim.y, closeTo(expectedRefined.y, 1e-9));
        expect(refinedAim.z, closeTo(expectedRefined.z, 1e-9));
        // And with the anchor tracked again, the same hold now earns a
        // photograph through the real gate.
        await harness.holdForAutomaticShutter();
        expect(harness.controller.state.capturedCount, 1);
      },
    );

    test(
      'a pose without the active anchor invalidates the tracking gate',
      () async {
        final harness = await calibratedHarness();
        await harness.controller.selectTarget(1);
        await Harness.flush();
        final placed =
            harness.controller.state.activeTarget!.anchorWorldPosition!;
        final aim = facingRotation(placed.normalized);

        await harness.emitStable(count: 5);
        expect(harness.controller.state.activeAnchorTracking, isTrue);

        // The camera pose is tracked and still aimed at the target; only the
        // active-anchor report is missing. The earlier "tracking" answer does
        // not describe this event, so it may not be carried forward.
        await harness.emit(orientation: aim, includeActiveAnchorPose: false);

        final state = harness.controller.state;
        expect(
          state.activeAnchorTracking,
          isFalse,
          reason: 'a pose that cannot name the anchor cannot confirm it',
        );
        expect(state.readyToCapture, isFalse);
        // The station anchor is the shared reference for all 26 nodes, so a
        // frame that cannot name it is a recovery boundary: guidance is
        // withheld rather than drawn from a remembered coordinate.
        expect(state.alignment, isNull);
        expect(state.trackingRecovering, isTrue);
        expect(state.captureBlockReason, contains('station reference'));
        expect(state.activeTarget!.anchorWorldPosition, placed);

        // And the shutter refuses on this state, for as long as it is held.
        await harness.emitStable(includeActiveAnchorPose: false, count: 20);
        await Harness.flush();
        expect(harness.gateway.stillRequests, 0);
        expect(harness.controller.state.capturedCount, 0);
        expect(harness.controller.state.lastSavedPath, isNull);

        // The next pose that names a tracked anchor re-arms the gate, and the
        // hold then earns a photograph. The budget covers both holds the
        // recovery requires: 600 ms proving station continuity, then a fresh
        // 600 ms capture window.
        await harness.holdForAutomaticShutter(count: 40);
        expect(harness.controller.state.capturedCount, 1);
        // The photograph is the proof the gate re-armed: the shutter reads
        // `activeAnchorTracking` itself, and a completion clears the active
        // target afterwards, so the flag is not re-asserted here.
        expect(
          harness.controller.state.targets[0].status,
          CaptureTargetStatus.captured,
        );
      },
    );
  });

  // ── the station-drift gate ───────────────────────────────────────────
  //
  // The defect: `driftM` was measured, displayed ("drift 0.20 m") and then
  // ignored — nothing in `captureBlockReason` read it, so a phone standing
  // five metres from the station, aimed and steady, saved a photograph
  // composed from the wrong place. The stability monitor already catches the
  // *walk* (position drift across its window); only this gate catches
  // *standing still in the wrong place*, which is the common case.
  group('walking away from the station', () {
    test('a drifted phone is blocked, and the sentence names the way back', () {
      final state = readyState(driftM: 5.0);
      expect(state.stationDrifted, isTrue);
      expect(state.readyToCapture, isFalse);
      final reason = state.captureBlockReason;
      expect(reason, isNotNull);
      expect(reason, contains('station'));
      expect(reason, contains('20 cm'));
      // The always-visible instruction names exactly one action: return to the
      // spot the 26 targets were built around. It deliberately does not offer
      // recalibration here — that would move the station to wherever the phone
      // happens to be, silently redefining the capture geometry instead of
      // correcting the drift.
      expect(state.instruction, 'Too far from station — return within 20 cm.');
    });

    test(
      'right on the drift limit the shutter stays live, just past it does not',
      () {
        // Ordinary shuffling is not a relocation; the limit is the spec's
        // `Δd ≤ 0.20 m` **inclusive** gate, and the comparison is a strict `>` so
        // standing exactly on the boundary still captures.
        expect(readyState(driftM: 0.0).stationDrifted, isFalse);
        expect(readyState(driftM: 0.20).stationDrifted, isFalse);
        expect(readyState(driftM: 0.20).readyToCapture, isTrue);
        expect(readyState(driftM: 0.2001).stationDrifted, isTrue);
      },
    );

    test('the phase is not "Ready" while the shutter is drift-blocked', () {
      // A green "Ready" chip above a disabled button is the false positive
      // the shot-phase machine exists to prevent.
      final state = readyState(driftM: 2.0);
      expect(state.shotPhase, ShotPhase.align);
      expect(state.shotPhase.isReady, isFalse);
      expect(state.shotPhase.showsAligned, isFalse);
    });

    test(
      'the auto shutter does not fire while the user stands far away',
      () async {
        // The regression, end to end: aimed and steady five metres out, both
        // `stable` and `withinTolerance` are true — and the auto path used to
        // save the photograph anyway, because it read neither the block reason
        // nor the drift.
        final harness = await calibratedHarness();
        await harness.emitStable(position: const Vec3(5, 0, 0));
        await Harness.flush();

        final state = harness.controller.state;
        expect(state.driftM, closeTo(5, 1e-9));
        expect(state.stationDrifted, isTrue);
        // The shot itself: no photograph may exist. Asserted before the
        // preconditions so that a regression here reads as "a photograph was
        // saved", which is the defect, rather than as a stability mystery.
        expect(state.capturedCount, 0);
        expect(state.lastSavedPath, isNull);
        // And the reason it is a real regression: the aim is green out there.
        // The motion hold is not — a drift excursion clears the window — so the
        // drift gate is asserted as the named reason, not as the only one.
        expect(state.alignment!.withinTolerance, isTrue);
        expect(state.captureBlockReason, contains('station'));
      },
    );

    test('the shutter refuses too, and the state says why', () async {
      final harness = await calibratedHarness();
      await harness.emitStable(position: const Vec3(5, 0, 0), count: 20);
      await Harness.flush();

      final state = harness.controller.state;
      expect(harness.gateway.stillRequests, 0);
      expect(state.capturedCount, 0);
      expect(state.lastSavedPath, isNull);
      expect(state.captureBlockReason, contains('station'));
    });

    test('walking back to the station re-arms the shutter', () async {
      final harness = await calibratedHarness();
      await harness.emitStable(position: const Vec3(5, 0, 0));
      expect(harness.controller.state.captureBlockReason, contains('station'));
      expect(harness.gateway.stillRequests, 0);

      // Back at the station the same hold now earns a photograph: the drift
      // excursion cleared the window, so this is a fresh 600 ms, not a
      // continuation of the hold that spanned the walk.
      await harness.holdForAutomaticShutter(position: Vec3.zero);
      expect(harness.controller.state.stationDrifted, isFalse);
      expect(harness.controller.state.capturedCount, 1);
    });
  });
}
