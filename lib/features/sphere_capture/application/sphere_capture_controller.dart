// Named parameters are deliberately not `this._field`: a private named
// parameter cannot be used by callers outside this library, so the public
// constructor reads `rotation:` rather than `_rotation:`.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppLifecycleState;

import 'package:camera/camera.dart' show CameraException;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:path/path.dart' as p;

import 'package:path_provider/path_provider.dart';

import 'package:adaptive_360_capture_app/core/error/failures.dart';
import 'package:adaptive_360_capture_app/core/permissions/permission_service.dart';
import 'package:adaptive_360_capture_app/features/capture/application/panorama_generation_service.dart';
import 'package:adaptive_360_capture_app/features/capture/data/repositories/capture_repository_impl.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/models/capture_record.dart';
import 'package:adaptive_360_capture_app/features/capture/domain/services/panorama_stitcher.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/application/panorama_sync_service.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/data/local/capture_session_store.dart';
import 'package:adaptive_360_capture_app/features/sitewise_sync/domain/capture_session.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/data/gallery_saver.dart';
// `NormalizedJpeg` lives in the domain layer (not in `jpeg_normalizer.dart`,
// which links OpenCV) so this controller — and every test that drives it — does
// not need the native stitching library to name the type.
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/normalized_jpeg.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/motion_detector.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/motion_freeze_gate.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_projection.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/scalars.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/platform/rotation_sensor.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/platform/sphere_camera.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// Where the 3DoF capture flow is in its lifecycle.
enum SphereCapturePhase {
  /// Nothing has been asked of the device yet; the start screen is showing.
  idle,

  /// Permissions, camera and sensor are coming up.
  starting,

  /// Live: rotation is tracked and the shutter can fire automatically.
  ready,

  /// A photograph is being written.
  capturing,

  /// All 38 photographs exist; the panorama is stitching.
  complete,

  /// Camera or sensor could not start. [SphereCaptureController.message] says
  /// why, in words for the user.
  failed,
}

/// One target plus the evidence that it has been photographed.
class SphereTargetState {
  final SphereTargetSpec spec;
  final bool captured;
  final String? imagePath;

  const SphereTargetState({
    required this.spec,
    this.captured = false,
    this.imagePath,
  });

  SphereTargetState asCaptured(String path) =>
      SphereTargetState(spec: spec, captured: true, imagePath: path);
}

/// The sphere-follows-phone capture controller.
///
/// ## What it does not do
///
/// There is no AR session, no anchor, no plane, no station and no translation.
/// The sphere's centre is the phone; walking is invisible to the maths. The
/// only state that changes with the world is the device quaternion, and the
/// only geometry is `q⁻¹ · (q₀ · v_S)` — see `sphere_projection.dart`.
///
/// ## The automatic shutter
///
/// On every rotation sample the controller finds the uncaptured target with
/// the smallest angle to the centre reticle. If that angle is inside
/// [toleranceDeg] the hold ring fills; it reaches the shutter after
/// [holdDuration]. Leaving the cone past [exitToleranceDeg] discards the hold,
/// so a hand tremor at the boundary cannot reset a ring the user has earned,
/// but a deliberate turn cannot keep filling one either.
///
/// **Any** uncaptured target can be captured, not just the next in sequence —
/// the specification says so, and it is also what makes the flow forgiving
/// when the user overshoots. The bottom pill names the nearest target, which
/// is the one the ring belongs to.
class SphereCaptureController extends ChangeNotifier {
  SphereCaptureController({
    required RotationSource rotation,
    required SphereCamera camera,
    required CaptureRepository repository,
    required PanoramaStitcher stitcher,
    required String stationId,
    required Future<NormalizedJpeg> Function(Uint8List bytes) normalize,
    Stream<Vec3>? motion,
    Stream<Vec3>? angularVelocity,
    PermissionService? permissions,
    Future<void> Function()? haptic,
    DateTime Function()? clock,
    SphereExporter? export,
    GallerySaver? gallerySaver,
    CaptureSessionStore? sessions,
    PanoramaSyncService? sync,
    String? userId,
    int? propertyId,
    this.toleranceDeg = kSphereAlignmentToleranceDeg,
    this.exitToleranceDeg = kSphereAlignmentExitDeg,
    this.holdDuration = const Duration(milliseconds: 600),
  }) : _rotation = rotation,
       _camera = camera,
       _repository = repository,
       _stitcher = stitcher,
       _stationId = stationId,
       _motionStream = motion,
       _angularVelocityStream = angularVelocity,
       _permissions = permissions ?? PermissionService(),
       _haptic = haptic ?? HapticFeedback.mediumImpact,
       _clock = clock ?? DateTime.now,
       _normalize = normalize,
       _export = export ?? _defaultExport,
       _gallery = gallerySaver ?? const GallerySaver(),
       _sessions = sessions,
       _sync = sync,
       _userId = userId,
       _propertyId = propertyId;

  final RotationSource _rotation;
  final SphereCamera _camera;
  final CaptureRepository _repository;
  final PanoramaStitcher _stitcher;
  final String _stationId;
  final Stream<Vec3>? _motionStream;

  /// Raw gyroscope, rad/s. Null in tests and on a device without one, in which
  /// case the freeze gate is skipped rather than blocking every capture.
  final Stream<Vec3>? _angularVelocityStream;
  final PermissionService _permissions;
  final Future<void> Function() _haptic;
  final DateTime Function() _clock;
  final Future<NormalizedJpeg> Function(Uint8List bytes) _normalize;
  final SphereExporter _export;
  final GallerySaver _gallery;

  /// The local-first metadata store, when one is attached.
  ///
  /// Optional so the capture flow still works if SQLite cannot be opened: a
  /// metadata write failing must never cost the user a photograph. Every call
  /// into it is guarded for exactly that reason.
  final CaptureSessionStore? _sessions;

  /// The upload queue, when Supabase is configured.
  final PanoramaSyncService? _sync;

  String? _userId;
  int? _propertyId;

  /// The alignment cone that turns a target green and fills the ring.
  final double toleranceDeg;

  /// The angle past which a filling hold is discarded.
  final double exitToleranceDeg;

  /// How long the target must stay inside [toleranceDeg] before the shutter.
  final Duration holdDuration;

  final MotionDetector _motionDetector = MotionDetector();

  /// How long the phone must have been angularly still before the shutter.
  final MotionFreezeGate _freezeGate = MotionFreezeGate();

  StreamSubscription<Vec3>? _gyroSubscription;

  List<SphereTargetState> _targets = <SphereTargetState>[
    for (final SphereTargetSpec spec in buildSphereTargets())
      SphereTargetState(spec: spec),
  ];

  SphereCapturePhase _phase = SphereCapturePhase.idle;
  String? _message;
  Quat? _deviceToWorld;
  Quat? _startDeviceToWorld;

  /// When the camera preview first became renderable.
  ///
  /// Rotation samples that arrive before this describe a phone pose from
  /// before the user could see the viewfinder, so they can never seed the
  /// reference heading. Seeding from one of those was the startup defect:
  /// the reference described a mid-lift pose and target 1 ended up 20–40°
  /// outside the viewfinder once the preview appeared.
  DateTime? _previewReadyAt;

  /// Arrival time of the previous rotation sample, for the continuity check
  /// that keeps a single stale/glitched event from freezing the reference.
  DateTime? _lastRotationArrivalAt;

  /// Completes the moment the reference heading is established, so `start()`
  /// can flip to `ready` only when the sphere is actually anchored.
  Completer<void>? _referenceCompleter;
  int? _activeTargetId;
  double _activeErrorDeg = 180;
  double _holdProgress = 0;
  int? _holdTargetId;
  DateTime? _lastSampleAt;
  Vec3? _lastCapturedDirection;
  int? _guideTargetId;
  double _guideSeparationDeg = 180;
  double _guideErrorDeg = 180;
  double _guideTurnDeg = 0;
  double _guidePitchDeg = 0;
  bool _guideBehind = false;
  bool _moving = false;
  bool _capturing = false;
  bool _stitching = false;
  bool _exporting = false;
  bool _disposed = false;
  bool _loggedFirstSample = false;
  String? _banner;
  String? _stitchStage;
  String? _stitchError;
  String? _panoramaPath;
  String? _exportPath;
  String? _galleryPath;

  /// The local synchronisation row for this session, when one exists.
  PanoramaSyncRecord? _syncRecord;

  /// The most recent upload attempt, so the completion sheet can say what
  /// happened without re-reading SQLite on every frame.
  SyncAttempt? _lastSyncAttempt;
  bool _syncing = false;

  StreamSubscription<Quat>? _rotationSubscription;
  StreamSubscription<Vec3>? _motionSubscription;
  Timer? _bannerTimer;
  Future<void>? _stitchFuture;

  SphereCapturePhase get phase => _phase;

  String? get message => _message;

  List<SphereTargetState> get targets =>
      List<SphereTargetState>.unmodifiable(_targets);

  int get capturedCount =>
      _targets.where((SphereTargetState t) => t.captured).length;

  int? get activeTargetId => _activeTargetId;

  SphereTargetState? get activeTarget {
    final id = _activeTargetId;
    if (id == null) return null;
    for (final target in _targets) {
      if (target.spec.targetId == id) return target;
    }
    return null;
  }

  /// The angle between the active target and the centre reticle, in degrees.
  double get activeErrorDeg => _activeErrorDeg;

  /// 0…1 progress of the hold ring for the active target.
  double get holdProgress => _holdProgress;

  bool get moving => _moving;

  bool get capturing => _capturing;

  String? get banner => _banner;

  bool get stitching => _stitching;

  String? get stitchStage => _stitchStage;

  String? get stitchError => _stitchError;

  String? get panoramaPath => _panoramaPath;

  /// The MediaStore URI of the Gallery copy, or `null` when it was not saved.
  String? get galleryPath => _galleryPath;

  /// `Pictures/SiteWise360/<stationId>`, the folder the Gallery copy lives in.
  String get galleryFolder => 'Pictures/SiteWise360/$_stationId';

  String? get exportPath => _exportPath;

  bool get exporting => _exporting;

  /// The session id, which is also the station directory name.
  ///
  /// The two are deliberately the same string: the SQLite row and the JPEG paths
  /// on disk then describe one thing, so the stitcher keeps reading exactly the
  /// paths it always read.
  String get sessionId => _stationId;

  /// `public.property.property_id` for this session, once one is chosen and the
  /// association is verified. `null` means the panorama stays on the device.
  int? get propertyId => _propertyId;

  /// The account that owns this capture, when signed in.
  String? get userId => _userId;

  /// Whether an upload is running right now.
  bool get syncing => _syncing;

  /// The local synchronisation row, for the status line.
  PanoramaSyncRecord? get syncRecord => _syncRecord;

  /// The last attempt's outcome and message.
  SyncAttempt? get lastSyncAttempt => _lastSyncAttempt;

  /// A sentence about the cloud copy: uploading, uploaded, or why not.
  String? get syncMessage => _lastSyncAttempt?.message ?? _syncRecord?.lastError;

  /// Whether the cloud copy is confirmed by Supabase.
  bool get isUploaded => _syncRecord?.status == PanoramaSyncStatus.uploaded;

  /// Whether "Retry" should be offered: there is a panorama, and it is not
  /// already in the cloud.
  bool get canRetrySync {
    final record = _syncRecord;
    if (record == null || _panoramaPath == null) return false;
    return record.status != PanoramaSyncStatus.uploaded && !_syncing;
  }

  Quat? get deviceToWorld => _deviceToWorld;

  /// The device orientation captured when the sphere was anchored to the
  /// phone, i.e. `q₀` in `q⁻¹ · (q₀ · v_S)`.
  Quat? get startDeviceToWorld => _startDeviceToWorld;

  /// The station directory name, for the export manifest and diagnostics.
  String get stationId => _stationId;

  /// The target the arrow points at: the next uncaptured frame in the stitch
  /// path.
  ///
  /// This **is** [activeTarget]. They were once two different things — the
  /// arrow followed the stitch order while the shutter fired for whatever was
  /// nearest the reticle — which let the UI highlight one target and capture
  /// another. One field now drives the arrow, the pill, the hold ring and the
  /// shutter, so they cannot disagree.
  SphereTargetState? get guideTarget {
    final id = _guideTargetId;
    if (id == null) return null;
    for (final target in _targets) {
      if (target.spec.targetId == id) return target;
    }
    return null;
  }

  int? get guideTargetId => _guideTargetId;

  /// Angular distance between the guide target and the last captured frame.
  double get guideSeparationDeg => _guideSeparationDeg;

  /// Estimated share of the previous frame the guided capture will overlap.
  double get guideOverlapFraction =>
      estimatedOverlapFraction(_guideSeparationDeg);

  /// The current angle between the guide target and the centre reticle.
  double get guideErrorDeg => _guideErrorDeg;

  /// Signed horizontal angle from the reticle to the guide target, in degrees.
  ///
  /// Positive is to the user's **right**, so the guidance can say "turn right
  /// 30°" instead of "follow the arrow (30°)" — the sign is what the arrow used
  /// to carry alone. It is already the shortest way round: `atan2` returns
  /// (−180°, +180°], so a target 170° clockwise is "right 170", not "left 190".
  double get guideTurnDeg => _guideTurnDeg;

  /// Signed vertical angle to the guide target, in degrees, positive up.
  double get guidePitchDeg => _guidePitchDeg;

  /// Whether the guide target is behind the camera, where it cannot be drawn.
  bool get guideBehind => _guideBehind;

  /// Where the phone is currently looking, expressed in the frozen start
  /// device frame — the same frame the target directions live in.
  ///
  /// This is what lets the mini-map show "you are here" against the fixed
  /// sphere, so the user can see that turning is closing the gap rather than
  /// having to infer it from the arrow.
  Vec3? get lookDirectionInStartFrame {
    final device = _deviceToWorld;
    final start = _startDeviceToWorld;
    if (device == null || start == null) return null;
    final world = device.rotate(const Vec3(0, 0, -1));
    return start.conjugate.rotate(world).normalized;
  }

  /// `Target 1 / 38 — Middle Ring (0°)`, or the completion sentence.
  String get progressLabel {
    final target = guideTarget ?? activeTarget;
    if (target == null) {
      return 'All $kSphereTargetCount targets captured';
    }
    return target.spec.progressLabel;
  }

  /// The sentence above the progress pill.
  ///
  /// It names the turn in the words the user actually needs — "Turn right 30°"
  /// — because the arrow is only unambiguous once the target is on screen, and
  /// with 30° ring spacing and a ~50° horizontal field of view the next target
  /// is usually *outside* it while the current one is centred. The wording is
  /// derived from the same angle the shutter uses, so it cannot drift from the
  /// capture gate.
  String get guidance {
    if (_phase == SphereCapturePhase.failed) {
      return _message ?? 'The camera could not start.';
    }
    if (_phase == SphereCapturePhase.starting) {
      return 'Starting the camera and rotation sensor…';
    }
    if (_phase == SphereCapturePhase.complete) {
      return 'All $kSphereTargetCount targets captured.';
    }
    if (_phase == SphereCapturePhase.capturing) {
      return 'Saving the photograph…';
    }
    final target = guideTarget ?? activeTarget;
    if (target == null) return 'Hold the phone steady.';
    if (_activeErrorDeg <= toleranceDeg) {
      return 'Hold steady — capturing ${target.spec.shortName}.';
    }
    final name = target.spec.shortName;
    // Coarse turns are horizontal; once the bearing is close, the remaining
    // error is usually vertical and "tilt up" is the useful instruction.
    final String move;
    if (_guideTurnDeg.abs() >= 12) {
      move =
          'Turn ${_guideTurnDeg > 0 ? 'right' : 'left'} '
          '${_guideTurnDeg.abs().round()}°';
    } else if (_guidePitchDeg.abs() >= 8) {
      move =
          'Tilt ${_guidePitchDeg > 0 ? 'up' : 'down'} '
          '${_guidePitchDeg.abs().round()}°';
    } else {
      move =
          'Turn ${_guideTurnDeg >= 0 ? 'right' : 'left'} '
          '${_activeErrorDeg.round()}°';
    }
    // No overlap warning here. The two 90° pole steps genuinely share nothing
    // with their predecessor, but they are bridged by the ring frame that
    // follows, and telling the user the panorama "may seam" mid-capture is an
    // alarm they cannot act on. `guideOverlapFraction` stays available for
    // diagnostics.
    return '$move to $name.';
  }

  /// Starts permissions, camera and rotation stream.
  Future<void> start() async {
    if (_phase == SphereCapturePhase.starting ||
        _phase == SphereCapturePhase.ready ||
        _phase == SphereCapturePhase.capturing ||
        _phase == SphereCapturePhase.complete) {
      return;
    }
    _phase = SphereCapturePhase.starting;
    _message = null;
    // A retry must anchor the sphere to the pose the user is in now, not to
    // whatever pose a previous, failed attempt happened to record.
    _deviceToWorld = null;
    _startDeviceToWorld = null;
    _previewReadyAt = null;
    _lastRotationArrivalAt = null;
    _referenceCompleter = Completer<void>();
    _holdProgress = 0;
    _holdTargetId = null;
    _lastSampleAt = null;
    _lastCapturedDirection = null;
    _guideTargetId = null;
    _guideSeparationDeg = 180;
    _guideErrorDeg = 180;
    _guideTurnDeg = 0;
    _guidePitchDeg = 0;
    _guideBehind = false;
    _galleryPath = null;
    _notify();
    try {
      // The session row exists before the camera does, so a capture that is
      // interrupted on the very first frame still leaves a resumable record.
      await _ensureSession();
      await _permissions.ensureCapturePermissions();
      await _camera.open();
      // The preview must be visible before the reference heading is taken.
      // `open()` only guarantees the platform stream is configured; the
      // texture still has to attach and draw. A reference taken before that
      // anchors the sphere to a pose the user could not see yet — the cause
      // of target 1 appearing outside the viewfinder at Start.
      await _camera.ensurePreviewReady();
      _previewReadyAt = _clock();
      // A retry after a failure must not leave the previous subscription
      // attached: two listeners would double every hold increment.
      await _rotationSubscription?.cancel();
      _rotationSubscription = _rotation.rotations.listen(
        _onRotation,
        onError: _onRotationError,
      );
      await _rotation.start();
      final motion = _motionStream;
      if (motion != null) {
        _motionSubscription = motion.listen(_onMotionSample);
      }
      final gyro = _angularVelocityStream;
      if (gyro != null) {
        _freezeGate.reset();
        _gyroSubscription = gyro.listen(_onGyroSample);
      }
      _message = 'Aligning the sphere…';
      _notify();
      // Wait for a fresh, settled sample to establish the reference heading.
      // Bounded: if the phone is pointing at a pole there is no heading to
      // take, and the guidance below tells the user how to fix that rather
      // than blocking the screen forever.
      await _referenceCompleter?.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      _phase = SphereCapturePhase.ready;
      _recomputeGuide();
      if (_startDeviceToWorld == null) {
        _message =
            'Point the phone towards the room — not straight down or straight '
            'up — so the sphere has a horizon to sit on.';
      } else {
        _message = 'Point the phone at a target and hold it inside the ring.';
      }
    } on CaptureFailure catch (error) {
      _phase = SphereCapturePhase.failed;
      _message = error.message;
    } catch (error) {
      _phase = SphereCapturePhase.failed;
      _message = 'The capture could not start: ${_describe(error)}';
    }
    _notify();
  }

  void _onRotationError(Object error) {
    _phase = SphereCapturePhase.failed;
    _message =
        'The device rotation sensor is unavailable, so the sphere cannot '
        'follow the phone ($error).';
    _notify();
  }

  void _onRotation(Quat quaternion) {
    // `starting` is included on purpose: the reference heading is established
    // from a rotation sample during startup, not before it.
    if (_phase != SphereCapturePhase.starting &&
        _phase != SphereCapturePhase.ready &&
        _phase != SphereCapturePhase.capturing) {
      return;
    }
    final now = _clock();
    final previousArrival = _lastRotationArrivalAt;
    _lastRotationArrivalAt = now;
    _deviceToWorld = quaternion;
    // The sphere's reference frame is the start pose **levelled**: heading kept,
    // pitch and roll dropped. Seeding it from the raw first sample baked the
    // phone's tilt at the instant Start was pressed into every target, so the
    // "horizon" ring was not the horizon and every marker sat at the same
    // constant angle off the room while still tracking the phone correctly.
    //
    // `worldUp` comes from the source, not from a constant here: Android
    // reports East–North–Up (`+Z` up) while this project's pose helpers use
    // `+Y`. Levelling with the wrong axis turns the "yaw" into a roll and tilts
    // every ring by 90°. See [levelStartFrame].
    final worldUp = _rotation.worldUp;
    if (_startDeviceToWorld == null) {
      // A sample may seed the reference only when it is *fresh* in the two
      // senses that matter at startup:
      //
      //  * it arrived after the preview was renderable (plus a short settle
      //    window), so it describes the phone where the user can actually see
      //    the viewfinder rather than mid-lift; and
      //  * it is part of a continuous stream (the previous sample was recent),
      //    so a single stale or glitched event cannot freeze the heading.
      //
      // Until both hold, the pose keeps updating — the first rendered frame
      // after `ready` is already correct — but nothing is anchored.
      final readyAt = _previewReadyAt;
      final settled =
          readyAt != null &&
          now.difference(readyAt) >= const Duration(milliseconds: 250);
      final continuous =
          previousArrival != null &&
          now.difference(previousArrival) <=
              const Duration(milliseconds: 150);
      if (!settled || !continuous) {
        return;
      }
      _startDeviceToWorld = levelStartFrame(quaternion, worldUp: worldUp);
      final completer = _referenceCompleter;
      if (_startDeviceToWorld != null &&
          completer != null &&
          !completer.isCompleted) {
        completer.complete();
      }
    }
    final start = _startDeviceToWorld;
    if (start == null) {
      // The phone is pointing too close to straight up or down for a heading to
      // exist. Freezing a reference here would tilt the whole station, so the
      // calibration waits — and says so — instead of guessing.
      _message =
          'Point the phone towards the room — not straight down or straight '
          'up — so the sphere has a horizon to sit on.';
      _notify();
      return;
    }
    if (!_loggedFirstSample) {
      _loggedFirstSample = true;
      // The tilt that levelling removed, so a device log can confirm the sphere
      // started level rather than inheriting the phone's angle at Start.
      final removedTiltDeg = cameraElevationDeg(quaternion, worldUp: worldUp);
      debugPrint(
        'SPHERE_SENSOR: first rotation '
        'q=(${quaternion.x.toStringAsFixed(4)}, '
        '${quaternion.y.toStringAsFixed(4)}, '
        '${quaternion.z.toStringAsFixed(4)}, '
        '${quaternion.w.toStringAsFixed(4)}) '
        'start tilt removed=${removedTiltDeg.toStringAsFixed(1)}° '
        'worldUp=(${worldUp.x.toStringAsFixed(0)},'
        '${worldUp.y.toStringAsFixed(0)},'
        '${worldUp.z.toStringAsFixed(0)})',
      );
    }

    // **One target, one decision.** The target the arrow points at, the target
    // the pill names, the target whose ring fills and the target the shutter
    // fires for are the same object. They used to be two: the arrow followed
    // the stitch order while the shutter fired for whatever was nearest the
    // reticle, so a user could see "Target 5" highlighted and have target 3
    // captured. With a fixed id order the first uncaptured target is also
    // target 1 at the start of a station, which is what makes the first
    // photograph compulsory and horizon-level.
    final active = guideTarget;
    var activeError = 180.0;
    var turnDeg = 0.0;
    var pitchDeg = 0.0;
    var behind = false;
    if (active != null) {
      final direction = sphereTargetCameraDirection(
        deviceToWorld: quaternion,
        startDeviceToWorld: start,
        startDirection: active.spec.direction,
      );
      activeError = reticleErrorDeg(direction);
      // Horizontal bearing in the camera frame. The camera looks along `−z`, so
      // a target to the user's right has `x > 0` and `atan2(x, −z)` is a
      // positive angle — the sign the guidance needs to say "turn right".
      turnDeg = math.atan2(direction.x, -direction.z) * radToDeg;
      pitchDeg = math.asin(clampDouble(direction.y, -1, 1)) * radToDeg;
      behind = direction.z > 0;
    }

    _activeTargetId = active?.spec.targetId;
    _activeErrorDeg = activeError;
    _guideErrorDeg = activeError;
    _guideTurnDeg = turnDeg;
    _guidePitchDeg = pitchDeg;
    _guideBehind = behind;

    if (active != null && _phase == SphereCapturePhase.ready) {
      if (_holdTargetId != active.spec.targetId) {
        _holdTargetId = active.spec.targetId;
        _holdProgress = 0;
        _lastSampleAt = now;
      }
      if (activeError <= toleranceDeg) {
        final last = _lastSampleAt;
        final dtSeconds = last == null
            ? 0.0
            : (now.difference(last).inMicroseconds / 1e6).clamp(0.0, 0.1);
        _lastSampleAt = now;
        _holdProgress =
            (_holdProgress + dtSeconds / (holdDuration.inMilliseconds / 1000))
                .clamp(0.0, 1.0);
        // The hold proves the target is *centred*; the freeze gate proves the
        // phone has *stopped*. A still taken mid-sweep satisfies the cone for a
        // sample and still skews a vertical wall, so both are required. With no
        // gyroscope (tests, or a device without one) the gate is skipped rather
        // than blocking every capture.
        // SITEWISE_SEAM_POSE_INTEGRITY_20261121: angular stillness is not
        // evidence of a stationary viewpoint. Pause auto-shutter when the
        // accelerometer's motion window still reports translational movement.
        final frozen =
            (_angularVelocityStream == null || _freezeGate.still) && !_moving;
        if (_holdProgress >= 1.0 && !_capturing && frozen) {
          unawaited(_capture(active));
        }
      } else if (activeError > exitToleranceDeg) {
        _holdProgress = 0;
        _lastSampleAt = now;
      } else {
        // Inside the hysteresis band: the ring neither fills nor resets.
        _lastSampleAt = now;
      }
    }
    _notify();
  }

  void _onMotionSample(Vec3 acceleration) {
    _motionDetector.addSample(acceleration, _clock());
    final moving = _motionDetector.moving;
    if (moving == _moving) return;
    _moving = moving;
    _notify();
  }

  /// Feeds the freeze gate. Deliberately does not notify: the stream runs at
  /// ~50 Hz and rebuilding the overlay for it would cost more than it shows.
  void _onGyroSample(Vec3 rateRadPerSec) {
    _freezeGate.update(rateRadPerSec, _clock());
  }

  Future<void> _capture(SphereTargetState target) async {
    if (_capturing) return;
    if (_deviceToWorld == null) return;
    // SITEWISE_SEAM_POSE_INTEGRITY_20261121: the pose must be sampled near
    // the real shutter request, not before the CameraX queue-settling delay.
    // Captured photos retain an immutable pose even while sensors keep ticking.
    _capturing = true;
    _phase = SphereCapturePhase.capturing;
    _holdProgress = 0;
    _notify();
    try {
      // Let the pipeline flush before the shutter.
      //
      // CameraX keeps a small pool of in-flight buffers; on a device driven
      // hard by preview and stills the JPEG can be served from a frame captured
      // ~100-200 ms earlier — a pose the user has already left, which is one
      // half of the double-image overlay. 150 ms is longer than the buffer
      // queue's latency and short enough that the shutter does not feel slow.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      // SITEWISE_SEAM_POSE_INTEGRITY_20261121: refresh pose AFTER the
      // 150ms camera queue settle, at the moment the still is requested.
      // Earlier code only refreshed the error and recorded a stale quaternion,
      // creating a systematic mismatch between projection and JPEG content.
      final shutterDevice = _deviceToWorld;
      if (shutterDevice == null ||
          _activeTargetId != target.spec.targetId ||
          _activeErrorDeg > toleranceDeg ||
          _moving ||
          (_angularVelocityStream != null && !_freezeGate.still)) {
        _phase = SphereCapturePhase.ready;
        _message = 'Phone moved before the shutter. Hold still and retry.';
        return; // Keep the target uncaptured; the finally block resets state.
      }
      final errorAtShutter = _activeErrorDeg;
      final shutterAt = _clock();
      final raw = await _camera.takePicture();
      final normalized = await _normalize(raw);
      final path = await _repository.framePath(
        _stationId,
        target.spec.targetId,
      );
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(normalized.bytes, flush: true);
      final record = CaptureRecord(
        stationId: _stationId,
        targetId: target.spec.targetId,
        imagePath: path,
        capturedAt: shutterAt,
        targetYawDegrees: target.spec.yawDeg,
        targetPitchDegrees: target.spec.pitchDeg,
        // 3DoF measures no translation, so none is claimed. The position is
        // the sphere centre by definition and the orientation is the sensor
        // quaternion at the shutter.
        cameraPosition: Vec3.zero,
        cameraOrientation: shutterDevice,
        alignmentErrorDeg: errorAtShutter,
        anchored: false,
        imageWidth: normalized.width,
        imageHeight: normalized.height,
        sourceImageWidth: normalized.sourceWidth,
        sourceImageHeight: normalized.sourceHeight,
        cropOffsetX: normalized.cropOffsetX,
        cropOffsetY: normalized.cropOffsetY,
        imageFormat: 'jpeg',
        toleranceDeg: toleranceDeg,
      );
      await _repository.saveRecord(record);
      // Mirrored into SQLite after the JPEG and the JSON record exist. A
      // failure here loses bookkeeping only, never the photograph, so it must
      // not fail the capture.
      await _persistFrame(record);
      debugPrint(
        'SPHERE_CAPTURE: target ${target.spec.targetId} saved '
        '${normalized.width}x${normalized.height} '
        '(error ${errorAtShutter.toStringAsFixed(1)}°) -> $path',
      );
      _targets = <SphereTargetState>[
        for (final t in _targets)
          if (t.spec.targetId == target.spec.targetId)
            t.asCaptured(path)
          else
            t,
      ];
      // The stitch path continues from this frame: the next guide target is
      // the adjacent uncaptured direction, so consecutive photographs keep
      // overlapping content for the panorama.
      _lastCapturedDirection = target.spec.direction;
      _recomputeGuide();
      _message = normalized.warning;
      // Haptics are a courtesy, not evidence: a device that refuses them must
      // not turn a saved photograph into a reported failure.
      try {
        await _haptic();
      } catch (_) {
        // Ignored on purpose.
      }
      // The first photograph establishes the exposure and focus for the whole
      // sweep: AE/AF have now converged on the room rather than on whatever the
      // preview saw while it was starting.
      if (capturedCount == 1) {
        await _camera.lockCaptureSettings();
      }
      _banner = 'Captured!';
      _bannerTimer?.cancel();
      _bannerTimer = Timer(const Duration(milliseconds: 1400), () {
        _banner = null;
        _notify();
      });
      if (capturedCount >= kSphereTargetCount) {
        _phase = SphereCapturePhase.complete;
        _notify();
        unawaited(_stitch());
      } else {
        _phase = SphereCapturePhase.ready;
      }
    } on CaptureFailure catch (error) {
      _phase = SphereCapturePhase.ready;
      _message = error.message;
    } catch (error) {
      _phase = SphereCapturePhase.ready;
      _message =
          'The photograph could not be saved, so the target stays open: '
          '${_describe(error)}';
    } finally {
      _capturing = false;
      _notify();
    }
  }

  /// Reopens the camera after Android reclaimed it.
  ///
  /// A backgrounded app loses the camera to the OS; without this the preview
  /// stays black on return even though the sphere, the sensor and the saved
  /// station are all still valid. The start pose is deliberately not reset:
  /// `q₀` is a device→world orientation, which backgrounding does not change.
  Future<void> handleAppLifecycle(AppLifecycleState state) async {
    if (_phase != SphereCapturePhase.ready &&
        _phase != SphereCapturePhase.capturing &&
        _phase != SphereCapturePhase.complete) {
      return;
    }
    if (state == AppLifecycleState.paused) {
      // Closing mid-capture would fail a photograph that is already being
      // written; the shutter owns the camera until it finishes.
      if (_capturing) return;
      await _camera.close();
      return;
    }
    if (state == AppLifecycleState.resumed && !_camera.isOpen) {
      try {
        await _camera.open();
        _notify();
      } catch (error) {
        _message =
            'The camera could not be reopened after returning to the app: '
            '${_describe(error)}';
        _notify();
      }
    }
  }

  /// Re-runs validation and stitching against the records on disk.
  Future<void> retryStitching() async {
    if (_stitching) return;
    _stitchError = null;
    await _stitch();
  }

  /// Starts a stitch, or joins the one already running.
  ///
  /// Joining matters for Save & Finish: tapping it while the completion modal
  /// is still stitching must export the panorama that is about to exist, not
  /// silently omit it.
  Future<void> _stitch() {
    final inFlight = _stitchFuture;
    if (inFlight != null) return inFlight;
    final future = _runStitch();
    _stitchFuture = future;
    return future.whenComplete(() => _stitchFuture = null);
  }

  Future<void> _runStitch() async {
    _stitching = true;
    _stitchStage = 'Preparing the $kSphereTargetCount photographs…';
    _notify();
    try {
      final records = await _repository.loadRecords(_stationId);
      final result = await PanoramaGenerationService(_stitcher).generate(
        records: records,
        total: kSphereTargetCount,
        onStage: (String stage) {
          _stitchStage = stage;
          _notify();
        },
      );
      if (result.success && result.panoramaPath != null) {
        _panoramaPath = result.panoramaPath;
        _stitchError = null;
        debugPrint('SPHERE_STITCH: panorama at ${result.panoramaPath}');
        // Persist the panorama and queue it for upload before the Gallery copy:
        // the Gallery is a convenience, the cloud copy is the deliverable, and
        // the local file is already safely on disk either way.
        await _recordPanorama(result.panoramaPath!);
        // A Gallery copy is what the user can actually find in Photos. Its
        // failure must not turn a successful stitch into an error.
        try {
          _galleryPath = await _gallery.savePanorama(
            sourcePath: result.panoramaPath!,
            stationId: _stationId,
          );
        } catch (error) {
          debugPrint('GALLERY_SAVE: $error');
        }
        // Offered to the network in the background: the completion sheet is
        // usable while the upload runs, and a failure leaves a queued row
        // rather than an error the user has to dismiss.
        unawaited(_autoSync());
      } else {
        _stitchError = result.message;
        await _recordPanoramaFailure(result.message);
        debugPrint('SPHERE_STITCH: failed: ${result.message}');
      }
    } catch (error) {
      _stitchError = 'The panorama could not be generated: $error';
    } finally {
      _stitching = false;
      _stitchStage = null;
      _notify();
    }
  }

  /// Copies the 38 JPEGs, the panorama and a manifest into a user-reachable
  /// export folder, and returns its path.
  Future<String?> saveAndFinish() async {
    if (_exporting) return null;
    _exporting = true;
    _notify();
    try {
      // Wait for a stitch already in flight, then start one if the panorama is
      // still missing. A second stitch is never started over a first.
      final inFlight = _stitchFuture;
      if (inFlight != null) await inFlight;
      if (_panoramaPath == null) await _stitch();
      // A station stitched before this build may already have a panorama but
      // no Gallery copy; saving here makes Save & Finish consistent.
      if (_galleryPath == null && _panoramaPath != null) {
        try {
          _galleryPath = await _gallery.savePanorama(
            sourcePath: _panoramaPath!,
            stationId: _stationId,
          );
        } catch (error) {
          debugPrint('GALLERY_SAVE: $error');
        }
      }
      final path = await _export(
        stationId: _stationId,
        targets: _targets,
        panoramaPath: _panoramaPath,
      );
      _exportPath = path;
      return path;
    } catch (error) {
      _message = 'The export failed: $error';
      return null;
    } finally {
      _exporting = false;
      _notify();
    }
  }

  /// Chooses the next target in the capture path and measures its overlap.
  ///
  /// ## The route
  ///
  /// The order is the layout's own: middle ring, zenith, upper ring, lower
  /// ring, nadir. That is the sequence the progress pill counts through, so the
  /// arrow and the pill cannot disagree — and it is also the shortest possible
  /// **maximum** step, which is what keeps every guided turn predictable:
  ///
  /// | step | angle | why |
  /// |---|---|---|
  /// | within a ring | 30° | 12 targets over 360° |
  /// | middle → zenith | 90° | a pole is 90° from *every* horizon target |
  /// | zenith → upper | 55° | 90° − 35° |
  /// | upper → lower | 70° | 35° above to 35° below |
  /// | lower → nadir | 55° | 90° − 35° |
  ///
  /// Any route must pay at least one 90° step to reach a pole, because the
  /// zenith is 90° from every non-pole direction. This order pays two — one per
  /// pole — and nothing above 90°. Sweeping the upper ring *before* the zenith
  /// would trade the 90° climb for a 135° descent to the lower ring, which is
  /// strictly worse; that is why the zenith sits at id 13 rather than after the
  /// upper ring.
  ///
  /// ## Why it also writes the active target
  ///
  /// `_guideTargetId` and `_activeTargetId` are two views of one decision, and
  /// they used to be updated at different times: the guide changed the instant a
  /// photograph was saved, while the active target waited for the next 50 Hz
  /// rotation sample. For those ~20 ms the arrow pointed at target 5 while the
  /// marker, pill and alignment error still described target 4. Writing both
  /// here removes the window entirely, so "the arrow and the shutter disagree"
  /// cannot happen even transiently.
  ///
  /// [guideSeparationDeg] is the angle from the **last captured frame's
  /// centre** to this target — the number that decides how much content two
  /// consecutive frames share. At 30° within a ring it is ~40% of a 50°
  /// horizontal field of view; at the 90° ring transitions it is 0, which is
  /// exactly the two seams the panorama has to blend across.
  void _recomputeGuide() {
    final last = _lastCapturedDirection;
    SphereTargetState? next;
    for (final target in _targets) {
      if (!target.captured) {
        next = target;
        break;
      }
    }
    _guideTargetId = next?.spec.targetId;
    _guideSeparationDeg = next == null || last == null
        ? 0
        : angleBetweenDeg(last, next.spec.direction);

    final device = _deviceToWorld;
    final start = _startDeviceToWorld;
    if (next == null || device == null || start == null) {
      _activeTargetId = next?.spec.targetId;
      _activeErrorDeg = 180;
      _guideErrorDeg = 180;
      _guideTurnDeg = 0;
      _guidePitchDeg = 0;
      _guideBehind = false;
    } else {
      final direction = sphereTargetCameraDirection(
        deviceToWorld: device,
        startDeviceToWorld: start,
        startDirection: next.spec.direction,
      );
      _activeTargetId = next.spec.targetId;
      _activeErrorDeg = reticleErrorDeg(direction);
      _guideErrorDeg = _activeErrorDeg;
      _guideTurnDeg = math.atan2(direction.x, -direction.z) * radToDeg;
      _guidePitchDeg =
          math.asin(clampDouble(direction.y, -1, 1)) * radToDeg;
      _guideBehind = direction.z > 0;
    }
    // The new target has not been held yet. Clearing the bookkeeping rather
    // than zeroing the progress makes the next sample start a fresh hold, which
    // is what stops a half-filled ring carrying over from the previous target.
    _holdTargetId = null;
    _holdProgress = 0;
    _lastSampleAt = null;
  }

  /// Creates the session row, or restores the one already there, and repopulates
  /// the target states from what is on disk.
  ///
  /// This is the "close the app and come back" path. It is deliberately the
  /// first thing `start()` does, before permissions and before the camera: a
  /// session that cannot be recorded is worth knowing about before the user
  /// spends two minutes capturing, and a restored session lets them see their
  /// progress immediately.
  Future<void> _ensureSession() async {
    final store = _sessions;
    if (store == null) return;
    try {
      final session = await store.createSession(
        sessionId: _stationId,
        userId: _userId,
        propertyId: _propertyId,
      );
      // A session created on a previous launch already knows its property; the
      // in-memory value must follow it, or the upload would be queued without
      // an association.
      _propertyId ??= session.propertyId;
      _userId ??= session.userId;
      await restoreFromStore();
      _syncRecord = await store.getPanorama(_stationId);
      _notify();
    } catch (error) {
      // Local metadata is not worth failing a capture over. The JSON records the
      // stitcher reads are written by `_repository` regardless.
      debugPrint('SPHERE_SESSION: could not open session $_stationId: $error');
    }
  }

  /// Marks the targets whose photographs are already saved as captured.
  ///
  /// A frame is only restored when its JPEG is still on disk: a row whose file
  /// has been deleted describes evidence that no longer exists, and treating it
  /// as captured would let the user reach 38 targets with 37 usable frames.
  Future<void> restoreFromStore() async {
    final store = _sessions;
    if (store == null) return;
    final frames = await store.loadFrames(_stationId);
    if (frames.isEmpty) return;

    final byTarget = <int, CapturedFrame>{
      for (final frame in frames) frame.targetId: frame,
    };
    final restored = <SphereTargetState>[];
    for (final target in _targets) {
      final frame = byTarget[target.spec.targetId];
      if (frame != null && File(frame.imagePath).existsSync()) {
        restored.add(target.asCaptured(frame.imagePath));
      } else {
        restored.add(SphereTargetState(spec: target.spec));
      }
    }
    _targets = restored;

    // The stitch path continues from the last saved frame, so the guide arrow
    // points at the next target in sequence rather than back at target 1.
    final capturedIds = <int>[
      for (final target in _targets)
        if (target.captured) target.spec.targetId,
    ]..sort();
    if (capturedIds.isNotEmpty) {
      final lastId = capturedIds.last;
      for (final spec in buildSphereTargets()) {
        if (spec.targetId == lastId) {
          _lastCapturedDirection = spec.direction;
          break;
        }
      }
    }

    final session = await store.getSession(_stationId);
    if (session != null) {
      // The property association and owner are part of the session, not of this
      // launch: a capture resumed tomorrow must still know which building its
      // panorama belongs to.
      _propertyId ??= session.propertyId;
      _userId ??= session.userId;
      if (session.hasPanorama) {
        _panoramaPath = session.localPanoramaPath;
      }
      if (session.panoramaStatus == PanoramaGenerationStatus.failed) {
        _stitchError = session.lastError;
      }
    }
    // The cloud state is part of what a reopen has to restore: a panorama that
    // failed to upload must come back with its error and its Retry, not as a
    // fresh "not uploaded yet".
    _syncRecord = await store.getPanorama(_stationId);

    if (capturedCount >= kSphereTargetCount) {
      _phase = SphereCapturePhase.complete;
    }
    _recomputeGuide();
    debugPrint(
      'SPHERE_SESSION: restored $capturedCount/$kSphereTargetCount targets for '
      '$_stationId',
    );
  }

  /// Mirrors a saved JPEG into SQLite.
  ///
  /// Runs **after** the file and the JSON record exist, so a metadata failure
  /// can only ever lose bookkeeping, never a photograph.
  Future<void> _persistFrame(CaptureRecord record) async {
    final store = _sessions;
    if (store == null) return;
    try {
      await store.saveFrame(CapturedFrame.fromCaptureRecord(record));
      if (capturedCount >= kSphereTargetCount) {
        await store.markSessionStatus(
          sessionId: _stationId,
          status: CaptureSessionStatus.complete,
        );
      }
    } catch (error) {
      debugPrint(
        'SPHERE_SESSION: target ${record.targetId} could not be recorded in '
        'SQLite: $error',
      );
    }
  }

  /// Records the stitched panorama and queues it for upload.
  Future<void> _recordPanorama(String panoramaPath) async {
    final store = _sessions;
    if (store == null) return;
    try {
      _syncRecord = await store.savePanorama(
        sessionId: _stationId,
        localPanoramaPath: panoramaPath,
        status: PanoramaGenerationStatus.ready,
      );
      // `savePanorama` already writes the pending row; this makes the intent
      // explicit and is a no-op when the row is already queued.
      await store.markUploadPending(_stationId);
      _syncRecord = await store.getPanorama(_stationId);
    } catch (error) {
      debugPrint('SPHERE_SESSION: panorama could not be recorded: $error');
    }
  }

  Future<void> _recordPanoramaFailure(String? message) async {
    final store = _sessions;
    if (store == null) return;
    try {
      _syncRecord = await store.savePanorama(
        sessionId: _stationId,
        localPanoramaPath: null,
        status: PanoramaGenerationStatus.failed,
        error: message,
      );
    } catch (error) {
      debugPrint('SPHERE_SESSION: panorama failure not recorded: $error');
    }
  }

  /// Offers the finished panorama to the upload queue.
  ///
  /// Automatic, and deliberately quiet: a device with no session or no network
  /// leaves a queued row behind, and nothing about the user's capture changes.
  Future<void> _autoSync() async {
    final sync = _sync;
    if (sync == null) return;
    _syncing = true;
    _notify();
    try {
      _lastSyncAttempt = await sync.syncSession(_stationId);
      _syncRecord = await _sessions?.getPanorama(_stationId) ?? _syncRecord;
    } catch (error) {
      debugPrint('SPHERE_SYNC: $error');
    } finally {
      _syncing = false;
      _notify();
    }
  }

  /// The user-initiated retry: re-arms a blocked row and ignores the backoff.
  Future<void> retrySync() async {
    final sync = _sync;
    if (sync == null || _syncing) return;
    _syncing = true;
    _notify();
    try {
      _lastSyncAttempt = await sync.retry(_stationId);
      _syncRecord = await _sessions?.getPanorama(_stationId) ?? _syncRecord;
    } catch (error) {
      debugPrint('SPHERE_SYNC: retry failed: $error');
    } finally {
      _syncing = false;
      _notify();
    }
  }

  /// Attaches the property this session's panorama belongs to.
  ///
  /// The association is chosen before upload; the server still verifies it
  /// before storing a byte.
  Future<void> attachProperty(int propertyId) async {
    _propertyId = propertyId;
    try {
      await _sessions?.attachProperty(
        sessionId: _stationId,
        propertyId: propertyId,
      );
    } catch (error) {
      debugPrint('SPHERE_SESSION: property association not recorded: $error');
    }
    _notify();
  }

  String _describe(Object error) {
    if (error is CaptureFailure) return error.message;
    if (error is CameraException) {
      return error.description ?? error.code;
    }
    return '$error';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _bannerTimer?.cancel();
    unawaited(_rotationSubscription?.cancel());
    unawaited(_motionSubscription?.cancel());
    unawaited(_gyroSubscription?.cancel());
    unawaited(_rotation.stop());
    // Release the locks before closing: the next session must not inherit this
    // room's exposure.
    unawaited(_camera.unlockCaptureSettings());
    unawaited(_camera.close());
    super.dispose();
  }
}

/// Writes the finished station to a folder the user can find.
typedef SphereExporter =
    Future<String> Function({
      required String stationId,
      required List<SphereTargetState> targets,
      required String? panoramaPath,
    });

Future<String> _defaultExport({
  required String stationId,
  required List<SphereTargetState> targets,
  required String? panoramaPath,
}) async {
  final base =
      await getExternalStorageDirectory() ??
      await getApplicationDocumentsDirectory();
  final directory = Directory(p.join(base.path, 'SiteWise360', stationId));
  final frames = Directory(p.join(directory.path, 'frames'));
  await frames.create(recursive: true);

  final manifest = <Map<String, Object?>>[];
  for (final target in targets) {
    final source = target.imagePath;
    if (!target.captured || source == null) continue;
    final name = 't${target.spec.targetId.toString().padLeft(2, '0')}.jpg';
    await File(source).copy(p.join(frames.path, name));
    manifest.add(<String, Object?>{
      'targetId': target.spec.targetId,
      'ring': target.spec.ringName,
      'yawDeg': target.spec.yawDeg,
      'pitchDeg': target.spec.pitchDeg,
      'file': 'frames/$name',
    });
  }
  String? panoramaName;
  if (panoramaPath != null && await File(panoramaPath).exists()) {
    panoramaName = 'panorama.jpg';
    await File(panoramaPath).copy(p.join(directory.path, panoramaName));
  }
  await File(p.join(directory.path, 'capture.json')).writeAsString(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'stationId': stationId,
      'architecture': '3DoF sphere-follows-phone',
      'targetCount': kSphereTargetCount,
      'capturedCount': manifest.length,
      'panorama': panoramaName,
      'targets': manifest,
      'exportedAt': DateTime.now().toIso8601String(),
    }),
    flush: true,
  );
  return directory.path;
}
