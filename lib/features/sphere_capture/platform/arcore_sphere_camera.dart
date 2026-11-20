import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:adaptive_360_capture_app/features/sphere_capture/platform/rotation_sensor.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/platform/sphere_camera.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/ar_types.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/platform/arcore_ar.dart';

/// Camera and orientation source that share ONE ARCore camera session.
/// CameraX cannot be opened while ARCore owns the camera. The session's raw
/// camera-to-world quaternion uses +Y up and -Z forward, matching the sphere
/// projector; do NOT apply the virtual-tour's +Z-forward conversion here.
///
/// No manual plane scan and no surface placement are required: the fixed
/// station is the first reliable camera position in ARCore's local world.
class ArCoreSphereCamera implements SphereCamera, RotationSource {
  ArCoreSphereCamera({ArCoreGateway? gateway}) : _gateway = gateway ?? ArCoreHost();

  final ArCoreGateway _gateway;
  final StreamController<Quat> _rotations = StreamController<Quat>.broadcast();
  final StreamController<SphereCameraPose> _tracked =
      StreamController<SphereCameraPose>.broadcast();
  StreamSubscription<ArCoreEvent>? _events;
  ArCoreSession? _session;
  bool _open = false;
  SphereCameraPose? _lastPose;
  SphereCameraPose? _lastShot;
  bool _disposed = false;

  @override
  Stream<Quat> get rotations => _rotations.stream;
  @override
  Vec3 get worldUp => Vec3.unitY;
  @override
  Stream<SphereCameraPose>? get trackedPoses => _tracked.stream;
  @override
  SphereCameraPose? get lastCapturePose => _lastShot;
  @override
  bool get isOpen => _open;
  @override
  double? get previewAspectRatio => 9 / 16;

  void _onEvent(ArCoreEvent event) {
    if (event.type == ArCoreEventType.error) {
      if (event.fatal) {
        _lastPose = null;
        if (!_rotations.isClosed) {
          _rotations.addError(StateError(event.message ?? 'ARCore tracking failed.'));
        }
      }
      return;
    }
    final sample = event.pose;
    if (event.type != ArCoreEventType.pose || sample == null) return;
    final pose = SphereCameraPose(
      position: sample.position,
      orientation: sample.raw.orientation,
      tracking: sample.tracking == TrackingState.tracking &&
          !sample.trackingTransition,
      timestampNs: sample.raw.timestampNs,
    );
    _lastPose = pose;
    if (!_tracked.isClosed) _tracked.add(pose);
    if (pose.tracking && !_rotations.isClosed) {
      _rotations.add(pose.orientation);
    }
  }

  @override
  Future<void> open() async {
    if (_open) return;
    if (_disposed) throw StateError('This ARCore camera has been disposed.');
    if (_session != null) {
      await _gateway.resume();
      _lastPose = null;
      _lastShot = null;
      _open = true;
      return;
    }
    final availability = await _gateway.checkAvailability();
    if (!availability.usable) {
      if (availability.supported && !availability.serviceInstalled) {
        final install = await _gateway.requestInstall();
        if (!install.installed) {
          throw StateError('Install Google Play Services for AR and retry.');
        }
      } else {
        throw StateError(
          availability.reason ?? 'This device does not support ARCore tracking.',
        );
      }
    }
    _events = _gateway.events.listen(_onEvent);
    try {
      final started = await _gateway.start(width: 720, height: 1280, planes: false);
      if (!started.canShoot || started.textureId < 0) {
        throw StateError('ARCore does not expose a usable camera image.');
      }
      _session = started;
      _open = true;
    } catch (_) {
      await _events?.cancel();
      _events = null;
      await _gateway.stop();
      rethrow;
    }
  }

  @override
  Widget preview() {
    final session = _session;
    if (!_open || session == null) return const SizedBox.shrink();
    return Texture(textureId: session.textureId);
  }

  @override
  Future<void> ensurePreviewReady({Duration timeout = const Duration(seconds: 3)}) async {
    final limit = DateTime.now().add(timeout);
    while ((_lastPose == null || !_lastPose!.tracking) &&
        DateTime.now().isBefore(limit)) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    if (_lastPose == null || !_lastPose!.tracking) {
      throw StateError('AR tracking is not ready. Point at a detailed area and move slowly.');
    }
  }

  @override
  Future<Uint8List> takePicture() async {
    if (!_open || _lastPose?.tracking != true) {
      throw StateError('AR tracking was lost. Hold the phone still and retry.');
    }
    _lastShot = null;
    final shot = await _gateway.takeStill(quality: 95);
    final pose = shot.capturePose;
    if (pose == null || pose.tracking != TrackingState.tracking) {
      throw StateError('This photograph has no valid shutter-time AR pose. Retake it.');
    }
    _lastShot = SphereCameraPose(
      position: pose.position,
      orientation: pose.orientation,
      tracking: true,
      timestampNs: pose.timestampNs,
    );
    return shot.jpeg;
  }

  @override
  Future<void> lockCaptureSettings() async {
    // ARCore owns exposure/focus; do not invoke CameraX on the same device.
  }

  @override
  Future<void> unlockCaptureSettings() async {}

  @override
  Future<void> close() async {
    if (!_open) return;
    await _gateway.pause();
    _open = false;
    _lastPose = null;
  }

  @override
  Future<void> start() async {
    // Pose EventChannel is already subscribed by open(), before previewReady.
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    _disposed = true;
    await _events?.cancel();
    _events = null;
    await _gateway.stop();
    _open = false;
    _session = null;
    await _rotations.close();
    await _tracked.close();
  }
}
