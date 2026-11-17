#!/usr/bin/env python3
"""Scoped, precondition-checked panorama patch for adaptive_360_capture_app_test.

Usage: py sitewise_panorama_alignment_fix/apply_panorama_fix.py C:/path/to/repo
No arbitrary source files are touched. A dated backup is made before writing.
"""
from __future__ import annotations

import datetime
import pathlib
import shutil
import sys


def replace_once(source: str, old: str, new: str, path: str) -> str:
    count = source.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one anchor, found {count}: {old[:100]!r}")
    return source.replace(old, new, 1)


def patch_sphere_camera(s: str, path: str) -> str:
    s = replace_once(s,
        "import 'package:flutter/material.dart';\n",
        "import 'package:flutter/material.dart';\nimport 'package:flutter/services.dart' show MethodChannel, MissingPluginException;\n",
        path)
    s = replace_once(s,
        "/// The camera surface the sphere flow needs, and nothing more.\n",
        '''/// The stable physical lens parameters supplied by Android Camera2.
/// CameraX JPEGs may already be distortion-corrected; the native distortion
/// coefficients are NOT blindly reapplied to JPEG pixels.
class SphereLensMetadata {
  const SphereLensMetadata({
    required this.focalMm,
    required this.sensorWidthMm,
    required this.sensorHeightMm,
  });

  final double focalMm;
  final double sensorWidthMm;
  final double sensorHeightMm;

  /// Derive focal lengths in SOURCE JPEG coordinates only when the output
  /// aspect agrees with the sensor's physical aspect; otherwise CameraX may
  /// have cropped the frame and the calibration cannot be mapped reliably.
  ({double x, double y})? focalForImage(int width, int height) {
    if (width <= 0 || height <= 0 || focalMm <= 0 ||
        sensorWidthMm <= 0 || sensorHeightMm <= 0) return null;
    final sensorLong = sensorWidthMm > sensorHeightMm
        ? sensorWidthMm : sensorHeightMm;
    final sensorShort = sensorWidthMm > sensorHeightMm
        ? sensorHeightMm : sensorWidthMm;
    final imageLong = width > height ? width : height;
    final imageShort = width > height ? height : width;
    if (((imageLong / imageShort) / (sensorLong / sensorShort) - 1).abs() >
        0.045) return null;
    final focalLong = focalMm * imageLong / sensorLong;
    final focalShort = focalMm * imageShort / sensorShort;
    return width >= height
        ? (x: focalLong, y: focalShort)
        : (x: focalShort, y: focalLong);
  }
}

/// The camera surface the sphere flow needs, and nothing more.
''', path)
    s = replace_once(s,
        '  /// One full-resolution JPEG.\n  Future<Uint8List> takePicture();',
        '''  /// Called once per station after the preview is renderable. Real cameras
  /// can focus/meter and lock their settings; test fakes remain a no-op.
  Future<void> prepareCaptureSweep() async {}

  /// Real physical-lens calibration, when Camera2 and the selected lens expose
  /// sufficient metadata. Null means use the documented fallback geometry.
  SphereLensMetadata? get lensMetadata => null;

  /// One full-resolution JPEG.
  Future<Uint8List> takePicture();''', path)
    s = replace_once(s,
        '''class PluginSphereCamera implements SphereCamera {
  CameraController? _controller;
''',
        '''class PluginSphereCamera implements SphereCamera {
  CameraController? _controller;
  SphereLensMetadata? _lensMetadata;

  static const MethodChannel _lensChannel = MethodChannel('adaptive360/lens');

  @override
  SphereLensMetadata? get lensMetadata => _lensMetadata;
''', path)
    s = replace_once(s,
        '''    _controller = controller;
    try {
      await controller.initialize();''',
        '''    _controller = controller;
    _lensMetadata = null;
    try {
      await controller.initialize();''', path)
    s = replace_once(s,
        '''      try {
        await controller.setFlashMode(FlashMode.off);
      } on CameraException {
        // Some devices expose no flash; the still is unaffected.
      }
''',
        '''      try {
        await controller.setFlashMode(FlashMode.off);
      } on CameraException {
        // Some devices expose no flash; the still is unaffected.
      }
      // Metadata comes from the same camera ID CameraX selected. If a phone
      // provides no physical-lens metadata, preserve the previous FOV fallback.
      try {
        final info = await _lensChannel.invokeMapMethod<String, dynamic>(
          'describe', <String, Object?>{'cameraId': back.name},
        );
        final focal = (info?['focalMm'] as num?)?.toDouble();
        final width = (info?['sensorWidthMm'] as num?)?.toDouble();
        final height = (info?['sensorHeightMm'] as num?)?.toDouble();
        if (focal != null && width != null && height != null &&
            focal > 0 && width > 0 && height > 0) {
          _lensMetadata = SphereLensMetadata(
            focalMm: focal,
            sensorWidthMm: width,
            sensorHeightMm: height,
          );
        }
      } on MissingPluginException {
        // Desktop and fake camera implementations have no Android channel.
      } catch (_) {
        // Camera2 metadata is optional. Never fail capture if it is absent.
      }
''', path)
    s = replace_once(s,
        '  @override\n  Future<Uint8List> takePicture() async {',
        '''  @override
  Future<void> prepareCaptureSweep() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    // One focus and exposure state is more consistent than remetering every
    // shot in the sweep. CameraX support differs across Android devices.
    try {
      await controller.setFocusMode(FocusMode.auto);
    } catch (_) {
      // Continue with the platform default.
    }
    try {
      await controller.setExposureMode(ExposureMode.auto);
    } catch (_) {
      // Continue with the platform default.
    }
    await Future<void>.delayed(const Duration(milliseconds: 450));
    try {
      await controller.setFocusMode(FocusMode.locked);
    } catch (_) {
      // Autofocus continues if the platform cannot lock it.
    }
    try {
      await controller.setExposureMode(ExposureMode.locked);
    } catch (_) {
      // Exposure is compensated between saved photos during blending.
    }
    // The camera Flutter plugin does not expose a white-balance lock. The
    // stitcher's conservative overlap-based colour compensation handles drift.
  }

  @override
  Future<Uint8List> takePicture() async {''', path)
    s = replace_once(s,
        '''    _controller = null;
    await controller?.dispose();
''',
        '''    _controller = null;
    _lensMetadata = null;
    await controller?.dispose();
''', path)
    return s


def patch_controller(s: str, path: str) -> str:
    s = replace_once(s,
        '''      await _camera.ensurePreviewReady();
      _previewReadyAt = _clock();''',
        '''      await _camera.ensurePreviewReady();
      await _camera.prepareCaptureSweep();
      _previewReadyAt = _clock();''', path)
    s = replace_once(s,
        '''    _deviceToWorld = quaternion;
    // The sphere's reference frame''',
        '''    final previousPose = _deviceToWorld;
    final secondsBetweenSamples = previousArrival == null
        ? 0.0
        : now.difference(previousArrival).inMicroseconds / 1e6;
    final angularSpeedDegPerSec = previousPose == null ||
            secondsBetweenSamples <= 0
        ? double.infinity
        : _poseAngleDeg(previousPose, quaternion) / secondsBetweenSamples;
    _deviceToWorld = quaternion;
    // The sphere's reference frame''', path)
    s = replace_once(s,
        '''      if (activeError <= toleranceDeg) {
''',
        '''      // Being aimed at a target is NOT the same as being stationary.
      // This additional motion gate prevents blurry shutter frames.
      if (_moving || angularSpeedDegPerSec > 4.0) {
        _holdProgress = 0;
        _lastSampleAt = now;
      } else if (activeError <= toleranceDeg) {
''', path)
    s = replace_once(s,
        '''      final raw = await _camera.takePicture();
      final normalized = await _normalize(raw);''',
        '''      final raw = await _camera.takePicture();
      final after = _deviceToWorld;
      if (after != null && _poseAngleDeg(device, after) > 2.0) {
        throw StateError('The phone moved during the photo. Keep the lens '
            'in one spot and hold steady to retry this target.');
      }
      final normalized = await _normalize(raw);
      final sourceWidth = normalized.sourceWidth > 0
          ? normalized.sourceWidth : normalized.width;
      final sourceHeight = normalized.sourceHeight > 0
          ? normalized.sourceHeight : normalized.height;
      final lensFocal = _camera.lensMetadata?.focalForImage(
        sourceWidth, sourceHeight,
      );''', path)
    s = replace_once(s,
        '''        cropOffsetX: normalized.cropOffsetX,
        cropOffsetY: normalized.cropOffsetY,
        imageFormat: 'jpeg',''',
        '''        cropOffsetX: normalized.cropOffsetX,
        cropOffsetY: normalized.cropOffsetY,
        focalLengthXPx: lensFocal?.x,
        focalLengthYPx: lensFocal?.y,
        imageFormat: 'jpeg',''', path)
    s = replace_once(s,
        '''        await _camera.open();
        _notify();''',
        '''        await _camera.open();
        await _camera.ensurePreviewReady();
        await _camera.prepareCaptureSweep();
        _notify();''', path)
    s = replace_once(s,
        '/// Writes the finished station to a folder the user can find.',
        '''/// Absolute angular distance between orientations. q and -q describe the
/// same pose, so the dot product uses its absolute value.
double _poseAngleDeg(Quat a, Quat b) {
  final dot = (a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w).abs();
  return 2 * math.acos(dot.clamp(0.0, 1.0)) * 180 / math.pi;
}

/// Writes the finished station to a folder the user can find.''', path)
    return s


def patch_capture_ui(s: str, path: str) -> str:
    return replace_once(s,
        '''              '3DoF rotation only · levelled to gravity at Start · the sphere '
              'stays locked to the room',''',
        '''              'Keep the camera lens above one fixed spot. Move around '
              'that spot while rotating the phone, not your body with the '
              'phone held at arm\\'s length. Hold still when each target aligns.',''', path)


def patch_native_lens(s: str, path: str) -> str:
    s = replace_once(s,
        'import com.adaptive360.adaptive_360_capture_app.ar.ArCoreCapturePlugin\n',
        '''import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import com.adaptive360.adaptive_360_capture_app.ar.ArCoreCapturePlugin
''', path)
    s = replace_once(s,
        '    private var mediaChannel: MethodChannel? = null\n',
        '    private var mediaChannel: MethodChannel? = null\n    private var lensChannel: MethodChannel? = null\n', path)
    s = replace_once(s,
        '''        media.setMethodCallHandler(MediaStoreChannel(applicationContext))
        mediaChannel = media''',
        '''        media.setMethodCallHandler(MediaStoreChannel(applicationContext))
        mediaChannel = media

        // Physical lens metadata supplements the 65-degree fallback. These
        // values describe sensor geometry; processed CameraX JPEGs may already
        // be distortion-corrected. Never reapply raw distortion coefficients.
        val lens = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "adaptive360/lens",
        )
        lens.setMethodCallHandler { call, result ->
            if (call.method != "describe") {
                result.notImplemented()
            } else {
                val cameraId = call.argument<String>("cameraId")
                if (cameraId.isNullOrBlank()) {
                    result.success(null)
                } else {
                    try {
                        val cameras = getSystemService(Context.CAMERA_SERVICE) as CameraManager
                        val characteristics = cameras.getCameraCharacteristics(cameraId)
                        val sensor = characteristics.get(
                            CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE
                        )
                        val focal = characteristics.get(
                            CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS
                        )?.firstOrNull()
                        if (sensor == null || focal == null) {
                            result.success(null)
                        } else {
                            result.success(mapOf(
                                "focalMm" to focal.toDouble(),
                                "sensorWidthMm" to sensor.width.toDouble(),
                                "sensorHeightMm" to sensor.height.toDouble(),
                            ))
                        }
                    } catch (error: Exception) {
                        // Missing metadata is not an error: use the old FOV.
                        result.success(null)
                    }
                }
            }
        }
        lensChannel = lens''', path)
    s = replace_once(s,
        '''        mediaChannel?.setMethodCallHandler(null)
        mediaChannel = null''',
        '''        mediaChannel?.setMethodCallHandler(null)
        mediaChannel = null
        lensChannel?.setMethodCallHandler(null)
        lensChannel = null''', path)
    return s


def patch_pubspec(s: str, path: str) -> str:
    return replace_once(s,
        '        - imgcodecs\n',
        '        - imgcodecs\n        # cv.cvtColor is provided by imgproc; keep this native symbol.\n        - imgproc\n', path)


def patch_intrinsics(s: str, path: str) -> str:
    s = replace_once(s,
        '''  required double verticalFovDeg,
  int cropOffsetX = 0,
  int cropOffsetY = 0,
}) {''',
        '''  required double verticalFovDeg,
  int cropOffsetX = 0,
  int cropOffsetY = 0,
  double? sourceFocalLengthXPx,
  double? sourceFocalLengthYPx,
}) {''', path)
    s = replace_once(s,
        '''  final focalSource = focalFromHeight(
    effSourceH.toDouble(),
    verticalFovDeg,
  );''',
        '''  // A matched physical camera lens is more accurate than the default
  // 65-degree assumption. Only accept the calibration if the source x/y
  // focal lengths are consistent: a CameraX crop or bad metadata must not
  // silently distort the entire panorama.
  final calibratedX = sourceFocalLengthXPx;
  final calibratedY = sourceFocalLengthYPx;
  var focalSource = focalFromHeight(effSourceH.toDouble(), verticalFovDeg);
  if (calibratedX != null && calibratedY != null &&
      calibratedX > 0 && calibratedY > 0 &&
      ((calibratedX - calibratedY).abs() /
          ((calibratedX + calibratedY) / 2)) < 0.08) {
    focalSource = (calibratedX + calibratedY) / 2;
  }''', path)
    return s


def patch_registration(s: str, path: str) -> str:
    s = replace_once(s,
        '''    required this.cropOffsetX,
    required this.cropOffsetY,
  });''',
        '''    required this.cropOffsetX,
    required this.cropOffsetY,
    this.sourceFocalLengthXPx,
    this.sourceFocalLengthYPx,
  });''', path)
    s = replace_once(s,
        '''  final int cropOffsetX;
  final int cropOffsetY;
}''',
        '''  final int cropOffsetX;
  final int cropOffsetY;
  final double? sourceFocalLengthXPx;
  final double? sourceFocalLengthYPx;
}''', path)
    s = replace_once(s,
        '''          cropOffsetX: frame.cropOffsetX,
          cropOffsetY: frame.cropOffsetY,
        );''',
        '''          cropOffsetX: frame.cropOffsetX,
          cropOffsetY: frame.cropOffsetY,
          sourceFocalLengthXPx: frame.sourceFocalLengthXPx,
          sourceFocalLengthYPx: frame.sourceFocalLengthYPx,
        );''', path)
    return s


def patch_stitcher(s: str, path: str) -> str:
    s = replace_once(s,
        '''        cropOffsetX: (record['cropOffsetX'] as num?)?.toInt() ?? 0,
        cropOffsetY: (record['cropOffsetY'] as num?)?.toInt() ?? 0,
      ),''',
        '''        cropOffsetX: (record['cropOffsetX'] as num?)?.toInt() ?? 0,
        cropOffsetY: (record['cropOffsetY'] as num?)?.toInt() ?? 0,
        sourceFocalLengthXPx:
            (record['focalLengthXPx'] as num?)?.toDouble(),
        sourceFocalLengthYPx:
            (record['focalLengthYPx'] as num?)?.toDouble(),
      ),''', path)
    s = replace_once(s,
        '''        cropOffsetX: (record['cropOffsetX'] as num?)?.toInt() ?? 0,
        cropOffsetY: (record['cropOffsetY'] as num?)?.toInt() ?? 0,
      );''',
        '''        cropOffsetX: (record['cropOffsetX'] as num?)?.toInt() ?? 0,
        cropOffsetY: (record['cropOffsetY'] as num?)?.toInt() ?? 0,
        sourceFocalLengthXPx:
            (record['focalLengthXPx'] as num?)?.toDouble(),
        sourceFocalLengthYPx:
            (record['focalLengthYPx'] as num?)?.toDouble(),
      );''', path)
    s = replace_once(s,
        '''  final exposureMs = lapMs();

  // ── Feathering''',
        '''  // The camera plugin supports focus/exposure lock but does not offer
  // white-balance lock. Solve modest per-image RGB corrections from matching
  // shared pixels. These preserve luminance and never modify the source JPEGs.
  final whiteBalance = solveWhiteBalanceGains(
    pixelCount: width * height,
    frameCount: records.length,
    bestFrame: bestFrame,
    secondFrame: secondFrame,
    bestWeight: bestWeight,
    secondWeight: secondWeight,
    bestColour: bestColour,
    secondColour: secondColour,
  );

  final exposureMs = lapMs();

  // ── Feathering''', path)
    # The old top-2 weighted average ghosts objects that moved by several
    # pixels. Suppress the secondary source only where they disagree, keeping
    # feathering where photographs agree. This is not a graph-cut seam finder.
    first='''      final total = best + second;
      final t = best / total;
      final gainSecond = gains[secondIndex];
      final offsetSecond = offsets[secondIndex];
      for (var c = 0; c < 3; c++) {
        final value =
            (bestColour[i * 3 + c] * gainBest + offsetBest) * t +
            (secondColour[i * 3 + c] * gainSecond + offsetSecond) * (1 - t);
        output[i * 3 + c] = value <= 0
            ? 0
            : (value >= 255 ? 255 : value.round());
      }'''
    second='''      final total = best + second;
      final originalT = best / total;
      final gainSecond = gains[secondIndex];
      final offsetSecond = offsets[secondIndex];
      // Dissimilar source pixels represent misaligned geometry or motion.
      // Avoid averaging two object positions into a transparent double image.
      // Keep smooth feathering over regions where the images agree.
      var largestDisagreement = 0.0;
      for (var c = 0; c < 3; c++) {
        final a = (bestColour[i * 3 + c] * gainBest + offsetBest) *
            whiteBalance[bestIndex * 3 + c];
        final b = (secondColour[i * 3 + c] * gainSecond + offsetSecond) *
            whiteBalance[secondIndex * 3 + c];
        final diff = (a - b).abs();
        if (diff > largestDisagreement) largestDisagreement = diff;
      }
      final agreement = ((54 - largestDisagreement) / 36).clamp(0.0, 1.0);
      final t = 1.0 - (1.0 - originalT) * agreement;
      for (var c = 0; c < 3; c++) {
        final a = (bestColour[i * 3 + c] * gainBest + offsetBest) *
            whiteBalance[bestIndex * 3 + c];
        final b = (secondColour[i * 3 + c] * gainSecond + offsetSecond) *
            whiteBalance[secondIndex * 3 + c];
        final value = a * t + b * (1 - t);
        output[i * 3 + c] = value <= 0
            ? 0
            : (value >= 255 ? 255 : value.round());
      }'''
    s = replace_once(s,first,second,path)
    s = replace_once(s,
        '''        final value = bestColour[i * 3 + c] * gainBest + offsetBest;
        output[i * 3 + c] = value <= 0''',
        '''        final value = (bestColour[i * 3 + c] * gainBest + offsetBest) *
            whiteBalance[bestIndex * 3 + c];
        output[i * 3 + c] = value <= 0''',path)
    s = replace_once(s,
        '''/// Per-photograph exposure gains, estimated from the pixels two photographs
''',
        '''/// Conservative, overlap-derived per-channel correction for white-balance
/// drift between frames. The result is [frameCount * 3] RGB gains. Only pixels
/// with similar luminance and shared high-confidence coverage participate;
/// otherwise a moving object or an overexposed window could contaminate the
/// estimate. Gains are clamped to +/-10% and neutralised per frame so the
/// existing luminance exposure solver remains in charge of brightness.
@visibleForTesting
Float64List solveWhiteBalanceGains({
  required int pixelCount,
  required int frameCount,
  required Int16List bestFrame,
  required Int16List secondFrame,
  required Float32List bestWeight,
  required Float32List secondWeight,
  required Uint8List bestColour,
  required Uint8List secondColour,
}) {
  final corrections = Float64List(frameCount * 3)
    ..fillRange(0, frameCount * 3, 1.0);
  if (frameCount < 2) return corrections;
  final pairCount = frameCount * frameCount;
  final sumsA = Float64List(pairCount * 3);
  final sumsB = Float64List(pairCount * 3);
  final counts = Int32List(pairCount);
  for (var i = 0; i < pixelCount; i++) {
    final a = bestFrame[i];
    final b = secondFrame[i];
    if (a < 0 || b < 0 || a == b ||
        secondWeight[i] < bestWeight[i] * 0.35) continue;
    final j = i * 3;
    final lumA = 0.2126 * bestColour[j] +
        0.7152 * bestColour[j + 1] + 0.0722 * bestColour[j + 2];
    final lumB = 0.2126 * secondColour[j] +
        0.7152 * secondColour[j + 1] + 0.0722 * secondColour[j + 2];
    if (lumA < 35 || lumA > 225 || lumB < 35 || lumB > 225 ||
        (lumA - lumB).abs() > 0.22 * math.max(lumA, lumB)) continue;
    final k = a * frameCount + b;
    for (var c = 0; c < 3; c++) {
      sumsA[k * 3 + c] += (bestColour[j + c] + 8) / lumA;
      sumsB[k * 3 + c] += (secondColour[j + c] + 8) / lumB;
    }
    counts[k]++;
  }
  final logGain = Float64List(frameCount * 3);
  for (var c = 0; c < 3; c++) {
    for (var pass = 0; pass < 100; pass++) {
      for (var a = 0; a < frameCount; a++) {
        for (var b = 0; b < frameCount; b++) {
          final k = a * frameCount + b;
          if (counts[k] < 45) continue;
          final one = sumsA[k * 3 + c];
          final two = sumsB[k * 3 + c];
          if (one <= 0 || two <= 0) continue;
          final target = math.log(two / one);
          final mismatch = target -
              (logGain[a * 3 + c] - logGain[b * 3 + c]);
          final step = mismatch * 0.06;
          logGain[a * 3 + c] += step;
          logGain[b * 3 + c] -= step;
        }
      }
    }
  }
  for (var i = 0; i < frameCount; i++) {
    // Remove common RGB brightness changes, which are handled by exposure.
    final mean = (logGain[i * 3] + logGain[i * 3 + 1] +
        logGain[i * 3 + 2]) / 3;
    for (var c = 0; c < 3; c++) {
      corrections[i * 3 + c] = math.exp(
        (logGain[i * 3 + c] - mean).clamp(-0.10, 0.10),
      );
    }
  }
  return corrections;
}

/// Per-photograph exposure gains, estimated from the pixels two photographs
''', path)
    return s


PATCHES = {
    'pubspec.yaml': patch_pubspec,
    'lib/features/sphere_capture/platform/sphere_camera.dart': patch_sphere_camera,
    'lib/features/sphere_capture/application/sphere_capture_controller.dart': patch_controller,
    'lib/features/sphere_capture/presentation/screens/sphere_capture_screen.dart': patch_capture_ui,
    'android/app/src/main/kotlin/com/adaptive360/adaptive_360_capture_app/MainActivity.kt': patch_native_lens,
    'lib/features/sphere_capture/domain/sphere_intrinsics.dart': patch_intrinsics,
    'lib/features/sphere_capture/data/sphere_frame_registration.dart': patch_registration,
    'lib/features/sphere_capture/data/equirectangular_stitcher.dart': patch_stitcher,
}


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: py apply_panorama_fix.py PATH_TO_REPOSITORY', file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1]).expanduser().resolve()
    if not (root / 'pubspec.yaml').is_file():
        print(f'Not a Flutter repository: {root}', file=sys.stderr)
        return 2
    original = {}
    updated = {}
    try:
        for name, patch in PATCHES.items():
            path = root / name
            source = path.read_text(encoding='utf-8')
            original[name] = source
            updated[name] = patch(source, name)
    except Exception as error:
        print(f'No files modified: {error}', file=sys.stderr)
        return 1
    backup = root / '.sitewise_panorama_backup' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    for name in PATCHES:
        destination = backup / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(original[name], encoding='utf-8')
    for name in PATCHES:
        (root / name).write_text(updated[name], encoding='utf-8')
        print(f'Updated: {name}')
    print(f'Original versions backed up at: {backup}')
    print('Local source changes applied; Android runtime validation is still required.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
