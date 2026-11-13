import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_360_capture_app/features/capture/application/capture_controller.dart';
import 'package:adaptive_360_capture_app/features/capture/application/capture_state.dart';
import 'package:adaptive_360_capture_app/features/capture/data/services/ar_session_service.dart';
import 'package:adaptive_360_capture_app/features/capture/data/services/photo_capture_service.dart';
import 'package:adaptive_360_capture_app/features/capture/data/services/plane_anchor_service.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_target.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/alignment_calculator.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/station_frame.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/target_sphere.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/arcore_ar.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';

import 'capture_test_fakes.dart';
import 'capture_targets_test.dart' show orientationFor;

/// A plausible JPEG: long enough to pass the sanity floor. It is not a real
/// image — what these tests care about is that it is written and read back byte
/// for byte.
final Uint8List fakeJpeg = Uint8List.fromList(
  List<int>.generate(8192, (int i) => (i * 31) & 0xFF),
);

class Harness {
  Harness(this.gateway, this.repository, this.controller);

  final FakeArGateway gateway;
  final FakeCaptureRepository repository;
  final CaptureController controller;

  /// The injected clock. The stability window is measured against this, so a
  /// test can walk through 500 ms without waiting for 500 ms.
  DateTime now = DateTime.utc(2026, 1, 1);

  /// Lets queued stream events and the async capture they trigger run.
  ///
  /// The pose stream is a broadcast stream and the shutter writes a real file,
  /// so a test has to yield to the event loop — and to real IO — before it can
  /// assert on the outcome of a capture.
  static Future<void> flush() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Waits until [condition] holds, giving up after [attempts] flushes.
  ///
  /// The budget is deliberately generous (200 × 20 ms): this machine runs the
  /// 26-frame loop with a Gradle build queued behind it, and a 1.2 s bound was
  /// observed to expire on a merely busy machine. A real regression never
  /// satisfies the condition and still fails — later, not silently.
  ///
  /// The shutter writes a real file and verifies it by reading it back, so
  /// "captured" lands on the event loop, not synchronously with the press. A
  /// fixed flush is enough on an idle machine and not enough on a loaded one;
  /// this keeps the assertion about the outcome rather than about the machine,
  /// and it is bounded so a real regression still fails rather than hangs.
  static Future<void> waitFor(
    bool Function() condition, {
    int attempts = 200,
  }) async {
    for (var i = 0; i < attempts; i++) {
      if (condition()) return;
      await flush();
    }
  }

  /// Emits one pose, advancing the clock by [advance] first.
  ///
  /// **The advance models the pose stream, not convenience.** A real device
  /// delivers poses at 30–60 Hz, each stamped with its own `frame.timestamp`, so
  /// two consecutive poses never share a timestamp. The engine's stability gate
  /// reads those stamps, and a non-increasing one is refused as a duplicate or
  /// out-of-order arrival *and clears the hold* — so a fake that stamped every
  /// pose with one frozen clock value could never elapse the 600 ms window, and
  /// "the shutter re-arms on the next tracked pose" would fail for a reason the
  /// device never sees. 16 ms is one frame at 60 Hz.
  Future<void> emit({
    Vec3 position = Vec3.zero,
    Quat orientation = Quat.identity,
    TrackingState tracking = TrackingState.tracking,
    int planesTracked = 3,
    ({Vec3 position, Quat orientation, TrackingState tracking})?
    activeAnchorPose,
    String? reportedActiveAnchorId,
    bool includeActiveAnchorPose = true,
    Duration advance = const Duration(milliseconds: 16),
  }) async {
    now = now.add(advance);
    gateway.emitPose(
      position: position,
      worldOrientation: orientation,
      tracking: tracking,
      planesTracked: planesTracked,
      activeAnchorPose: activeAnchorPose,
      reportedActiveAnchorId: reportedActiveAnchorId,
      includeActiveAnchorPose: includeActiveAnchorPose,
    );
    await flush();
  }

  /// Emits [count] identical poses spread over the window, so the stability gate
  /// can elapse without the test waiting for it.
  ///
  /// **The default pose aims at the active target's placed world position.**
  /// World-space placement gives every target its own position, so a single
  /// fixed pose is only aligned with the target that happens to sit straight
  /// ahead — the old fake put every anchor at one raycast hit, which is why an
  /// identity pose used to work for all 26. A test that wants a deliberately
  /// misaligned pose still passes [orientation] explicitly.
  Future<void> emitStable({
    Vec3? position,
    Quat? orientation,
    int count = 14,
    Duration step = const Duration(milliseconds: 60),
    TrackingState tracking = TrackingState.tracking,
    int planesTracked = 3,
    bool includeActiveAnchorPose = true,
  }) async {
    final at = position ?? Vec3.zero;
    final aim = orientation ?? _aimAtActiveTarget(from: at);
    for (var i = 0; i < count; i++) {
      await emit(
        position: at,
        orientation: aim,
        tracking: tracking,
        planesTracked: planesTracked,
        includeActiveAnchorPose: includeActiveAnchorPose,
        advance: step,
      );
    }
  }

  /// Holds an aimed, steady pose until the automatic shutter fires, then waits
  /// for its transaction to settle.
  ///
  /// This is what a manual press used to mean. The product has only one shutter
  /// now — the automatic gate — so a test that wants a photograph has to earn it
  /// the same way the operator does: hold the pose past the stability window and
  /// let the gate decide. The wait is bounded, so a gate that never arms fails
  /// the assertion instead of hanging.
  Future<void> holdForAutomaticShutter({
    Vec3? position,
    Quat? orientation,
    TrackingState tracking = TrackingState.tracking,
    int count = 20,
  }) async {
    final before = gateway.stillRequests;
    await emitStable(
      position: position,
      orientation: orientation,
      tracking: tracking,
      count: count,
    );
    await waitFor(
      () => gateway.stillRequests > before && !controller.state.capturing,
    );
    await flush();
  }

  /// Emits aimed poses one frame at a time until the automatic shutter fires,
  /// then stops — and pins the still to the pose that armed it.
  ///
  /// [emitStable] cannot be used while a photograph is held in flight: it keeps
  /// emitting after the armed frame, so the still comes back stamped with a
  /// later pose than the one that armed the shutter, and the save correctly
  /// refuses a photograph older than its 250 ms freshness limit. Stopping on the
  /// armed frame and returning exactly that pose is what a real camera does —
  /// it hands back the frame it was asked to capture, however long its pipeline
  /// takes.
  Future<void> emitUntilShutterArms() async {
    final before = gateway.stillRequests;
    for (var frames = 0; frames < 40; frames++) {
      await emit(advance: const Duration(milliseconds: 60));
      if (gateway.stillRequests > before) {
        gateway.stillPose = gateway.lastEmittedPose;
        return;
      }
    }
    throw StateError('the automatic shutter never armed');
  }

  /// The camera orientation that looks from [from] at the active target's
  /// anchored world position. Identity when no target is placed.
  Quat _aimAtActiveTarget({required Vec3 from}) {
    final world = controller.state.activeTarget?.anchorWorldPosition;
    if (world == null) return Quat.identity;
    return facingRotation((world - from).normalized);
  }
}

Future<Harness> bootHarness({
  ArRaycastHit? hit,
  bool surfaceFound = true,
  Uint8List? stillBytes,
  Object? stillError,
  bool hostPresent = true,
  bool autoAdvance = false,
  Object? recordError,
  bool reusedSession = false,
}) async {
  final gateway = FakeArGateway(
    hit: hit,
    surfaceFound: surfaceFound,
    stillBytes: stillBytes ?? fakeJpeg,
    stillError: stillError,
    hostPresent: hostPresent,
  )..reusedSession = reusedSession;
  final repository = FakeCaptureRepository()..recordError = recordError;
  final session = ArSessionService(gateway);
  const geometry = CaptureGeometryConfig();
  final anchors = PlaneAnchorService(gateway, geometry: geometry);
  final photos = PhotoCaptureService(host: gateway, repository: repository);

  Harness? harness;
  final controller = CaptureController(
    session: session,
    anchors: anchors,
    photos: photos,
    repository: repository,
    geometry: geometry,
    meshes: FakeMeshSource(),
    clock: () => harness!.now,
    autoAdvance: autoAdvance,
    mode: CaptureMode.automatic,
  );
  harness = Harness(gateway, repository, controller);
  // The pose stream and the controller share one clock, so the engine's 600 ms
  // window is walked by the test rather than by real elapsed time.
  gateway.clock = () => harness!.now;
  await controller.boot(width: 720, height: 1280);
  await Harness.flush();
  return harness;
}

Future<Harness> calibratedHarness({
  ArRaycastHit? hit,
  bool surfaceFound = true,
  Uint8List? stillBytes,
  Object? stillError,
  bool autoAdvance = false,
  Object? recordError,
  bool hostPresent = true,
  bool reusedSession = false,
}) async {
  final harness = await bootHarness(
    hit: hit,
    surfaceFound: surfaceFound,
    stillBytes: stillBytes,
    stillError: stillError,
    autoAdvance: autoAdvance,
    recordError: recordError,
    hostPresent: hostPresent,
    reusedSession: reusedSession,
  );
  await harness.emit();
  await harness.controller.calibrateStation(stationId: 's1');
  await Harness.flush();
  return harness;
}

void main() {
  test(
    'the module reports a missing AR host instead of failing silently',
    () async {
      final harness = await bootHarness(hostPresent: false);
      expect(harness.controller.state.phase, CapturePhase.unavailable);
      expect(harness.controller.state.message, contains('ARCore host'));
    },
  );

  test('26-target startup explicitly disables plane finding', () async {
    final harness = await bootHarness();
    expect(harness.gateway.lastStartPlanes, isFalse);
    expect(harness.gateway.startCalls, 1);
  });

  group('station calibration', () {
    test('refuses to calibrate while AR is not tracking', () async {
      final harness = await bootHarness();
      await harness.emit(tracking: TrackingState.paused);
      await harness.controller.calibrateStation();
      expect(harness.controller.state.station, isNull);
      expect(harness.controller.state.message, contains('not tracking'));
    });

    test('records a fresh tracked camera pose as the reference pose', () async {
      final harness = await bootHarness();
      await harness.emit(position: const Vec3(1, 1.6, -2));
      expect(harness.controller.calibrationReadiness.isReady, isTrue);
      await harness.controller.calibrateStation(stationId: 's1');
      final station = harness.controller.state.station;
      expect(station, isNotNull);
      expect(station!.stationId, 's1');
      expect(station.referencePosition, const Vec3(1, 1.6, -2));
      expect(station.total, kCaptureTargetCount);
      expect(station.trackingStatus, TrackingState.tracking);
    });

    test(
      'stale or heading-invalid camera pose cannot establish the station',
      () async {
        final harness = await bootHarness();
        await harness.emit();
        harness.now = harness.now.add(const Duration(milliseconds: 300));
        expect(harness.controller.calibrationReadiness.isReady, isFalse);
        expect(
          harness.controller.calibrationReadiness.reason,
          contains('stale'),
        );
        expect(
          await harness.controller.calibrateStation(stationId: 's1'),
          isFalse,
        );
        expect(harness.gateway.anchorCreations, 0);

        // A new measured pose restores freshness, but a vertical optical axis
        // cannot define a horizontal station heading and must still be refused.
        await harness.emit(
          orientation: Quat.fromYawPitch(0, 90),
          advance: Duration.zero,
        );
        expect(harness.controller.calibrationReadiness.isReady, isFalse);
        expect(
          harness.controller.calibrationReadiness.reason,
          contains('horizontal'),
        );
        expect(
          await harness.controller.calibrateStation(stationId: 's1'),
          isFalse,
        );
        expect(harness.gateway.anchorCreations, 0);
      },
    );

    test('creates all 26 targets, none captured', () async {
      final harness = await calibratedHarness();
      expect(harness.controller.state.targets.length, kCaptureTargetCount);
      expect(harness.controller.state.capturedCount, 0);
      expect(
        harness.controller.state.targets.every(
          (CaptureTarget t) => t.status != CaptureTargetStatus.captured,
        ),
        isTrue,
      );
    });

    test(
      'calibrates with zero detected planes and one shared world anchor',
      () async {
        final harness = await bootHarness();
        await harness.emit(planesTracked: 0);

        final calibrated = await harness.controller.calibrateStation(
          stationId: 'markerless-zero-planes',
        );

        expect(calibrated, isTrue);
        expect(harness.controller.state.station, isNotNull);
        expect(harness.controller.state.targets, hasLength(26));
        expect(harness.gateway.anchorCreations, 1);
        expect(harness.gateway.anchors, hasLength(1));
        expect(harness.gateway.lastAnchorTrackableKey, isNull);
        expect(
          harness.controller.state.targets
              .map((CaptureTarget target) => target.anchorIdentifier)
              .toSet(),
          hasLength(1),
        );
        expect(harness.gateway.raycastCalls, 0);
        expect(harness.gateway.probeCalls, 0);
      },
    );
  });

  // ── required case 10 ──────────────────────────────────────────────────
  test('a room with no detected surfaces still places the target', () async {
    // Every one of the 26 probes reports a miss — ARCore has mapped nothing.
    // Placement must not care: the world position is computed from the
    // station, not discovered from a raycast.
    final harness = await calibratedHarness(surfaceFound: false);

    final target = harness.controller.state.targets.first;
    expect(target.anchorIdentifier, isNotNull);
    expect(target.anchorWorldPosition, isNotNull);
    expect(target.anchorSurfaceType, 'WORLD');
    expect(harness.controller.state.activeAnchored, isTrue);
    expect(harness.controller.state.targets, hasLength(kCaptureTargetCount));
    expect(
      harness.controller.state.targets
          .map((CaptureTarget target) => target.anchorIdentifier)
          .toSet(),
      hasLength(1),
    );
    expect(harness.gateway.anchors, hasLength(1));
    // The point of the test: calibration and readiness ask for no raycasts or
    // informational plane probes, so a room with no mapped surfaces is no
    // different from a mapped one.
    expect(harness.gateway.raycastCalls, 0);
    expect(harness.gateway.probeCalls, 0);
    // The whole arrangement is in the scene: bezel + target for all 26.
    expect(harness.gateway.lastScene.length, kCaptureTargetCount * 2);
    expect(harness.controller.state.instruction, isNot('Scan this surface'));
  });

  test(
    'placement anchors the target at its calculated world position',
    () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);
      await Harness.flush();

      final target = harness.controller.state.targets.first;
      expect(target.anchorIdentifier, isNotNull);
      expect(target.anchorWorldPosition, isNotNull);
      // World-space placement: there is no surface, and the record says so
      // instead of a plane type.
      expect(target.anchorSurfaceType, 'WORLD');
      // The position is station + radius × direction, through the station
      // frame's own transform. Deriving the expectation from the spec and the
      // frame keeps this honest for any reordering of the sphere.
      final radius = const CaptureGeometryConfig().targetRadiusM;
      final spec = buildCaptureSphere().first;
      final station = harness.controller.state.station!;
      final frame = StationFrame(
        origin: station.referencePosition,
        orientation: station.referenceOrientation,
      );
      final expectedPosition =
          frame.localToWorld(spec.direction).normalized * radius;
      expect(target.anchorWorldPosition!.x, closeTo(expectedPosition.x, 1e-9));
      expect(target.anchorWorldPosition!.y, closeTo(expectedPosition.y, 1e-9));
      expect(target.anchorWorldPosition!.z, closeTo(expectedPosition.z, 1e-9));
      // One shared station anchor holds all 26 nodes, placed once at
      // calibration — and selecting a target does not create another.
      expect(harness.gateway.anchorCreations, 1);
      // Bezel first, target on top — the order two coplanar meshes need.
      expect(
        harness.gateway.lastScene.first.meshId,
        PlaneAnchorService.bezelMeshId,
      );
      expect(
        harness.gateway.lastScene.last.meshId,
        PlaneAnchorService.targetMeshId,
      );
      expect(harness.controller.state.activeAnchored, isTrue);
    },
  );

  group('capture gating', () {
    test(
      'a shared ARCore map correction is not treated as leaving the station',
      () async {
        final harness = await calibratedHarness();
        final target = harness.controller.state.activeTarget!;
        final anchorId = target.anchorIdentifier!;
        // All 26 nodes hang off ONE station anchor, which sits at the station
        // origin — not at the target node's own world position. Refining the
        // node position here would be an anchor-only jump of a whole target
        // radius, which is a different event from a shared map correction.
        final placed = harness.controller.state.station!.referencePosition;
        const correction = Vec3(0.26, 0, 0);

        // Establish the anchor's first stable position, then reproduce the
        // relocalisation update from ARCore. Without this baseline a first pose
        // cannot tell a newly placed target from a refined one.
        await harness.emit();

        // ARCore can refine a world map after calibration. In that event its
        // camera and world anchors receive the same translation even though
        // the handset did not physically move. The gate must remove that
        // shared shift before applying the 20 cm station-distance rule.
        await harness.emit(
          position: correction,
          activeAnchorPose: (
            position: placed + correction,
            orientation: Quat.identity,
            tracking: TrackingState.tracking,
          ),
          reportedActiveAnchorId: anchorId,
        );

        expect(harness.controller.state.driftM, lessThan(0.001));
        expect(harness.controller.state.stationDrifted, isFalse);
        // The station did not move, but the thing the user is aiming at did.
        // A new stable window is therefore required before either shutter path
        // can use it.
        expect(harness.controller.state.stable, isFalse);
        expect(harness.controller.state.readyToCapture, isFalse);
      },
    );

    // ── required case 9 ─────────────────────────────────────────────────
    test('invalid tracking prevents capture', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1); // straight ahead

      // AR loses tracking, and the aimed hold is sustained well past the
      // stability window. The automatic gate is evaluated on every pose, so
      // this is the manual "press" translated into the only shutter the
      // product still has.
      await harness.emitStable(tracking: TrackingState.paused, count: 20);
      expect(harness.controller.state.readyToCapture, isFalse);
      expect(harness.controller.state.captureBlockReason, contains('tracking'));
      expect(harness.gateway.stillRequests, 0);
      expect(harness.controller.state.capturedCount, 0);

      // Tracking returns and the same hold now earns a real photograph. That
      // is what makes the refusal above a gate rather than a dead end. The
      // hold is longer than a normal one because recovery is two holds, not
      // one: 600 ms proving the station reference is continuous, then a fresh
      // 600 ms capture window.
      await harness.holdForAutomaticShutter(count: 40);
      expect(harness.gateway.stillRequests, 1);
      expect(harness.controller.state.capturedCount, 1);
      // The photograph cleared the guidance: with auto-advance off there is no
      // active target, so there is honestly nothing to aim at.
      expect(
        harness.controller.state.targets[0].status,
        CaptureTargetStatus.captured,
      );
      expect(harness.controller.state.alignment, isNull);
    });

    test('an unplaced target cannot be captured', () async {
      // Placement happens once, at calibration. The only way a target is
      // unplaced is AR refusing its world anchor during that pass — so the
      // refusal is armed before calibration, not after it.
      final harness = await bootHarness();
      await harness.emit();
      harness.gateway.refuseAnchors = true;
      await harness.controller.calibrateStation(stationId: 's1');
      await Harness.flush();

      // Calibration is atomic: one shared anchor carries all 26 directions,
      // so a refused anchor means there is no station and no arrangement —
      // not a station with 26 unplaced rows pretending to be usable.
      expect(harness.controller.state.station, isNull);
      expect(harness.controller.state.targets, isEmpty);
      expect(harness.controller.state.activeAnchored, isFalse);
      expect(harness.controller.state.readyToCapture, isFalse);
      expect(
        harness.controller.state.captureBlockReason,
        contains('retry calibration'),
      );
      await harness.emitStable();
      expect(harness.gateway.stillRequests, 0);
      // Nothing claimed to be placed: the whole pass failed, honestly.
      expect(harness.gateway.anchorCreations, 0);

      // And it is retryable: with AR accepting anchors again, the same call
      // produces a real station and the full arrangement.
      harness.gateway.refuseAnchors = false;
      await harness.controller.calibrateStation(stationId: 's1');
      await Harness.flush();
      expect(harness.controller.state.station, isNotNull);
      expect(harness.controller.state.targets.length, kCaptureTargetCount);
      expect(harness.gateway.anchorCreations, 1);
    });

    test('a pose outside tolerance is not ready', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);
      // Turn to face the opposite way: 180° of error.
      await harness.emit(orientation: orientationFor(const Vec3(0, 0, -1)));
      expect(
        harness.controller.state.alignment!.angularErrorDeg,
        greaterThan(3),
      );
      expect(harness.controller.state.readyToCapture, isFalse);
      await harness.emitStable(
        orientation: orientationFor(const Vec3(0, 0, -1)),
      );
      expect(harness.gateway.stillRequests, 0);
    });

    test('the shutter fires by itself once aligned and steady', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);
      // More samples than the window strictly needs: the gate has to be reached
      // well before the last pose, so a slow machine cannot make this test flaky.
      await harness.emitStable(count: 20);
      // The auto shutter is fire-and-forget: wait for the write to land rather
      // than assuming one flush was enough on this machine.
      await Harness.waitFor(
        () =>
            harness.controller.state.targets[0].status ==
            CaptureTargetStatus.captured,
      );
      expect(harness.gateway.stillRequests, 1);
      expect(
        harness.controller.state.targets[0].status,
        CaptureTargetStatus.captured,
      );
    });

    test(
      'green hold progress and JPEG auto-capture work without planes',
      () async {
        final harness = await bootHarness(surfaceFound: false);
        await harness.emit(planesTracked: 0);
        expect(
          await harness.controller.calibrateStation(stationId: 'markerless'),
          isTrue,
        );
        await harness.controller.selectTarget(1);
        await Harness.flush();

        final stillGate = Completer<void>();
        harness.gateway.stillGate = stillGate.future;
        var observedFullGreenHold = false;
        void observe() {
          final state = harness.controller.state;
          if (state.autoStage == AutoCaptureStage.armed &&
              state.stabilityProgress >= 1 &&
              state.alignmentHoldComplete &&
              state.station != null) {
            observedFullGreenHold = true;
          }
        }

        harness.controller.addListener(observe);
        await harness.emitStable(count: 24, planesTracked: 0);
        await Harness.waitFor(() => harness.gateway.stillRequests == 1);
        expect(observedFullGreenHold, isTrue);
        expect(harness.gateway.probeCalls, 0);
        expect(harness.gateway.raycastCalls, 0);
        expect(harness.controller.state.capturing, isTrue);
        expect(harness.repository.saveRecordCalls, 0);

        stillGate.complete();
        await Harness.waitFor(
          () => harness.controller.state.targets.first.status.isDone,
        );
        harness.controller.removeListener(observe);
        final record = (await harness.repository.loadRecords(
          'markerless',
        )).single;
        expect(record.targetId, 1);
        expect(record.imageFormat, 'jpeg');
        expect(await readCaptureImage(record.imagePath), fakeJpeg);
        expect(harness.controller.state.capturedCount, 1);
      },
    );

    test(
      'a single aligned frame is not enough — the pose must be steady',
      () async {
        final harness = await calibratedHarness();
        await harness.controller.selectTarget(1);
        await harness.emit(); // one aligned sample
        expect(harness.controller.state.alignment!.withinTolerance, isTrue);
        expect(harness.controller.state.stable, isFalse);
        expect(harness.gateway.stillRequests, 0);
      },
    );
  });

  // ── required case 11 ──────────────────────────────────────────────────
  group('a failed save', () {
    test(
      'does not mark the target captured when ARCore returns no image',
      () async {
        final harness = await calibratedHarness(
          stillError: const ArCoreFailure('Fake: no camera image.'),
        );
        await harness.controller.selectTarget(1);
        await harness.holdForAutomaticShutter();

        expect(harness.gateway.stillRequests, 1);
        expect(
          harness.controller.state.targets[0].status,
          CaptureTargetStatus.failed,
        );
        expect(harness.controller.state.targets[0].imagePath, isNull);
        expect(harness.controller.state.capturedCount, 0);
        expect(harness.repository.saveRecordCalls, 0);
        expect(harness.controller.state.lastError, isNotNull);
      },
    );

    test(
      'does not mark the target captured when the bytes are not a photograph',
      () async {
        final harness = await calibratedHarness(
          stillBytes: Uint8List.fromList(const <int>[1, 2, 3]),
        );
        await harness.controller.selectTarget(1);
        await harness.holdForAutomaticShutter();

        expect(
          harness.controller.state.targets[0].status,
          CaptureTargetStatus.failed,
        );
        expect(harness.controller.state.targets[0].imagePath, isNull);
        expect(harness.repository.saveRecordCalls, 0);
      },
    );

    test(
      'does not mark the target captured when the record cannot be written',
      () async {
        final harness = await calibratedHarness(
          recordError: StateError('disk full'),
        );
        await harness.controller.selectTarget(1);
        await harness.holdForAutomaticShutter();

        expect(harness.repository.saveRecordCalls, 1);
        expect(
          harness.controller.state.targets[0].status,
          CaptureTargetStatus.failed,
        );
        expect(harness.controller.state.targets[0].imagePath, isNull);
        expect(harness.controller.state.capturedCount, 0);
      },
    );

    test('can be retried, and the retry succeeds', () async {
      final harness = await calibratedHarness(
        stillError: const ArCoreFailure('Fake: no camera image.'),
      );
      await harness.controller.selectTarget(1);
      await harness.holdForAutomaticShutter();
      expect(
        harness.controller.state.targets[0].status,
        CaptureTargetStatus.failed,
      );

      harness.gateway.stillError = null;

      // The retry latch stays on until the user deliberately re-aims, so
      // continuing to hold the same aligned pose must not fire a second shot.
      await harness.emitStable(count: 20);
      await Harness.flush();
      expect(
        harness.controller.state.targets[0].status,
        CaptureTargetStatus.failed,
      );
      expect(
        harness.gateway.stillRequests,
        1,
        reason: 'the refused retry must not reach the camera',
      );

      // Breaking the hold and aiming again re-arms the shutter.
      await harness.emit(orientation: Quat.axisAngle(90, Vec3.unitY));
      await harness.holdForAutomaticShutter();
      expect(
        harness.controller.state.targets[0].status,
        CaptureTargetStatus.captured,
      );
      expect(harness.controller.state.capturedCount, 1);
    });
  });

  // ── required case 12 ──────────────────────────────────────────────────
  group('a successful save', () {
    test('updates only the station and target it belongs to', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);
      await harness.holdForAutomaticShutter();

      final targets = harness.controller.state.targets;
      expect(targets[0].status, CaptureTargetStatus.captured);
      expect(targets[0].imagePath, isNotNull);
      expect(targets.where((CaptureTarget t) => t.status.isDone).length, 1);
      expect(harness.controller.state.capturedCount, 1);
      expect(harness.controller.state.station!.capturedCount, 1);

      final records = await harness.repository.loadRecords('s1');
      expect(records.length, 1);
      expect(records.single.targetId, 1);
      expect(records.single.imagePath, targets[0].imagePath);
      expect(records.single.imageFormat, 'jpeg');
      expect(records.single.anchored, isTrue);
      expect(records.single.anchorSurfaceType, 'WORLD');
      expect(records.single.alignmentErrorDeg, lessThan(1e-6));
      expect(records.single.imageWidth, 1920);
      expect(records.single.imageHeight, 1080);
    });

    test('writes a file that exists and reads back byte for byte', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);
      await harness.holdForAutomaticShutter();

      final path = harness.controller.state.targets[0].imagePath!;
      final bytes = await readCaptureImage(path);
      expect(bytes, isNotNull);
      expect(bytes!.length, fakeJpeg.length);
      expect(bytes[0], fakeJpeg[0]);
      expect(bytes[fakeJpeg.length - 1], fakeJpeg[fakeJpeg.length - 1]);
    });

    test(
      'a second target adds a second record and leaves the first alone',
      () async {
        final harness = await calibratedHarness();
        await harness.controller.selectTarget(1);
        await harness.holdForAutomaticShutter();
        final firstPath = harness.controller.state.targets[0].imagePath;

        await harness.controller.selectTarget(10);
        await Harness.flush();
        await harness.holdForAutomaticShutter();

        final targets = harness.controller.state.targets;
        expect(targets[0].imagePath, firstPath);
        expect(targets[0].status, CaptureTargetStatus.captured);
        expect(targets[9].status, CaptureTargetStatus.captured);
        expect(harness.controller.state.capturedCount, 2);

        final records = await harness.repository.loadRecords('s1');
        expect(records.length, 2);
        expect(records.map((r) => r.targetId).toSet(), <int>{1, 10});
      },
    );
  });

  group('retake', () {
    test('clears one target without touching the others', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);
      await harness.holdForAutomaticShutter();
      await harness.controller.selectTarget(10);
      await Harness.flush();
      await harness.holdForAutomaticShutter();
      expect(harness.controller.state.capturedCount, 2);

      await harness.controller.retake(1);
      await Harness.flush();
      final targets = harness.controller.state.targets;
      expect(targets[0].status, isNot(CaptureTargetStatus.captured));
      expect(targets[0].imagePath, isNull);
      expect(targets[9].status, CaptureTargetStatus.captured);
      expect(targets[9].imagePath, isNotNull);
      expect(harness.controller.state.capturedCount, 1);
    });
  });

  group('app lifecycle', () {
    test(
      'background pause retains the session and verifies the shared anchor',
      () async {
        final harness = await calibratedHarness();
        await harness.controller.selectTarget(1);
        await Harness.flush();
        final targetIds = harness.controller.state.targets
            .map((CaptureTarget target) => target.targetId)
            .toList();
        final sharedAnchor =
            harness.controller.state.targets.first.anchorIdentifier;
        final startsBeforePause = harness.gateway.startCalls;

        await harness.controller.onAppPaused();
        expect(harness.gateway.pauseCalls, 1);
        expect(harness.gateway.stopCalls, 0);
        expect(harness.gateway.anchorCreations, 1);
        expect(sharedAnchor, isNotNull);
        expect(harness.gateway.anchors.containsKey(sharedAnchor), isTrue);
        expect(harness.controller.state.station, isNotNull);
        expect(harness.controller.state.trackingRecovering, isTrue);

        await harness.controller.onAppResumed(width: 720, height: 1280);
        expect(harness.gateway.resumeCalls, 1);
        expect(harness.gateway.startCalls, startsBeforePause);
        expect(harness.controller.state.station, isNotNull);
        expect(
          harness.controller.state.targets
              .map((CaptureTarget target) => target.targetId)
              .toList(),
          targetIds,
        );
        expect(harness.controller.state.trackingRecovering, isTrue);
        expect(harness.controller.state.readyToCapture, isFalse);

        // Fresh TRACKING camera and same tracked shared anchor must remain stable
        // for the independent recovery hold before guidance/capture can resume.
        await harness.emitStable(count: 16, planesTracked: 0);
        expect(harness.controller.state.trackingRecovering, isFalse);
        expect(harness.controller.state.station, isNotNull);
        expect(harness.gateway.anchorCreations, 1);
        expect(harness.gateway.stillRequests, 0);
      },
    );

    test(
      'an explicit new-session retry retains saved JPEGs for recalibration',
      () async {
        final harness = await calibratedHarness();
        await harness.controller.selectTarget(1);
        await harness.holdForAutomaticShutter();
        final savedPath = harness.controller.state.targets.first.imagePath!;
        final savedBytes = await readCaptureImage(savedPath);
        expect(savedBytes, isNotNull);

        await harness.controller.retrySession();
        await Harness.flush();

        expect(harness.gateway.stopCalls, 1);
        expect(harness.gateway.startCalls, 2);
        expect(harness.controller.state.station, isNull);
        expect(harness.controller.state.targets, isEmpty);
        expect(await readCaptureImage(savedPath), savedBytes);
        expect((await harness.repository.loadRecords('s1')).single.targetId, 1);
        expect(harness.controller.resumableStationId, 's1');
      },
    );

    test(
      'a second boot does not leave two pose subscriptions running',
      () async {
        final harness = await calibratedHarness();
        await harness.controller.onAppPaused();
        await harness.controller.onAppResumed(width: 720, height: 1280);
        await Harness.flush();

        expect(harness.gateway.startCalls, 1);
        expect(harness.gateway.resumeCalls, 1);
        // One pose sample must advance the stability clock once, not twice: with
        // two listeners the shutter could fire twice for one target.
        await harness.controller.selectTarget(1);
        await harness.emitStable(count: 36);
        await Harness.flush();
        expect(harness.gateway.stillRequests, lessThanOrEqualTo(1));
      },
    );

    test(
      'a failed resume keeps capture blocked and can retry the same session',
      () async {
        final harness = await calibratedHarness();
        final station = harness.controller.state.station;
        final targetIds = harness.controller.state.targets
            .map((CaptureTarget target) => target.targetId)
            .toList();
        harness.gateway.resumeError = const ArCoreFailure(
          'Fake: camera could not reopen.',
        );

        await harness.controller.onAppPaused();
        await harness.controller.onAppResumed(width: 720, height: 1280);
        await Harness.flush();

        expect(harness.gateway.startCalls, 1);
        expect(harness.gateway.stopCalls, 0);
        expect(harness.controller.state.station, station);
        expect(
          harness.controller.state.targets.map((t) => t.targetId),
          targetIds,
        );
        expect(harness.controller.state.trackingRecovering, isTrue);
        expect(harness.controller.state.readyToCapture, isFalse);
        expect(harness.controller.state.message, contains('could not reopen'));

        // A later lifecycle resume retries `resume()` on the retained session;
        // it does not start a new world or discard the saved station.
        harness.gateway.resumeError = null;
        await harness.controller.onAppResumed(width: 720, height: 1280);
        await Harness.flush();
        expect(harness.gateway.resumeCalls, 2);
        expect(harness.gateway.startCalls, 1);
        expect(harness.controller.state.station, station);
        expect(harness.controller.state.trackingRecovering, isTrue);
        expect(harness.gateway.stillRequests, 0);
      },
    );

    test(
      'dispose stops the session once and leaves no listener behind',
      () async {
        final harness = await calibratedHarness();
        harness.controller.dispose();
        await Harness.flush();

        // dispose() is its own stop — a pause first would have counted a
        // second one, so this pins the shutdown as a single stop.
        expect(harness.gateway.stopCalls, 1);
        expect(harness.gateway.stillRequests, 0);

        // After dispose nothing re-subscribes the pose stream, so a frame
        // delivered late must not move state after the shutdown.
        final frozen = harness.controller.state;
        await harness.emit(advance: const Duration(milliseconds: 16));
        await Harness.flush();
        expect(identical(harness.controller.state, frozen), isTrue);
        expect(harness.gateway.stopCalls, 1);
      },
    );

    test('a rewound stamp refuses the pose and the gate re-arms', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);

      // The stability window is the subject, so the photograph it arms is held
      // open: in automatic mode a steady aimed hold *is* the shutter, and
      // letting the write land would move the test on to target 2 mid-window.
      final write = Completer<void>();
      harness.gateway.stillGate = write.future;

      // A normal stream walks the window: fourteen poses, 60 ms apart.
      await harness.emitStable(count: 14);
      await Harness.flush();
      expect(harness.controller.state.stable, isTrue);

      // A monotonic clock never runs backwards — but a replayed frame or a
      // buggy host can deliver a stamp *below* the previous one. The gate
      // refuses the sample, clears the hold and names what it refused.
      harness.now = harness.now.subtract(const Duration(milliseconds: 80));
      await harness.emit(advance: Duration.zero);
      await Harness.flush();
      expect(harness.controller.state.stable, isFalse);
      expect(harness.controller.state.stabilityRejection, 'timestamp');

      // The refusal cleared the hold; the next honest stream re-walks the
      // window and `stable` flips back. (`stabilityRejection` keeps its last
      // reproduced value through null-valued successes — the state's copyWith
      // semantics — so the engine-level re-arm is asserted as: the flag is
      // back, and the refusal is no longer what is being reproduced.)
      await harness.emitStable(count: 14);
      await Harness.flush();
      expect(harness.controller.state.stable, isTrue);
      expect(harness.controller.state.stabilityRejection, isNot('timestamp'));

      write.complete();
      await Harness.flush();
    });
  });

  group('tracking-reference loss', () {
    test(
      'accepted JPEGs and target IDs survive loss and re-establishment',
      () async {
        final harness = await calibratedHarness();
        await harness.controller.selectTarget(1);
        await harness.holdForAutomaticShutter();
        final firstPath = harness.controller.state.targets.first.imagePath!;
        final firstBytes = await readCaptureImage(firstPath);
        final targetIds = harness.controller.state.targets
            .map((CaptureTarget target) => target.targetId)
            .toList();

        await harness.controller.selectTarget(2);
        await Harness.flush();
        final oldAnchorId =
            harness.controller.state.targets[1].anchorIdentifier!;
        harness.gateway.dropAnchor(oldAnchorId);
        await harness.emit(advance: const Duration(milliseconds: 600));
        await Harness.waitFor(
          () => harness.controller.requiresReferenceReestablishment,
        );

        expect(harness.controller.state.station?.stationId, 's1');
        expect(harness.controller.requiresReferenceReestablishment, isTrue);
        expect(harness.controller.state.targets, hasLength(26));
        expect(
          harness.controller.state.targets.map((t) => t.targetId),
          targetIds,
        );
        expect(harness.controller.state.capturedCount, 1);
        expect(harness.controller.state.targets.first.imagePath, firstPath);
        expect(await readCaptureImage(firstPath), firstBytes);
        expect(harness.controller.state.readyToCapture, isFalse);

        // A fresh tracked camera pose is required to place a new single shared
        // anchor. The accepted target remains accepted and is not photographed
        // again when the remaining work resumes.
        await harness.emit();
        expect(await harness.controller.recalibrateAndContinue('s1'), isTrue);
        expect(harness.controller.state.station?.stationId, 's1');
        expect(harness.controller.state.targets, hasLength(26));
        expect(harness.controller.state.capturedCount, 1);
        expect(
          harness.controller.state.targets.first.status,
          CaptureTargetStatus.captured,
        );
        expect(harness.controller.state.targets.first.imagePath, firstPath);
        expect(harness.controller.requiresReferenceReestablishment, isFalse);
        expect(harness.gateway.anchorCreations, 2);
        expect(harness.gateway.anchors, hasLength(1));
        expect(
          harness.controller.state.targets
              .map((CaptureTarget target) => target.anchorIdentifier)
              .toSet(),
          hasLength(1),
        );
        expect((await harness.repository.loadRecords('s1')).single.targetId, 1);
        expect(await readCaptureImage(firstPath), firstBytes);
      },
    );
  });

  group('scan again', () {
    test(
      're-arms the host, drops the anchor and re-places the target',
      () async {
        final harness = await calibratedHarness();
        await harness.controller.selectTarget(1);
        await Harness.flush();
        expect(harness.controller.state.activeAnchored, isTrue);
        final before = harness.gateway.anchorCreations;

        await harness.controller.rescanActive();
        await Harness.flush();

        expect(harness.gateway.rescanCalls, 1);
        expect(harness.gateway.anchorCreations, greaterThan(before));
        expect(harness.controller.state.activeAnchored, isTrue);
      },
    );

    test(
      'says why it cannot place a target while tracking is paused',
      () async {
        final harness = await calibratedHarness(surfaceFound: false);
        await harness.emit(tracking: TrackingState.paused);
        await harness.controller.rescanActive();
        await Harness.flush();

        expect(harness.controller.state.message, contains('not tracking'));
        expect(harness.controller.state.activeAnchored, isFalse);
        expect(harness.gateway.rescanCalls, 1);
      },
    );

    test('never touches an already captured photograph', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);
      await harness.holdForAutomaticShutter();
      final path = harness.controller.state.targets[0].imagePath;
      expect(path, isNotNull);

      await harness.controller.rescanActive();
      await Harness.flush();

      expect(harness.controller.state.targets[0].imagePath, path);
      expect(
        harness.controller.state.targets[0].status,
        CaptureTargetStatus.captured,
      );
      expect(harness.controller.state.capturedCount, 1);
    });
  });

  group('a fatal render failure', () {
    test('is surfaced with its class, message and origin', () async {
      final harness = await calibratedHarness();
      harness.gateway.emitFault(
        'java.lang.IllegalArgumentException: Must use a native order direct '
        'buffer',
        frame:
            'com.adaptive360.adaptive_360_capture_app.ar.ArGlRenderer'
            '.drawCamera(ArGlRenderer.kt:212)',
      );
      await Harness.flush();

      expect(
        harness.controller.state.arFault,
        contains('Must use a native order direct buffer'),
      );
      expect(
        harness.controller.state.arFaultFrame,
        contains('ArGlRenderer.kt:212'),
      );
      // And it explains the disabled shutter rather than leaving it greyed out.
      expect(
        harness.controller.state.captureBlockReason,
        contains('not rendering'),
      );
      expect(harness.controller.state.readyToCapture, isFalse);
    });

    test(
      'a non-fatal error is a diagnostics line, not a fault banner',
      () async {
        final harness = await calibratedHarness();
        harness.gateway.emitFault('a transient hiccup', fatal: false);
        await Harness.flush();

        expect(harness.controller.state.arFault, isNull);
        expect(
          harness.controller.state.lastError,
          contains('transient hiccup'),
        );
      },
    );
  });

  group('the marker orientation', () {
    test('faces the station, not away from it', () {
      // A wall whose normal points away from the station must be flipped, or the
      // marker would be drawn showing its back.
      const normal = Vec3(0, 0, -1);
      final faced = facingRotation(normal).rotate(Vec3.unitZ);
      expect(faced.maxAbsDiff(normal), lessThan(1e-9));
    });

    test('is identity when the surface already faces the station', () {
      final rotation = facingRotation(const Vec3(0, 0, 1));
      expect(
        rotation.rotate(Vec3.unitZ).maxAbsDiff(Vec3.unitZ),
        lessThan(1e-9),
      );
    });

    test('works for a floor and a ceiling', () {
      for (final normal in <Vec3>[Vec3.unitY, -Vec3.unitY, Vec3.unitX]) {
        final faced = facingRotation(normal).rotate(Vec3.unitZ);
        expect(faced.maxAbsDiff(normal), lessThan(1e-9));
      }
    });

    test('is deterministic for the anti-parallel case', () {
      final rotation = facingRotation(-Vec3.unitZ);
      expect(
        rotation.rotate(Vec3.unitZ).maxAbsDiff(-Vec3.unitZ),
        lessThan(1e-9),
      );
      expect(
        math.acos(
              (rotation.rotate(Vec3.unitZ).dot(Vec3.unitZ)).clamp(-1.0, 1.0),
            ) *
            180 /
            math.pi,
        closeTo(180, 1e-6),
      );
    });
  });

  // ── the motion pipeline, end to end ────────────────────────────────────
  group('smoothing, concurrency and diagnostics', () {
    test('a long eligible hold produces one photograph, not one per frame', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);

      // The gate is evaluated on every pose and the shutter is fire-and-forget,
      // so dozens of eligible frames arrive while the first JPEG is still being
      // written. `_shoot` takes its latch synchronously before its first await;
      // this is the automatic equivalent of the old double-tap test.
      await harness.emitStable(count: 60);
      await Harness.waitFor(() => harness.controller.state.capturedCount == 1);
      await Harness.flush();

      expect(harness.gateway.stillRequests, 1);
      expect(harness.controller.state.capturedCount, 1);
      expect(
        harness.controller.state.targets.where((t) => t.status.isDone).length,
        1,
      );
    });

    test('the arrow and the shutter read one alignment, not two', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);
      await harness.emit(); // aimed: the smoother takes its first sample

      harness.now = harness.now.add(const Duration(milliseconds: 60));
      await harness.emit(orientation: Quat.fromYawPitch(6, 0));

      // One result, so the guidance never disagrees with the arithmetic the
      // shutter is gated on: a 6° turn reads as 6° on the very next frame.
      final alignment = harness.controller.state.alignment!;
      expect(alignment.angularErrorDeg, closeTo(6, 0.5));
      expect(alignment.withinTolerance, isFalse);
      expect(harness.controller.state.readyToCapture, isFalse);
      // And the named instruction state comes from that same result.
      expect(harness.controller.state.guidance, GuidanceState.right);

      // The smoother still runs — but its output goes to the motion record,
      // not to anything that aims. The filtered copy of this very sample lags,
      // which is exactly what the arrow must no longer inherit.
      final turning = harness.controller.diagnostics.entries.last;
      expect(turning.filtered.maxComponentDiff(turning.raw), greaterThan(1e-6));
    });

    test(
      'losing tracking clears the guidance instead of smearing across the gap',
      () async {
        final harness = await calibratedHarness();
        await harness.controller.selectTarget(1);
        await harness.emit();
        harness.now = harness.now.add(const Duration(milliseconds: 60));
        await harness.emit(orientation: Quat.fromYawPitch(6, 0));

        // A paused pose is ARCore's *last known* pose, so nothing that aims is
        // computed from it, and the filter is reset so it cannot carry the
        // pre-interruption estimate into the recovery.
        await harness.emit(tracking: TrackingState.paused);
        expect(harness.controller.state.alignment, isNull);
        expect(harness.controller.state.guidance, GuidanceState.trackingPaused);

        harness.now = harness.now.add(const Duration(milliseconds: 60));
        await harness.emit(orientation: Quat.fromYawPitch(6, 0));

        // The resumed frame is measured, not published: the station reference
        // still has to prove it is continuous, so guidance stays suppressed
        // and no turn is issued from a pose that may belong to a new map.
        expect(harness.controller.state.alignment, isNull);
        expect(harness.controller.state.trackingRecovering, isTrue);
        expect(
          harness.controller.state.instruction,
          'Verifying the station reference — keep the phone at the station.',
        );
        // The record still shows what was measured: 6° off, and the filtered
        // orientation is that same pose rather than a blend with the one held
        // before the interruption — the smoother was reset across the gap.
        final restored = harness.controller.diagnostics.entries.last;
        expect(restored.errorDeg, closeTo(6, 0.5));
        expect(
          restored.filtered.maxComponentDiff(restored.raw),
          lessThan(1e-9),
        );

        // Verification is its own 600 ms hold on the station-relative camera.
        // Once it completes, the aim is published — still 6° off, so the line
        // names a turn and the shutter stays shut.
        await harness.emitStable(
          orientation: Quat.fromYawPitch(6, 0),
          count: 14,
        );
        expect(harness.controller.state.trackingRecovering, isFalse);
        expect(
          harness.controller.state.alignment!.angularErrorDeg,
          closeTo(6, 0.5),
        );
        expect(harness.gateway.stillRequests, 0);

        harness.now = harness.now.add(const Duration(milliseconds: 60));
        await harness.emit();
        expect(harness.controller.state.trackingRecovering, isFalse);
      },
    );

    test('the motion record captures raw, filtered and the outcome', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);
      await harness.emitStable(count: 12);

      final diagnostics = harness.controller.diagnostics;
      expect(diagnostics.length, greaterThan(5));

      final csv = diagnostics.toCsv();
      expect(csv, startsWith('t_ms,raw_x'));
      expect(csv.split('\n').length, greaterThan(5));

      final json = diagnostics.toJson();
      expect(json, contains('adaptive360.motion/1'));
      // No personal data: the schema is timestamps, quaternions and outcomes.
      expect(json.toLowerCase(), isNot(contains('path')));
      expect(json.toLowerCase(), isNot(contains('device_id')));
    });

    test('the stability monitor reports why it refused', () async {
      final harness = await calibratedHarness();
      await harness.controller.selectTarget(1);
      await harness.emit(); // one aligned sample: the window has not elapsed
      expect(harness.controller.state.stable, isFalse);
      expect(harness.controller.state.stabilityRejection, 'window');
    });
  });

  // Optional diagnostic bridge API retained for other AR callers. The
  // markerless 26-target calibration path never invokes it.
  group('optional direction probe API', () {
    test(
      'calibration and auto-capture do not probe target directions',
      () async {
        final harness = await calibratedHarness(surfaceFound: false);
        expect(harness.gateway.probeCalls, 0);
        expect(harness.controller.state.probes, isEmpty);
        expect(
          harness.controller.state.targets,
          hasLength(kCaptureTargetCount),
        );
        expect(harness.controller.state.activeAnchored, isTrue);
      },
    );

    test('a probe records a surface per direction, and counts them', () async {
      final harness = await calibratedHarness();
      harness.gateway.probeResults = <SurfaceProbe>[
        for (var i = 0; i < kCaptureTargetCount; i++)
          i.isEven
              ? const SurfaceProbe.found(
                  distanceM: 2.4,
                  surfaceType: 'PLANE_VERTICAL',
                )
              : const SurfaceProbe.miss(),
      ];

      await harness.controller.probeTargets();
      await Harness.flush();

      final probes = harness.controller.state.probes;
      expect(probes.length, kCaptureTargetCount);
      expect(harness.controller.state.probesWithSurface, 13);
      expect(probes[1]!.found, isTrue);
      expect(probes[1]!.describe, 'wall · 2.4 m');
      expect(probes[2]!.found, isFalse);
    });

    test('a probe does not create anchors', () async {
      final harness = await calibratedHarness();
      final before = harness.gateway.anchorCreations;
      harness.gateway.probeResults = <SurfaceProbe>[
        for (var i = 0; i < kCaptureTargetCount; i++)
          const SurfaceProbe.found(distanceM: 2, surfaceType: 'PLANE_VERTICAL'),
      ];
      await harness.controller.probeTargets();
      await Harness.flush();
      expect(harness.gateway.anchorCreations, before);
    });

    test('the message reports how many directions have a surface', () async {
      final harness = await calibratedHarness();
      harness.gateway.probeResults = <SurfaceProbe>[
        for (var i = 0; i < kCaptureTargetCount; i++)
          i < 4
              ? const SurfaceProbe.found(
                  distanceM: 1,
                  surfaceType: 'PLANE_VERTICAL',
                )
              : const SurfaceProbe.miss(),
      ];
      await harness.controller.probeTargets();
      await Harness.flush();
      expect(
        harness.controller.state.message,
        contains('4 of $kCaptureTargetCount'),
      );
    });
  });
}
