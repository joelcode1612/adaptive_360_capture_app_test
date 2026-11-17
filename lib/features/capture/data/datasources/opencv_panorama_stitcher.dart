import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'dart:isolate';

import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/capture/domain/services/panorama_stitcher.dart';

/// On-device panorama generation with OpenCV's [cv.Stitcher] (PANORAMA mode).
///
/// ## Why the whole pipeline runs in a background isolate
///
/// Stitching 38 full-resolution frames takes roughly half a minute on a phone.
/// `stitchAsync` is asynchronous in Dart terms but the native `cv_Stitcher_stitch`
/// call still occupies the calling thread, and on the UI isolate that blocked
/// the Flutter frame loop long enough for Android to show an
/// "Application Not Responding" dialog — observed on device at 05:41. The
/// isolate keeps the preview, the progress modal and the back button alive
/// while OpenCV works.
///
/// No OpenCV object crosses the isolate boundary: the isolate receives file
/// paths and returns a record. That is deliberate — native `Mat` handles are
/// not sendable.
///
/// ## 2:1 output
///
/// The stitcher's spherical panorama does not always come out exactly 2:1
/// (the device produced 9596 × 4313, i.e. 2.22:1). A 360° viewer maps width to
/// 360° and height to 180°, so a non-2:1 image is silently stretched. The
/// result is resized to `2 × height` before it is written, preserving the full
/// stitched field.
class OpenCvPanoramaStitcher implements PanoramaStitcher {
  @override
  Future<StitchResult> stitchFrames(
    List<String> imagePaths, {
    void Function(String stage)? onStage,
  }) async {
    if (imagePaths.isEmpty) {
      return const StitchResult.failure('No images to stitch.');
    }
    // The panorama lands beside the station's metadata:
    // `<station>/frames/tNN.jpg` → `<station>/panorama.jpg`.
    final outPath = p.join(
      File(imagePaths.first).parent.parent.path,
      'panorama.jpg',
    );
    onStage?.call('Stitching ${imagePaths.length} photographs…');
    try {
      final result = await _stitchOnIsolate(imagePaths, outPath);
      if (!result.ok) return StitchResult.failure(result.message);
      return StitchResult(
        success: true,
        panoramaPath: outPath,
        message: 'Panorama generated successfully.',
      );
    } catch (error) {
      return StitchResult.failure('Stitching error: $error');
    }
  }
}

/// Launches [_stitchInIsolate] on a background isolate.
///
/// Top-level on purpose: the closure captures only this function's parameters
/// (the image paths and the output path). Writing the launch inline inside
/// `stitchFrames` made Dart capture that method's whole context — including
/// its `onStage` callback, which closes over the calling Flutter screen — and
/// the isolate message then failed with "unsendable".
Future<({bool ok, String message})> _stitchOnIsolate(
  List<String> imagePaths,
  String outPath,
) => Isolate.run(() => _stitchInIsolate(imagePaths, outPath));

/// The OpenCV work, on a background isolate.
///
/// Synchronous on purpose: the isolate has no event loop to keep responsive,
/// and the synchronous `stitch` avoids the callback plumbing `stitchAsync`
/// would add for no benefit here.
({bool ok, String message}) _stitchInIsolate(
  List<String> imagePaths,
  String outPath,
) {
  final mats = <cv.Mat>[];
  cv.Stitcher? stitcher;
  cv.VecMat? vec;
  try {
    for (final path in imagePaths) {
      if (!File(path).existsSync()) {
        return (ok: false, message: 'Frame file is missing: $path.');
      }
      final mat = cv.imread(path, flags: cv.IMREAD_COLOR);
      if (mat.isEmpty) {
        mat.dispose();
        return (ok: false, message: 'Frame could not be decoded: $path.');
      }
      mats.add(mat);
    }

    stitcher = cv.Stitcher.create(mode: cv.StitcherMode.PANORAMA);
    // Default confidence is 1.0, which refuses any frame whose match confidence
    // is not perfect. A plain ceiling or a painted wall legitimately matches
    // weakly, and at 1.0 the stitcher silently drops those frames — which is
    // how a 360° ring ends up with a hole at the pole instead of a seam.
    //
    // 0.6 keeps low-texture frames in the graph while still refusing frames
    // that match nothing at all. Set on the instance, not the mode, so the
    // PANORAMA warper and the default ExposureCompensator / GraphCutSeamFinder /
    // MultiBandBlender pipeline stay exactly as they are.
    stitcher.panoConfidenceThresh = 0.5;
    vec = cv.VecMat.fromList(mats);
    final (status, pano) = stitcher.stitch(vec);
    debugPrint(
      'FLUTTER_STITCH: OPENCV_STITCHER mode=PANORAMA frames=${mats.length} '
      'confidence=${stitcher.panoConfidenceThresh} '
      'status=${status.name}(${status.index})',
    );
    if (status != cv.StitcherStatus.OK || pano.isEmpty) {
      pano.dispose();
      return (
        ok: false,
        message:
            'Stitching failed (${status.name}). Keep the frames and retry, '
            'or retake frames with more overlap.',
      );
    }

    cv.Mat output = pano;
    var resized = false;
    try {
      if (pano.cols != pano.rows * 2) {
        output = cv.resize(pano, (
          pano.rows * 2,
          pano.rows,
        ), interpolation: cv.INTER_AREA);
        resized = true;
      }
      final ok = cv.imwrite(outPath, output);
      if (!ok || !File(outPath).existsSync()) {
        return (
          ok: false,
          message: 'Panorama rendered but could not be saved.',
        );
      }
      if (File(outPath).lengthSync() == 0) {
        return (ok: false, message: 'Panorama file is empty after stitching.');
      }
      return (ok: true, message: 'Panorama generated successfully.');
    } finally {
      if (resized) pano.dispose();
      output.dispose();
    }
  } catch (error) {
    return (ok: false, message: 'Stitching error: $error');
  } finally {
    vec?.dispose();
    stitcher?.dispose();
    for (final mat in mats) {
      mat.dispose();
    }
  }
}
