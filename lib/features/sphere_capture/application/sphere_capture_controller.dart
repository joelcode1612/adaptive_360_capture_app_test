// Named parameters are deliberately not `this._field`: a private named
// parameter cannot be used by callers outside this library, so the public
// constructor reads `rotation:` rather than `_rotation:`.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
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
import 'package:adaptive_360_capture_app/features/sphere_capture/data/gallery_saver.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/data/jpeg_normalizer.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/motion_detector.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_projection.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
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
    Stream<Vec3>? motion,
    PermissionService? permissions,
    Future<void> Function()? haptic,
    DateTime Function()? clock,
    Future<NormalizedJpeg> Function(Uint8List bytes)? normalize,
    SphereExporter? export,
    GallerySaver? gallerySaver,
    this.toleranceDeg = kSphereAlignmentToleranceDeg,
    this.exitToleranceDeg = kSphereAlignmentExitDeg,
    this.holdDuration = const Duration(milliseconds: 600),
  }) : _rotation = rotation,
       _camera = camera,
       _repository = repository,
       _stitcher = stitcher,
       _stationId = stationId,
       _motionStream = motion,
       _permissions = permissions ?? PermissionService(),
       _haptic = haptic ?? HapticFeedback.mediumImpact,
       _clock = clock ?? DateTime.now,
       _normalize = normalize ?? const JpegNormalizer().normalize,
       _export = export ?? _defaultExport,
       _gallery = gallerySaver ?? const GallerySaver();

  final RotationSource _rotation;
  final SphereCamera _camera;
  final CaptureRepository _repository;
  final PanoramaStitcher _stitcher;
  final String _stationId;
  final Stream<Vec3>? _motionStream;
  final PermissionService _permissions;
  final Future<void> Function() _haptic;
  final DateTime Function() _clock;
  final Future<NormalizedJpeg> Function(Uint8List bytes) _normalize;
  final SphereExporter _export;
  final GallerySaver _gallery;

  /// The alignment cone that turns a target green and fills the ring.
  final double toleranceDeg;

  /// The angle past which a filling hold is discarded.
  final double exitToleranceDeg;

  /// How long the target must stay inside [toleranceDeg] before the shutter.
  final Duration holdDuration;

  final MotionDetector _motionDetector = MotionDetector();

  List<SphereTargetState> _targets = <SphereTargetState>[
    for (final SphereTargetSpec spec in buildSphereTargets())
      SphereTargetState(spec: spec),
  ];

  SphereCapturePhase _phase = SphereCapturePhase.idle;
  String? _message;
  Quat? _deviceToWorld;
  Quat? _startDeviceToWorld;
  int? _activeTargetId;
  double _activeErrorDeg = 180;
  double _holdProgress = 0;
  int? _holdTargetId;
  DateTime? _lastSampleAt;
  Vec3? _lastCapturedDirection;
  int? _guideTargetId;
  double _guideSeparationDeg = 180;
  double _guideErrorDeg = 180;
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

  Quat? get deviceToWorld => _deviceToWorld;

  /// The device orientation captured when the sphere was anchored to the
  /// phone, i.e. `q₀` in `q⁻¹ · (q₀ · v_S)`.
  Quat? get startDeviceToWorld => _startDeviceToWorld;

  /// The station directory name, for the export manifest and diagnostics.
  String get stationId => _stationId;

  /// The target the arrow points at: the next frame in the stitch path.
  ///
  /// This is deliberately not the same thing as [activeTarget]. The active
  /// target is whatever the user is pointing at right now and owns the hold
  /// ring; the guide target is the adjacent uncaptured direction that keeps
  /// consecutive photographs overlapping. Following the arrow therefore also
  /// keeps the panorama stitchable.
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

  /// `Target 1 / 38 — Middle Ring (0°)`, or the completion sentence.
  String get progressLabel {
    final target = guideTarget ?? activeTarget;
    if (target == null) {
      return 'All $kSphereTargetCount targets captured';
    }
    return target.spec.progressLabel;
  }

  /// The sentence above the progress pill.
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
      return 'Hold steady — capturing '
          '${activeTarget?.spec.shortName ?? target.spec.shortName}.';
    }
    final warning = guideOverlapFraction < 0.05
        ? ' Almost no overlap with the previous frame — the panorama may '
              'seam here.'
        : '';
    return 'Follow the arrow to ${target.spec.shortName} '
        '(${_guideErrorDeg.toStringAsFixed(0)}°).$warning';
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
    _holdProgress = 0;
    _holdTargetId = null;
    _lastSampleAt = null;
    _lastCapturedDirection = null;
    _guideTargetId = null;
    _guideSeparationDeg = 180;
    _guideErrorDeg = 180;
    _galleryPath = null;
    _notify();
    try {
      await _permissions.ensureCapturePermissions();
      await _camera.open();
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
      _phase = SphereCapturePhase.ready;
      _recomputeGuide();
      _message = 'Point the phone at a target and hold it inside the ring.';
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
    if (_phase != SphereCapturePhase.ready &&
        _phase != SphereCapturePhase.capturing) {
      return;
    }
    _deviceToWorld = quaternion;
    _startDeviceToWorld ??= quaternion;
    final start = _startDeviceToWorld;
    if (start == null) return;
    if (!_loggedFirstSample) {
      _loggedFirstSample = true;
      debugPrint(
        'SPHERE_SENSOR: first rotation '
        'q=(${quaternion.x.toStringAsFixed(4)}, '
        '${quaternion.y.toStringAsFixed(4)}, '
        '${quaternion.z.toStringAsFixed(4)}, '
        '${quaternion.w.toStringAsFixed(4)})',
      );
    }

    final now = _clock();
    SphereTargetState? nearest;
    var nearestError = 180.0;
    for (final target in _targets) {
      if (target.captured) continue;
      final direction = sphereTargetCameraDirection(
        deviceToWorld: quaternion,
        startDeviceToWorld: start,
        startDirection: target.spec.direction,
      );
      final error = reticleErrorDeg(direction);
      if (error < nearestError) {
        nearestError = error;
        nearest = target;
      }
    }

    _activeTargetId = nearest?.spec.targetId;
    _activeErrorDeg = nearestError;

    // The guide target is independent of what the user is aiming at: it is the
    // next frame in the overlap-preserving stitch path. Its live error is what
    // the guidance sentence and the edge arrow report.
    final guide = guideTarget;
    if (guide != null) {
      _guideErrorDeg = reticleErrorDeg(
        sphereTargetCameraDirection(
          deviceToWorld: quaternion,
          startDeviceToWorld: start,
          startDirection: guide.spec.direction,
        ),
      );
    }

    if (nearest != null && _phase == SphereCapturePhase.ready) {
      if (_holdTargetId != nearest.spec.targetId) {
        _holdTargetId = nearest.spec.targetId;
        _holdProgress = 0;
        _lastSampleAt = now;
      }
      if (nearestError <= toleranceDeg) {
        final last = _lastSampleAt;
        final dtSeconds = last == null
            ? 0.0
            : (now.difference(last).inMicroseconds / 1e6).clamp(0.0, 0.1);
        _lastSampleAt = now;
        _holdProgress =
            (_holdProgress + dtSeconds / (holdDuration.inMilliseconds / 1000))
                .clamp(0.0, 1.0);
        if (_holdProgress >= 1.0 && !_capturing) {
          unawaited(_capture(nearest));
        }
      } else if (nearestError > exitToleranceDeg) {
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

  Future<void> _capture(SphereTargetState target) async {
    if (_capturing) return;
    final device = _deviceToWorld;
    if (device == null) return;
    // The evidence must describe the instant the shutter was authorised, not
    // the instant the JPEG finished encoding: rotation samples keep arriving
    // during `takePicture`, and reading the live field afterwards would record
    // an angle the user had already turned away from.
    final errorAtShutter = _activeErrorDeg;
    _capturing = true;
    _phase = SphereCapturePhase.capturing;
    _holdProgress = 0;
    _notify();
    try {
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
        capturedAt: _clock(),
        targetYawDegrees: target.spec.yawDeg,
        targetPitchDegrees: target.spec.pitchDeg,
        // 3DoF measures no translation, so none is claimed. The position is
        // the sphere centre by definition and the orientation is the sensor
        // quaternion at the shutter.
        cameraPosition: Vec3.zero,
        cameraOrientation: device,
        alignmentErrorDeg: errorAtShutter,
        anchored: false,
        imageWidth: normalized.width,
        imageHeight: normalized.height,
        sourceImageWidth: normalized.width,
        sourceImageHeight: normalized.height,
        imageFormat: 'jpeg',
        toleranceDeg: toleranceDeg,
      );
      await _repository.saveRecord(record);
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
      } else {
        _stitchError = result.message;
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
  /// The order is the layout's own: middle ring, upper ring, lower ring, then
  /// the poles. That is the sequence the progress pill counts through, so the
  /// arrow and the pill cannot disagree.
  ///
  /// [guideSeparationDeg] is the angle from the **last captured frame's
  /// centre** to this target — the number that decides whether the stitcher
  /// will find matching content. Within a ring it is 30°; between rings it is
  /// 45°, which is ~35% overlap against the camera's ~69° vertical field of
  /// view. A 90° step only occurs at the pole and the hemisphere transition.
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
    unawaited(_rotation.stop());
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
