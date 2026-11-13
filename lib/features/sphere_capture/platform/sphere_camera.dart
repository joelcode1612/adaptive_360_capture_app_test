import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// The camera surface the sphere flow needs, and nothing more.
///
/// Deliberately narrow so the capture controller can be driven by a fake in
/// tests: preview, one full-resolution still, and a lifecycle. The ARCore
/// still path is not involved — there is no AR session holding the sensor, so
/// the ordinary `camera` plugin can open it directly.
abstract class SphereCamera {
  /// Opens the rear camera at its highest still resolution.
  Future<void> open();

  bool get isOpen;

  /// Preview width ÷ height in portrait, or `null` before [open].
  double? get previewAspectRatio;

  /// The live preview, sized to cover its parent.
  Widget preview();

  /// One full-resolution JPEG.
  Future<Uint8List> takePicture();

  Future<void> close();
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
}
