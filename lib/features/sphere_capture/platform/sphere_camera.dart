// SITEWISE_360_BRANCH_PARALLAX_V1
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/vectors.dart';

/// The camera surface the sphere flow needs, and nothing more.
///
/// Deliberately narrow so the capture controller can be driven by a fake in
/// tests: preview, one full-resolution still, and a lifecycle. The ARCore
/// still path is not involved — there is no AR session holding the sensor, so
/// the ordinary `camera` plugin can open it directly.
/// A single ARCore camera-to-world pose, in the OpenGL -Z-forward basis used
/// by the sphere projection. CameraX does not provide this position evidence.
class SphereCameraPose {
  const SphereCameraPose({
    required this.position,
    required this.orientation,
    required this.tracking,
    this.timestampNs,
  });
  final Vec3 position;
  final Quat orientation;
  final bool tracking;
  final int? timestampNs;
}

abstract class SphereCamera {
  /// Opens the rear camera at its highest still resolution.
  Future<void> open();

  bool get isOpen;

  /// Null for CameraX (no translation measurement); live ARCore 6DoF otherwise.
  Stream<SphereCameraPose>? get trackedPoses => null;

  /// Exact ARCore shutter pose when available; null for CameraX.
  SphereCameraPose? get lastCapturePose => null;

  /// Preview width ÷ height in portrait, or `null` before [open].
  double? get previewAspectRatio;

  /// The live preview, sized to cover its parent.
  Widget preview();

  /// One full-resolution JPEG.
  Future<Uint8List> takePicture();

  /// Locks exposure and focus so the whole sweep shares one tone and one focal
  /// plane.
  ///
  /// Called once the first photograph is in: by then the auto-exposure loop has
  /// converged on real content, so the locked values describe the room rather
  /// than whatever the camera happened to be pointing at while the preview
  /// started. Locking earlier would freeze a mid-convergence exposure and make
  /// every one of the 38 frames wrong together, which is worse than varying.
  ///
  /// Default body does nothing, so a fake camera needs no implementation.
  Future<void> lockCaptureSettings() async {}

  /// Releases the locks, returning the camera to auto. Called when the session
  /// ends, so a later capture is not stuck with this room's exposure.
  Future<void> unlockCaptureSettings() async {}

  Future<void> close();

  /// Completes once the camera is open **and its preview has had a chance to
  /// render its first frame**.
  ///
  /// The capture controller takes its reference heading only after this
  /// completes. Taking it earlier described a phone pose from before the user
  /// could see anything, so target 1 was anchored to wherever the phone was
  /// mid-lift and then sat 20–40° outside the viewfinder once the preview
  /// appeared.
  ///
  /// The default body covers fakes that have no texture: wait for [isOpen],
  /// then one compositor frame. [PluginSphereCamera] overrides it with a
  /// stricter wait on the real controller.
  Future<void> ensurePreviewReady({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!isOpen && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (DateTime.now().isBefore(deadline)) {
      await SchedulerBinding.instance.endOfFrame;
    }
  }
}

/// The production camera: `camera` (CameraX on Android), rear lens, no audio.
///
/// `ResolutionPreset.max` is requested because the specification asks for a
/// 4:3 still in the 4032 × 3024 class. CameraX picks the largest available
/// still size, which is normally the sensor's native 4:3; the controller then
/// measures the actual JPEG and crops only if the device returned something
/// else. Nothing here claims a resolution the hardware did not deliver.
class PluginSphereCamera implements SphereCamera {
  CameraController? _controller;

  @override
  bool get isOpen => _controller?.value.isInitialized ?? false;

  @override
  double? get previewAspectRatio {
    final size = _controller?.value.previewSize;
    if (size == null || size.width <= 0) return null;
    // `previewSize` is landscape-first; the app is portrait-locked, so the
    // ratio the layout wants is the reciprocal.
    return size.height / size.width;
  }

  @override
  Future<void> open() async {
    if (isOpen) return;
    // A previous controller may exist but never have initialised (a failed
    // attempt). Dispose it rather than overwriting the reference.
    final previous = _controller;
    _controller = null;
    await previous?.dispose();
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw CameraException('no_camera', 'This device reports no camera.');
    }
    final back = cameras.firstWhere(
      (CameraDescription camera) =>
          camera.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      back,
      ResolutionPreset.max,
      enableAudio: false,
    );
    // Publish the controller *before* `initialize()` so the preview widget has
    // a listenable to attach to. Building the preview after the await instead
    // left it showing the black placeholder forever: the camera opened, but
    // the widget that had already decided "not open" was never rebuilt.
    _controller = controller;
    try {
      await controller.initialize();
      try {
        await controller.setFlashMode(FlashMode.off);
      } on CameraException {
        // Some devices expose no flash; the still is unaffected.
      }
    } catch (_) {
      _controller = null;
      rethrow;
    }
  }

  @override
  Widget preview() {
    final controller = _controller;
    if (controller == null) {
      return const ColoredBox(color: Colors.black);
    }
    // Reactive on purpose: `open()` publishes the controller before it
    // finishes initialising, so this rebuilds from the placeholder to the
    // live texture exactly when the camera becomes ready.
    return ValueListenableBuilder<CameraValue>(
      valueListenable: controller,
      builder: (BuildContext context, CameraValue value, Widget? child) {
        if (!value.isInitialized) {
          return const ColoredBox(color: Colors.black);
        }
        final size = value.previewSize;
        if (size == null || size.width <= 0 || size.height <= 0) {
          return CameraPreview(controller);
        }
        final portraitAspect = size.height / size.width;
        // A fixed logical box that already has the preview's portrait aspect,
        // then scaled to cover: FittedBox does the cover maths without
        // distorting the sensor image, which a stretched SizedBox would.
        return ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: 1000,
              height: 1000 / portraitAspect,
              child: CameraPreview(controller),
            ),
          ),
        );
      },
    );
  }

  /// Locks AE and AF. Both calls are best-effort: a device that refuses one
  /// still gets the other, and a device that refuses both still captures.
  @override
  Future<void> lockCaptureSettings() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.setExposureMode(ExposureMode.locked);
      debugPrint('SPHERE_CAMERA: exposure locked');
    } on CameraException catch (error) {
      debugPrint('SPHERE_CAMERA: exposure lock refused (${error.code})');
    }
    try {
      await controller.setFocusMode(FocusMode.locked);
      debugPrint('SPHERE_CAMERA: focus locked');
    } on CameraException catch (error) {
      debugPrint('SPHERE_CAMERA: focus lock refused (${error.code})');
    }
  }

  @override
  Future<void> unlockCaptureSettings() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.setExposureMode(ExposureMode.auto);
    } on CameraException {
      // Nothing to release.
    }
    try {
      await controller.setFocusMode(FocusMode.auto);
    } on CameraException {
      // Nothing to release.
    }
  }

  @override
  Future<Uint8List> takePicture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      throw CameraException(
        'not_open',
        'The camera is not open, so no photograph was taken.',
      );
    }
    final file = await controller.takePicture();
    try {
      return await file.readAsBytes();
    } finally {
      // The plugin writes into the cache directory; the accepted JPEG is
      // written to the station directory by the controller, so the temporary
      // file is not evidence and must not accumulate.
      try {
        await File(file.path).delete();
      } catch (_) {
        // Best effort: a leftover cache file is harmless.
      }
    }
  }

  @override
  Future<void> close() async {
    final controller = _controller;
    _controller = null;
    await controller?.dispose();
  }

  /// Waits until the platform preview is configured **and** has rendered.
  ///
  /// Two conditions matter here:
  ///
  /// 1. `isInitialized` with a reported `previewSize` — the stream exists.
  /// 2. At least two compositor frames — the texture is attached and drawn.
  ///
  /// The capture controller seeds the sphere's reference heading only after
  /// this completes, so the reference describes a frame the user can actually
  /// see. Seeding it earlier (the previous behaviour) anchored target 1 to the
  /// phone's pose mid-lift; by the time the preview appeared, the phone had
  /// turned 20–40° and target 1 was outside the viewfinder.
  @override
  Future<void> ensurePreviewReady({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final controller = _controller;
    if (controller == null) return;
    final deadline = DateTime.now().add(timeout);
    while ((!controller.value.isInitialized ||
            controller.value.previewSize == null) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    for (var frame = 0; frame < 2; frame++) {
      if (DateTime.now().isAfter(deadline)) break;
      await SchedulerBinding.instance.endOfFrame;
    }
  }
}
