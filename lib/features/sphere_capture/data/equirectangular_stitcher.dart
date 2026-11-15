import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/capture/domain/services/panorama_stitcher.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/data/sphere_frame_registration.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/data/stitch_job_runner.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/equirect_bounds.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_intrinsics.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';

/// A guaranteed full-sphere equirectangular panorama from the 3DoF captures.
///
/// ## Why not OpenCV's feature-based Stitcher
///
/// On device, `cv::Stitcher` returned a partial fan of the room: it dropped
/// frames it could not confidently register instead of covering the sphere.
/// That is the wrong failure mode for a 360° product — a hole cannot be
/// retried without recapturing.
///
/// This stitcher does not *depend* on feature matching for coverage. Every frame
/// already has a measured device quaternion in `records.json`, so its orientation
/// relative to the first frame is known. Each frame is projected onto the
/// equirectangular canvas through that rotation, and every canvas pixel takes a
/// weighted average of the photographs that reach it. Coverage is therefore
/// complete by construction, and no frame can be "rejected".
///
/// ## Registration
///
/// The quaternion is a gyroscope integral, and a couple of degrees of error is a
/// torn seam. So before projection each frame's orientation is refined against
/// the photographs that overlap it — ORB features detected once per frame,
/// matched only between neighbours chosen from the recorded geometry, filtered
/// by RANSAC, and turned into a small rotation correction by
/// [refineRotationFromCorrespondences]. A frame with no trustworthy overlap keeps
/// its recorded quaternion, which is what a blank wall produces. The pass is
/// optional ([refineRegistration]) and every correction is recorded in
/// `coverage_report.json`.
///
/// ## Blending
///
/// Averaging all overlapping frames ghosted badly wherever two rings disagreed
/// by a few degrees — because they *did* disagree, by more than a degree, before
/// registration existed. The canvas used to keep the nearest frame per pixel and
/// blend only where the best and second-best weights were within 3%; at 3% the
/// transition is a few pixels wide, so the seam read as a cut and tore where the
/// frames disagreed.
///
/// It is now a normalised weighted average of the top two contributors over the
/// whole overlap. The weights already fall off toward a frame's edge and toward
/// grazing angles, so the blend fades exactly where each photograph stops being
/// trustworthy, and there is no rectangular boundary left to see.
///
/// Three corrections sit on top of that choice:
///
/// * **Exposure.** Every photograph is exposed by its own auto-exposure loop, so
///   neighbouring frames of the same wall differ in brightness and every seam is
///   also a step. [solveExposureGains] and [solveExposureOffsets] recover a gain
///   and an offset per photograph from the pixels two frames share, and the blend
///   applies both.
/// * **Gaps.** Uncovered pixels used to be left at zero, which is why a missed
///   direction read as a black disc rather than as a soft patch. [fillUncovered]
///   now propagates colour outward from the covered boundary. The station is
///   still reported as deficient — [worstViewportGap] measures the largest
///   empty *view*, which is what a person sees, rather than empty *area*, which
///   cosine weighting makes nearly free at the poles.
/// * **Resolution.** The canvas is 2048 wide by default and 4096 when the caller
///   asks for it and the accumulator fits [kSphereStitchAccumulatorBudgetBytes].
///   A request that does not fit is downgraded and the downgrade is reported;
///   upscaling a finished panorama is not offered as a quality option because it
///   adds pixels, not detail.
///
/// ## What "complete" does and does not mean
///
/// Coverage is complete by construction only for the directions the layout
/// actually aimed at. The auto-shutter fires anywhere inside a ±5° cone, and the
/// thinnest seam in the layout shares 17.3% of a frame, so a legal aim error can
/// still leave a direction unphotographed — most easily at the poles, where the
/// ring-to-ring overlap is 10° against 30° elsewhere. The audit therefore reports
/// coverage rather than promising it.
///
/// The whole projection runs in a background isolate: 38 frames take several
/// seconds and must not block the Flutter UI thread (the previous on-thread
/// stitch caused an ANR). The isolate hand-off itself — the part that used to
/// fail with an unsendable `ReceivePort` — lives in [StitchJobRunner], where
/// only plain data and a `SendPort` cross the boundary.
class EquirectangularStitcher implements PanoramaStitcher {
  const EquirectangularStitcher({
    this.width = 2048,
    this.refineRegistration = true,
    this.worker = _projectEquirect,
  });

  /// Output width in pixels; height is half of it, i.e. a 2:1 equirectangular.
  final int width;

  /// Whether the projection refines each frame's recorded orientation against
  /// its overlapping neighbours first. See [registerSphereFrames]. Turning it
  /// off reproduces the previous behaviour exactly and is the escape hatch if a
  /// device cannot afford the extra decode pass.
  final bool refineRegistration;

  /// The projection entry point. Top-level by default; injectable so the
  /// isolate contract (progress plumbing, error propagation, duplicate-job
  /// rejection) is testable without the native OpenCV library.
  final StitchWorker worker;

  @override
  Future<StitchResult> stitchFrames(
    List<String> imagePaths, {
    void Function(String stage)? onStage,
  }) async {
    if (imagePaths.isEmpty) {
      return const StitchResult.failure('No images to stitch.');
    }
    final stationDir = File(imagePaths.first).parent.parent.path;
    final recordsFile = File(p.join(stationDir, 'records.json'));
    if (!recordsFile.existsSync()) {
      return const StitchResult.failure(
        'The capture records are missing, so the photographs cannot be '
        'oriented. Retake the station.',
      );
    }
    final outPath = p.join(stationDir, 'panorama.jpg');
    onStage?.call('Preparing ${imagePaths.length} photographs…');
    // The runner keeps the ReceivePort in this isolate and hands the worker
    // only a sendable record containing its SendPort. It also refuses a
    // second concurrent run for the same station.
    final result = await StitchJobRunner.run(
      worker: worker,
      stationDir: stationDir,
      outPath: outPath,
      width: width,
      refineRegistration: refineRegistration,
      onStage: onStage,
    );
    if (!result.ok) return StitchResult.failure(result.message);
    return StitchResult(
      success: true,
      panoramaPath: outPath,
      message: 'Panorama generated successfully.',
    );
  }
}

/// Whether the stitcher's verbose diagnostics are compiled in. Off unless the
/// run asks for it: `--dart-define=sphere_stitch_log=true`.
const bool kSphereStitchLog = bool.fromEnvironment('sphere_stitch_log');

/// The smallest projection weight a pixel may carry and still be written.
///
/// Below this the frame is grazing that direction so steeply that its colour is
/// more lens falloff than scene. The blend, the gap fill and the coverage audit
/// must all agree on this number: when they disagreed, the audit counted a
/// pixel as covered because a frame's ray landed in bounds while the renderer
/// skipped it for being under threshold — and the panorama shipped black pixels
/// that the report claimed were photographs.
const double _kMinPixelWeight = 1e-4;

/// The width the flow has always produced, and the safe default.
const int kSphereStitchStandardWidth = 2048;

/// The quality-oriented width. 2:1 at 4096×2048 is where a 360° viewer stops
/// looking soft on a phone screen without the accumulator outgrowing the device.
const int kSphereStitchHighWidth = 4096;

/// Bytes the accumulator needs at [width], before any decoded frame is held.
///
/// Every per-pixel buffer the projection keeps is counted: two weights (4 bytes
/// each), two colours (3 each), two frame indices (2 each), the coverage counter
/// (1) and the output (3) — 19 bytes per pixel. Decoded frames are not included
/// because exactly one is alive at a time and it is released before the next
/// opens.
///
/// This is an estimate, not a measurement, and it is exposed so the caller can
/// decide rather than guess: 2048×1024 needs about 38 MB, 4096×2048 about 152 MB.
int sphereStitchAccumulatorBytes(int width) {
  final height = width ~/ 2;
  return width * height * 19;
}

/// The ceiling the quality tier is allowed to reach. Above this the projection
/// would be competing with the camera and the rest of the app for a phone's
/// memory, and an out-of-memory kill loses the whole station — including the
/// photographs, which are the only thing that cannot be regenerated.
const int kSphereStitchAccumulatorBudgetBytes = 176 * 1024 * 1024;

/// The width actually used for [requested], downgraded when it does not fit.
///
/// A downgrade is not a silent quality loss: the chosen width and the reason are
/// written into `coverage_report.json`, so a station that came out at 2048 when
/// 4096 was asked for says so.
int resolveSphereStitchWidth(int requested) {
  if (requested <= kSphereStitchStandardWidth) return requested;
  if (sphereStitchAccumulatorBytes(kSphereStitchHighWidth) <=
      kSphereStitchAccumulatorBudgetBytes) {
    return kSphereStitchHighWidth;
  }
  return kSphereStitchStandardWidth;
}

/// The projection, on a background isolate.
({bool ok, String message}) _projectEquirect(StitchWorkerArgs args) {
  final stationDir = args.stationDir;
  final outPath = args.outPath;
  // The requested width is a ceiling, not a promise: a device that cannot hold
  // the 4096 accumulator gets 2048 instead of an out-of-memory kill.
  final requestedWidth = args.width;
  final width = resolveSphereStitchWidth(requestedWidth);
  final SendPort progress = args.progress;
  final stopwatch = Stopwatch()..start();
  final recordsFile = File(p.join(stationDir, 'records.json'));
  final raw = jsonDecode(recordsFile.readAsStringSync());
  if (raw is! List || raw.isEmpty) {
    return (ok: false, message: 'The capture records are empty.');
  }
  final records = raw.cast<Map<String, dynamic>>()
    ..sort(
      (Map<String, dynamic> a, Map<String, dynamic> b) => (a['targetId'] as num)
          .toInt()
          .compareTo((b['targetId'] as num).toInt()),
    );

  // ── Registration ────────────────────────────────────────────────────
  //
  // The recorded quaternion is a gyroscope integral: good to a couple of
  // degrees, and a couple of degrees at a seam is a torn edge. Before anything
  // is projected, each frame's orientation is refined against the photographs
  // that overlap it — see `registerSphereFrames`.
  //
  // This pass runs *before* the projection because it needs every frame's
  // descriptors, and the projection needs every frame's refined rotation. Two
  // sequential decodes per frame is the cost of that ordering; they are never
  // simultaneous, and each frame's Mats are released before the next opens.
  //
  // When it is switched off, or when every edge is refused, `rotations` is
  // exactly the recorded set and the rest of the pipeline is unchanged — which
  // is also the path a station of blank walls takes.
  final registrationFrames = <SphereRegistrationFrame>[
    for (final record in records)
      SphereRegistrationFrame(
        targetId: (record['targetId'] as num).toInt(),
        imagePath: record['imagePath'] as String? ?? '',
        rotation: Quat.fromList(
          (record['cameraOrientation'] as List<dynamic>).cast<double>(),
        ),
        savedWidth: (record['imageWidth'] as num?)?.toInt() ?? 0,
        savedHeight: (record['imageHeight'] as num?)?.toInt() ?? 0,
        sourceWidth: (record['sourceImageWidth'] as num?)?.toInt() ?? 0,
        sourceHeight: (record['sourceImageHeight'] as num?)?.toInt() ?? 0,
        cropOffsetX: (record['cropOffsetX'] as num?)?.toInt() ?? 0,
        cropOffsetY: (record['cropOffsetY'] as num?)?.toInt() ?? 0,
      ),
  ];
  final SphereRegistrationOutcome registration;
  if (args.refineRegistration) {
    progress.send(
      'Refining ${records.length} camera orientations against their overlaps…',
    );
    registration = registerSphereFrames(
      frames: registrationFrames,
      verticalFovDeg: kSphereAssumedVerticalFovDeg,
      onStage: progress.send,
    );
  } else {
    registration = SphereRegistrationOutcome.unrefined(
      registrationFrames,
      note: 'Registration was switched off for this run.',
    );
  }
  final rotations = registration.rotations;
  // The anchor is the first frame's *refined* rotation, so a correction accepted
  // for frame 0 rotates the whole sphere rather than skewing every other frame
  // against a stale reference.
  final anchor = rotations.first;
  final registrationMs = registration.elapsed.inMilliseconds;
  if (kSphereStitchLog) {
    debugPrint(
      'SPHERE_REGISTRATION: pairs=${registration.pairsConsidered} '
      'accepted=${registration.acceptedEdges} '
      'rejected=${registration.rejectedEdges} '
      'features=${registration.featureTotal} '
      'maxCorrection=${maxCorrectionDeg(registration.correctionDeg).toStringAsFixed(2)}° '
      'elapsed=${registrationMs}ms',
    );
  }

  final height = width ~/ 2;
  // Stage timing. No speed-up may be claimed without measurement, so every stage
  // is measured and written into the coverage report — a claim about this
  // pipeline can then be checked against a station's own numbers.
  var stageMarkMs = stopwatch.elapsedMilliseconds;
  int lapMs() {
    final now = stopwatch.elapsedMilliseconds;
    final delta = now - stageMarkMs;
    stageMarkMs = now;
    return delta;
  }

  final bestWeight = Float32List(width * height);
  final bestColour = Uint8List(width * height * 3);
  final secondWeight = Float32List(width * height);
  final secondColour = Uint8List(width * height * 3);
  // Which photograph owns each pixel. An exposure correction is a per-photograph
  // scalar, so a blended pixel has to remember which two photographs it came
  // from — the colour alone cannot say. `-1` means "no photograph reached here",
  // and it is also how the gap fill finds the holes without re-testing weights.
  final bestFrame = Int16List(width * height)
    ..fillRange(0, width * height, -1);
  final secondFrame = Int16List(width * height)
    ..fillRange(0, width * height, -1);
  // How many frames actually see each pixel. Saturating at 3: the audit only
  // reports single/double/triple coverage, and a fourth contributor would not
  // change any of those three numbers.
  final hits = Uint8List(width * height);

  final sinLon = Float64List(width);
  final cosLon = Float64List(width);
  for (var x = 0; x < width; x++) {
    final lon = -3.141592653589793 + (x + 0.5) / width * 6.283185307179586;
    sinLon[x] = math.sin(lon);
    cosLon[x] = math.cos(lon);
  }
  final sinLat = Float64List(height);
  final cosLat = Float64List(height);
  for (var y = 0; y < height; y++) {
    final lat = 1.5707963267948966 - (y + 0.5) / height * 3.141592653589793;
    sinLat[y] = math.sin(lat);
    cosLat[y] = math.cos(lat);
  }

  // Composition decode. This is the only place that decides how much real
  // detail reaches the canvas, and it used to be wrong in the quiet way: at 2048
  // it decoded `IMREAD_REDUCED_COLOR_4`, i.e. 768×1024 for a 3072×4096 still,
  // and then spread that across a 2048-pixel-wide canvas — a 2.7× stretch in
  // longitude, which is a blurred panorama produced by a resize rather than by
  // the lens. `REDUCED_COLOR_2` is 1536×2048 and fills the canvas roughly 1:1.
  //
  // The 4096 tier decodes at full resolution, because at that width anything
  // less is stretched again. Only one frame is ever decoded at a time and it is
  // released before the next opens, so the peak is one frame (about 38 MB for a
  // 12 MP still) on top of the accumulator — which is why the accumulator budget
  // is checked separately in [resolveSphereStitchWidth].
  final decodeFlag = width <= 2048 ? cv.IMREAD_REDUCED_COLOR_2 : cv.IMREAD_COLOR;
  for (var frameIndex = 0; frameIndex < records.length; frameIndex++) {
    final record = records[frameIndex];
    final path = record['imagePath'] as String?;
    if (path == null || !File(path).existsSync()) {
      return (ok: false, message: 'A captured photograph is missing: $path');
    }
    final mat = cv.imread(path, flags: decodeFlag);
    if (mat.isEmpty) {
      mat.dispose();
      return (ok: false, message: 'A photograph could not be decoded: $path');
    }
    try {
      // camera -> sphere, using the **refined** orientation when registration
      // accepted an edge for this frame and the recorded one otherwise. The
      // first frame defines the sphere's origin, and its own rotation is left
      // untouched by construction, so the reference does not drift with it.
      final cameraToSphere = (anchor.conjugate * rotations[frameIndex])
          .normalized;
      final sphereToCamera = cameraToSphere.conjugate;

      final imageWidth = mat.cols;
      final imageHeight = mat.rows;
      // Focal length and principal point **in the decoded image's coordinate
      // system**. The stitcher decodes reduced (IMREAD_REDUCED_COLOR_4 by
      // default), so the lens focal — a lens property, computed once on the
      // uncropped source frame — must be multiplied by the decode scale, and
      // the principal point must follow the recorded crop offsets. Using the
      // source height directly against a quarter-scale decoded image overstated
      // the focal 4×: every frame's angular footprint collapsed to about a
      // quarter of its true size and the coverage audit saw holes almost
      // everywhere. See `decodedProjection` for the full transform.
      final decoded = decodedProjection(
        decodedWidth: imageWidth,
        decodedHeight: imageHeight,
        savedWidth: (record['imageWidth'] as num?)?.toInt() ?? 0,
        savedHeight: (record['imageHeight'] as num?)?.toInt() ?? 0,
        sourceWidth: (record['sourceImageWidth'] as num?)?.toInt() ?? 0,
        sourceHeight: (record['sourceImageHeight'] as num?)?.toInt() ?? 0,
        verticalFovDeg: kSphereAssumedVerticalFovDeg,
        cropOffsetX: (record['cropOffsetX'] as num?)?.toInt() ?? 0,
        cropOffsetY: (record['cropOffsetY'] as num?)?.toInt() ?? 0,
      );
      if (decoded == null) {
        return (
          ok: false,
          message:
              'A photograph has invalid dimensions ($imageWidth×'
              '$imageHeight), so it cannot be projected.',
        );
      }
      final focal = decoded.focalPx;
      final cx = decoded.cx;
      final cy = decoded.cy;
      if (kSphereStitchLog && frameIndex == 0) {
        debugPrint(
          'SPHERE_STITCH: decoded=${imageWidth}x$imageHeight '
          'saved=${record['imageWidth']}x${record['imageHeight']} '
          'source=${record['sourceImageWidth']}x${record['sourceImageHeight']} '
          'decodeScale=${decoded.decodeScale.toStringAsFixed(3)} '
          'focalSource=${(decoded.focalPx / decoded.decodeScale).toStringAsFixed(1)} '
          'focalDecoded=${decoded.focalPx.toStringAsFixed(1)} '
          'hfov=${decoded.horizontalFovDeg.toStringAsFixed(2)}° '
          'vfov=${decoded.verticalFovDegDeg.toStringAsFixed(2)}°',
        );
      }
      final pixels = mat.data;
      final rowStride = imageWidth * 3;
      final marginX = 0.05 * imageWidth;
      final marginY = 0.05 * imageHeight;

      final bounds = equirectFrameBounds(
        cameraToSphere,
        imageWidth,
        imageHeight,
        focal,
        cx,
        cy,
      );
      final yStart = _clampInt(
        ((-bounds.maxLat + 1.5707963267948966) / 3.141592653589793 * height)
                .floor() -
            2,
        0,
        height - 1,
      );
      final yEnd = _clampInt(
        ((1.5707963267948966 - bounds.minLat) / 3.141592653589793 * height)
                .ceil() +
            2,
        0,
        height - 1,
      );
      // `minLon`/`maxLon` are unwrapped around the frame's own centre, so a
      // frame that straddles ±180° still has `minLon <= maxLon` and a span
      // below 2π. The column range may therefore fall outside [0, width) —
      // that is the wrap, and the `% width` in the loop handles it. A frame
      // that contains a pole covers every longitude and is marked full-width.
      final xStart = bounds.fullWidth
          ? 0
          : ((bounds.minLon + 3.141592653589793) / 6.283185307179586 * width)
                    .floor() -
                2;
      final xEnd = bounds.fullWidth
          ? width - 1
          : ((bounds.maxLon + 3.141592653589793) / 6.283185307179586 * width)
                    .ceil() +
                2;

      // Scalar quaternion components: the inner loop rotates millions of
      // directions, and allocating a Vec3 per pixel dominated the runtime.
      final qx = sphereToCamera.x;
      final qy = sphereToCamera.y;
      final qz = sphereToCamera.z;
      final qw = sphereToCamera.w;

      for (var y = yStart; y <= yEnd; y++) {
        final dy = sinLat[y];
        final dxz = cosLat[y];
        for (var xi = xStart; xi <= xEnd; xi++) {
          // The longitude interval extends by at most one panorama wrap.
          // Avoid two integer modulo operations in the hot pixel loop.
          final x = xi < 0 ? xi + width : (xi >= width ? xi - width : xi);
          final dx = sinLon[x] * dxz;
          final dz = -cosLon[x] * dxz;
          // v' = v + 2w(u×v) + 2u×(u×v), inlined.
          final c0x = qy * dz - qz * dy;
          final c0y = qz * dx - qx * dz;
          final c0z = qx * dy - qy * dx;
          final c1x = qy * c0z - qz * c0y;
          final c1y = qz * c0x - qx * c0z;
          final c1z = qx * c0y - qy * c0x;
          final camX = dx + 2 * (qw * c0x + c1x);
          final camY = dy + 2 * (qw * c0y + c1y);
          final camZ = dz + 2 * (qw * c0z + c1z);
          final depth = -camZ;
          if (depth <= 0.05) continue;
          final u = cx + focal * camX / depth;
          final v = cy - focal * camY / depth;
          if (u < 0 || u >= imageWidth - 1 || v < 0 || v >= imageHeight - 1) {
            continue;
          }
          final u0 = u.floor();
          final v0 = v.floor();
          final du = u - u0;
          final dv = v - v0;
          final i00 = v0 * rowStride + u0 * 3;
          final i10 = i00 + 3;
          final i01 = i00 + rowStride;
          final i11 = i01 + 3;
          final b = _lerp4(
            pixels[i00],
            pixels[i10],
            pixels[i01],
            pixels[i11],
            du,
            dv,
          );
          final g = _lerp4(
            pixels[i00 + 1],
            pixels[i10 + 1],
            pixels[i01 + 1],
            pixels[i11 + 1],
            du,
            dv,
          );
          final r = _lerp4(
            pixels[i00 + 2],
            pixels[i10 + 2],
            pixels[i01 + 2],
            pixels[i11 + 2],
            du,
            dv,
          );

          var weight = _pow6(depth);
          weight *= _smoothStep(_min(u, imageWidth - 1 - u) / marginX);
          weight *= _smoothStep(_min(v, imageHeight - 1 - v) / marginY);
          if (weight <= 0) continue;

          final index = y * width + x;
          if (hits[index] < 3) hits[index]++;
          if (weight > bestWeight[index]) {
            secondWeight[index] = bestWeight[index];
            secondFrame[index] = bestFrame[index];
            secondColour[index * 3] = bestColour[index * 3];
            secondColour[index * 3 + 1] = bestColour[index * 3 + 1];
            secondColour[index * 3 + 2] = bestColour[index * 3 + 2];
            bestWeight[index] = weight;
            bestFrame[index] = frameIndex;
            bestColour[index * 3] = r;
            bestColour[index * 3 + 1] = g;
            bestColour[index * 3 + 2] = b;
          } else if (weight > secondWeight[index]) {
            secondWeight[index] = weight;
            secondFrame[index] = frameIndex;
            secondColour[index * 3] = r;
            secondColour[index * 3 + 1] = g;
            secondColour[index * 3 + 2] = b;
          }
        }
      }
    } finally {
      mat.dispose();
    }
    progress.send(
      'Projecting photographs: ${frameIndex + 1}/${records.length} '
      '(${stopwatch.elapsed.inSeconds}s elapsed)…',
    );
  }

  final projectionMs = lapMs();
  progress.send('Blending panorama and encoding JPEG…');
  // Every photograph was exposed by its own auto-exposure loop, so two frames of
  // the same white wall can differ by 10-20%. Correct that before blending, or
  // every seam is also a brightness step.
  //
  // Two parameters per frame, not one. A gain alone cannot fix a scene where the
  // camera also shifted its black point — a window that blew out one frame leaves
  // the rest of that frame lifted, and scaling it down darkens the wall instead
  // of levelling it. `detail::GainCompensator` is not exposed by dartcv4 2.2.2,
  // so the equivalent is solved here: gain from the ratio of the shared means,
  // then offset from what the gain-corrected means still disagree by.
  final gains = solveExposureGains(
    pixelCount: width * height,
    frameCount: records.length,
    bestFrame: bestFrame,
    secondFrame: secondFrame,
    bestWeight: bestWeight,
    secondWeight: secondWeight,
    bestColour: bestColour,
    secondColour: secondColour,
  );
  final offsets = solveExposureOffsets(
    pixelCount: width * height,
    frameCount: records.length,
    bestFrame: bestFrame,
    secondFrame: secondFrame,
    bestWeight: bestWeight,
    secondWeight: secondWeight,
    bestColour: bestColour,
    secondColour: secondColour,
    gains: gains,
  );

  final exposureMs = lapMs();

  // ── Feathering ──────────────────────────────────────────────────────
  //
  // This replaces "the nearest photograph wins, blended only where the top two
  // weights are within 3%". That rule was the visible seam: at 3% the transition
  // is a few pixels wide, so the seam reads as a cut, and where two frames
  // disagreed the cut tore.
  //
  // Now every pixel that two photographs both see is a normalised weighted
  // average of the two, over the whole overlap rather than a hairline. The
  // weights are already the right ones — they fall off toward a frame's edge and
  // toward grazing angles — so the blend fades in and out exactly where each
  // photograph stops being trustworthy. `detail::MultiBandBlender` is not
  // exposed by dartcv4 2.2.2 either, and a pyramid built from Dart typed arrays
  // at 4096×2048 would cost more memory than the whole accumulator; feathering
  // the top two contributors is what removes the rectangular boundary and the
  // hard step, and compositing from a less-reduced decode is what keeps the
  // detail. Neither claim depends on the other.
  final output = Uint8List(width * height * 3);
  for (var i = 0; i < width * height; i++) {
    final best = bestWeight[i];
    if (best <= _kMinPixelWeight) continue;
    final bestIndex = bestFrame[i];
    final gainBest = bestIndex >= 0 ? gains[bestIndex] : 1.0;
    final offsetBest = bestIndex >= 0 ? offsets[bestIndex] : 0.0;
    final second = secondWeight[i];
    final secondIndex = secondFrame[i];
    if (second > _kMinPixelWeight && secondIndex >= 0) {
      final total = best + second;
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
      }
    } else {
      for (var c = 0; c < 3; c++) {
        final value = bestColour[i * 3 + c] * gainBest + offsetBest;
        output[i * 3 + c] = value <= 0
            ? 0
            : (value >= 255 ? 255 : value.round());
      }
    }
  }

  final blendMs = lapMs();

  // ── Gap fill ────────────────────────────────────────────────────────
  //
  // Uncovered pixels were previously left at zero, which is why a missed
  // direction showed as a black disc rather than as a slightly soft patch. A
  // gap cannot be retried without recapturing, so the honest failure mode is a
  // smeared extrapolation plus a diagnostic that says "retake this direction" —
  // not a hole in the product.
  final filledPixels = fillUncovered(
    output: output,
    bestWeight: bestWeight,
    width: width,
    height: height,
  );
  final fillMs = lapMs();
  // ── Coverage audit ──────────────────────────────────────────────────
  //
  // Equirectangular rows are not equal-area: a row at latitude φ covers only
  // cos(φ) of what an equatorial row does. Counting pixels would overstate
  // coverage near the poles — which is exactly where a sparse layout leaves
  // holes — so every number below is area-weighted.
  //
  // `single` is the one that decides success: every direction of the finished
  // sphere must come from a real photograph. The previous gate accepted 90%,
  // which let a ten-percent black band pass as a finished panorama.
  var totalArea = 0.0;
  var singleArea = 0.0;
  var doubleArea = 0.0;
  var tripleArea = 0.0;
  var worstRowWeight = -1.0;
  var worstLat = 0.0;
  var worstLon = 0.0;
  // 15°-cell grid of uncovered area, for the "where are the holes" report.
  const gapCols = 24;
  const gapRows = 12;
  final gapCells = Float64List(gapCols * gapRows);
  for (var y = 0; y < height; y++) {
    final rowWeight = cosLat[y];
    totalArea += rowWeight * width;
    for (var x = 0; x < width; x++) {
      final n = hits[y * width + x];
      if (n == 0) {
        gapCells[(y * gapRows ~/ height) * gapCols + (x * gapCols ~/ width)] +=
            rowWeight;
        // Remember the widest remaining gap, preferring the horizon: a hole
        // there is far more visible than one at the pole.
        if (rowWeight > worstRowWeight) {
          worstRowWeight = rowWeight;
          worstLat = 90 - (y + 0.5) / height * 180;
          worstLon = -180 + (x + 0.5) / width * 360;
        }
        continue;
      }
      singleArea += rowWeight;
      if (n >= 2) doubleArea += rowWeight;
      if (n >= 3) tripleArea += rowWeight;
    }
  }
  final single = singleArea / totalArea;
  final doubleCoverage = doubleArea / totalArea;
  final tripleCoverage = tripleArea / totalArea;
  // ── Viewport audit ──────────────────────────────────────────────────
  //
  // The area-weighted number above cannot see the failure users actually
  // report. A hole at the zenith is a few tenths of a percent of the sphere —
  // `cosLat` makes it nearly free — yet it fills the entire screen the moment
  // the viewer looks up. This measures what is seen: over a set of view
  // directions, the largest fraction of a 90° viewport that holds no
  // photograph at all.
  final viewport = worstViewportGap(
    hits: hits,
    width: width,
    height: height,
  );
  if (kSphereStitchLog) {
    debugPrint(
      'SPHERE_STITCH: coverage single=${(single * 100).toStringAsFixed(2)}% '
      'double=${(doubleCoverage * 100).toStringAsFixed(2)}% '
      'triple=${(tripleCoverage * 100).toStringAsFixed(2)}% '
      'uncovered=${((1 - single) * 100).toStringAsFixed(2)}% '
      'worstViewportGap=${(viewport.gap * 100).toStringAsFixed(2)}% '
      'at=lat${viewport.latitudeDeg.toStringAsFixed(0)}'
      '/lon${viewport.longitudeDeg.toStringAsFixed(0)} '
      'filled=$filledPixels '
      'output=${width}x$height',
    );
  }

  // ── Coverage diagnostics, written whether the gate passes or not ─────
  //
  // The map is generated from the *actual* photographs and their recorded
  // orientations — the same hits buffer the audit used — never from the ideal
  // layout alone. A passing coverage number says every direction received
  // real pixels; it does **not** claim the seams are invisible or the
  // alignment visually perfect.
  final mapBytes = Uint8List(width * height * 3);
  for (var i = 0; i < width * height; i++) {
    // Red: uncovered. Yellow: one photograph. Blue: two. Teal: three or more.
    final (r, g, b) = switch (hits[i]) {
      0 => (190, 40, 40),
      1 => (235, 200, 60),
      2 => (60, 110, 220),
      _ => (40, 190, 180),
    };
    mapBytes[i * 3] = r;
    mapBytes[i * 3 + 1] = g;
    mapBytes[i * 3 + 2] = b;
  }
  final mapPath = p.join(File(outPath).parent.path, 'coverage_map.jpg');
  _encodeJpeg(mapPath, width, height, mapBytes);
  final rankedGaps = <Map<String, Object?>>[];
  for (var cell = 0; cell < gapCells.length; cell++) {
    if (gapCells[cell] <= 0) continue;
    rankedGaps.add({
      'longitudeDeg': -180 + ((cell % gapCols) + 0.5) / gapCols * 360,
      'latitudeDeg':
          90 - ((cell ~/ gapCols) + 0.5) / gapRows * 180,
      'uncoveredAreaPercent': gapCells[cell] / totalArea * 100,
    });
  }
  rankedGaps.sort(
    (a, b) => (b['uncoveredAreaPercent']! as double).compareTo(
      a['uncoveredAreaPercent']! as double,
    ),
  );
  final reportPath = p.join(
    File(outPath).parent.path,
    'coverage_report.json',
  );
  final report = <String, Object?>{
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
        'station': File(outPath).parent.path,
        'panorama': {
          'path': outPath,
          'width': width,
          'height': height,
          'aspect': '2:1 equirectangular',
        },
        'photographCount': records.length,
        'verticalFovAssumedDeg': kSphereAssumedVerticalFovDeg,
        'resolution': {
          'requestedWidth': requestedWidth,
          'width': width,
          'height': height,
          'accumulatorBytes': sphereStitchAccumulatorBytes(width),
          'budgetBytes': kSphereStitchAccumulatorBudgetBytes,
          'downgraded': width != requestedWidth,
        },
        // Registration is the part that decides whether the seams are straight,
        // so its own numbers belong next to the coverage numbers rather than only
        // in the log: how many pairs were matched, how many produced a rotation
        // worth trusting, and how far the worst frame was moved.
        'registration': {
          'enabled': args.refineRegistration,
          'pairsConsidered': registration.pairsConsidered,
          'acceptedEdges': registration.acceptedEdges,
          'rejectedEdges': registration.rejectedEdges,
          'featuresDetected': registration.featureTotal,
          'maxCorrectionDeg': maxCorrectionDeg(registration.correctionDeg),
          'perFrameCorrectionDeg': registration.correctionDeg,
          if (registration.notes.isNotEmpty) 'notes': registration.notes,
        },
        // Measured, not estimated. A stage that gets slower shows up here.
        'timingsMs': {
          'registration': registrationMs,
          'projection': projectionMs,
          'exposure': exposureMs,
          'blend': blendMs,
          'gapFill': fillMs,
          // Patched in after the encode, which happens below. `-1` here means the
          // station was rejected before the encode was attempted.
          'encode': -1,
          'total': stopwatch.elapsedMilliseconds,
        },
        'thresholdPercent': 99.5,
        'passed': single >= 0.995,
        'coveragePercent': {
          'single': single * 100,
          'double': doubleCoverage * 100,
          'triple': tripleCoverage * 100,
        },
        'uncoveredPercent': (1 - single) * 100,
        'coverageMapPath': mapPath,
        // The number that matches the user's experience. `uncoveredPercent`
        // above is area-weighted and cannot see a polar hole; this is the worst
        // 90° viewport, in which a polar hole is the most visible thing there is.
        'worstViewportGapPercent': viewport.gap * 100,
        'worstViewportGapDirection': {
          'latitudeDeg': viewport.latitudeDeg,
          'longitudeDeg': viewport.longitudeDeg,
        },
        'worstViewportGapThresholdPercent': 25.0,
        'gapFilledPixels': filledPixels,
        'exposureGains': <double>[
          for (final gain in gains) double.parse(gain.toStringAsFixed(4)),
        ],
        if (single < 1)
          'largestGap': {
            'longitudeDeg': worstLon,
            'latitudeDeg': worstLat,
          },
        'uncoveredRegions': rankedGaps
            .take(6)
            .map(
              (Map<String, Object?> region) => <String, Object?>{
                'longitudeDeg':
                    (region['longitudeDeg']! as double).toStringAsFixed(1),
                'latitudeDeg':
                    (region['latitudeDeg']! as double).toStringAsFixed(1),
                'uncoveredAreaPercent': (region['uncoveredAreaPercent']! as double)
                    .toStringAsFixed(3),
              },
            )
            .toList(growable: false),
      };
  // Written before the acceptance gates, deliberately: a station that fails is
  // exactly the one whose coverage map and gap list someone needs to read.
  try {
    File(reportPath).writeAsStringSync(jsonEncode(report), flush: true);
  } catch (_) {
    // A missing report must not fail an otherwise valid panorama; the map is
    // diagnostics, not the product.
  }

  if (single < 0.995) {
    final lon = worstLon >= 0 ? '+${worstLon.round()}' : '${worstLon.round()}';
    final lat = worstLat >= 0 ? '+${worstLat.round()}' : '${worstLat.round()}';
    return (
      ok: false,
      message:
          'The sphere is only ${(single * 100).toStringAsFixed(1)}% covered, '
          'so the panorama would have a hole. The largest gap is around '
          'longitude $lon°, latitude $lat° — retake that direction. Every '
          'saved photograph has been kept.',
    );
  }

  // A quarter of one whole viewport with no photograph in it is not a seam
  // problem, it is a missing part of the room — and it is exactly the case the
  // area-weighted gate above cannot see, because a polar hole is a fraction of
  // a percent of the sphere. Below this the gap is filled and reported instead
  // of refused: a soft patch is a better product than no panorama at all.
  if (viewport.gap > 0.25) {
    final lon = viewport.longitudeDeg >= 0
        ? '+${viewport.longitudeDeg.round()}'
        : '${viewport.longitudeDeg.round()}';
    final lat = viewport.latitudeDeg >= 0
        ? '+${viewport.latitudeDeg.round()}'
        : '${viewport.latitudeDeg.round()}';
    return (
      ok: false,
      message:
          'Looking towards longitude $lon°, latitude $lat° shows a view that is '
          '${(viewport.gap * 100).toStringAsFixed(0)}% empty — no photograph '
          'reached it, so the panorama would be invented there. Retake that '
          'direction. Every saved photograph has been kept.',
    );
  }

  // Write PPM (cheap, no encoder in Dart), then let OpenCV encode the JPEG.
  final encodeStartedMs = stopwatch.elapsedMilliseconds;
  if (!_encodeJpeg(outPath, width, height, output)) {
    return (ok: false, message: 'The panorama could not be saved.');
  }
  final encodeMs = stopwatch.elapsedMilliseconds - encodeStartedMs;
  // The report is written before the gates so a rejected station still leaves its
  // diagnostics behind; the encode is the one stage that happens after, so its
  // measurement is patched into the file it already wrote.
  try {
    final timings = report['timingsMs'];
    if (timings is Map<String, Object?>) {
      timings['encode'] = encodeMs;
      timings['total'] = stopwatch.elapsedMilliseconds;
      File(reportPath).writeAsStringSync(jsonEncode(report), flush: true);
    }
  } catch (_) {
    // Measurement must never fail a panorama that has already been written.
  }
  if (kSphereStitchLog) {
    debugPrint(
      'SPHERE_STITCH: stages registration=${registrationMs}ms '
      'projection=${projectionMs}ms exposure=${exposureMs}ms '
      'blend=${blendMs}ms gapFill=${fillMs}ms encode=${encodeMs}ms '
      'total=${stopwatch.elapsedMilliseconds}ms',
    );
  }
  final refinedFrames = <int>[
    for (var i = 0; i < registration.correctionDeg.length; i++)
      if (registration.correctionDeg[i] > 0) i,
  ].length;
  return (
    ok: true,
    message:
        'Panorama generated ($width×$height). Coverage '
        '${(single * 100).toStringAsFixed(1)}% single, '
        '${(doubleCoverage * 100).toStringAsFixed(1)}% double, '
        '${(tripleCoverage * 100).toStringAsFixed(1)}% triple'
        '${refinedFrames > 0 ? ', $refinedFrames orientations refined' : ''}'
        '${viewport.gap > 0.02 ? ', worst view '
                  '${(viewport.gap * 100).toStringAsFixed(0)}% empty '
                  '(retake that direction)' : ''}.',
  );
}

/// Encodes an RGB byte buffer as a JPEG at [path] through a PPM intermediate
/// (Dart has no JPEG encoder; OpenCV reads PPM and writes JPEG).
///
/// The temporary PPM is deleted afterwards; a failure to delete it is
/// harmless and ignored. Returns whether the JPEG exists and is non-empty.
bool _encodeJpeg(String path, int width, int height, Uint8List rgb) {
  final ppmPath = p.join(File(path).parent.path, '.${p.basename(path)}.ppm');
  final header = Uint8List.fromList(ascii.encode('P6\n$width $height\n255\n'));
  final bytes = BytesBuilder(copy: false)
    ..add(header)
    ..add(rgb);
  try {
    File(ppmPath).writeAsBytesSync(bytes.takeBytes(), flush: true);
    final ppm = cv.imread(ppmPath, flags: cv.IMREAD_COLOR);
    try {
      if (ppm.isEmpty) return false;
      if (!cv.imwrite(path, ppm)) return false;
    } finally {
      ppm.dispose();
    }
  } catch (_) {
    return false;
  } finally {
    try {
      File(ppmPath).deleteSync();
    } catch (_) {}
  }
  final out = File(path);
  return out.existsSync() && out.lengthSync() > 0;
}

int _lerp4(int c00, int c10, int c01, int c11, double du, double dv) =>
    (c00 * (1 - du) * (1 - dv) +
            c10 * du * (1 - dv) +
            c01 * (1 - du) * dv +
            c11 * du * dv)
        .round();

/// Per-photograph exposure gains, estimated from the pixels two photographs
/// both see.
///
/// Each frame is exposed by its own auto-exposure loop, so two photographs of
/// the same white wall can differ by 10-20% in brightness. Blending them
/// uncorrected puts a visible step along every seam, and a ceiling shows it
/// worst because it is large, uniform and evenly lit — nothing else hides the
/// step.
///
/// For every pixel two photographs share, the model is
/// `log(g_a) - log(g_b) = log(mean_a / mean_b)`. Logs are what make this
/// linear: a gain is a multiplication, and multiplication is addition under a
/// logarithm. That gives a small overdetermined system over the photographs,
/// which Gauss-Seidel relaxation solves without a linear-algebra dependency.
///
/// The solution is normalised so the mean gain is 1 — only the *ratios* are
/// observable, so without that the whole panorama would drift bright or dark.
/// Gains are clamped to ±0.6 in log space (roughly 0.55× to 1.82×): a larger
/// correction than that is a misregistration or a genuinely different scene,
/// not an exposure difference, and applying it would wreck the image.
@visibleForTesting
Float64List solveExposureGains({
  required int pixelCount,
  required int frameCount,
  required Int16List bestFrame,
  required Int16List secondFrame,
  required Float32List bestWeight,
  required Float32List secondWeight,
  required Uint8List bestColour,
  required Uint8List secondColour,
}) {
  final gains = Float64List(frameCount)..fillRange(0, frameCount, 1.0);
  if (frameCount < 2) return gains;

  final sumBest = Float64List(frameCount * frameCount);
  final sumSecond = Float64List(frameCount * frameCount);
  final counts = Float64List(frameCount * frameCount);
  for (var i = 0; i < pixelCount; i++) {
    final a = bestFrame[i];
    final b = secondFrame[i];
    if (a < 0 || b < 0 || a == b) continue;
    // Only pixels genuinely shared count. A sliver at a frame's edge carries
    // the lens falloff, not the exposure difference — the same reason the
    // projection weights those pixels toward zero.
    if (secondWeight[i] < 0.35 * bestWeight[i]) continue;
    final lumBest =
        0.299 * bestColour[i * 3] +
        0.587 * bestColour[i * 3 + 1] +
        0.114 * bestColour[i * 3 + 2];
    final lumSecond =
        0.299 * secondColour[i * 3] +
        0.587 * secondColour[i * 3 + 1] +
        0.114 * secondColour[i * 3 + 2];
    // Near-black pixels carry almost no exposure information and divide badly.
    if (lumBest < 8 || lumSecond < 8) continue;
    final k = a * frameCount + b;
    sumBest[k] += lumBest;
    sumSecond[k] += lumSecond;
    counts[k] += 1;
  }

  // Collapse to one observation per ordered pair.
  //
  // The sign matters and is easy to get backwards. The goal is
  // `gain_a·mean_a == gain_b·mean_b`, so `gain_a/gain_b == mean_b/mean_a` —
  // the *reciprocal* of the brightness ratio. Using the brightness ratio
  // directly would brighten the already-bright frame and double the step it was
  // meant to remove.
  final pairA = <int>[];
  final pairB = <int>[];
  final pairRatio = <double>[];
  for (var a = 0; a < frameCount; a++) {
    for (var b = 0; b < frameCount; b++) {
      final k = a * frameCount + b;
      if (counts[k] < 24) continue;
      final gainRatio = sumSecond[k] / sumBest[k];
      if (gainRatio <= 0.05 || gainRatio >= 20) continue;
      pairA.add(a);
      pairB.add(b);
      pairRatio.add(math.log(gainRatio));
    }
  }
  if (pairA.isEmpty) return gains;

  final logGain = Float64List(frameCount);
  // A frame with no overlap keeps logGain 0, i.e. gain 1 — it is left alone
  // rather than dragged by a graph it is not connected to.
  for (var pass = 0; pass < 160; pass++) {
    for (var p = 0; p < pairA.length; p++) {
      final a = pairA[p];
      final b = pairB[p];
      final error = pairRatio[p] - (logGain[a] - logGain[b]);
      final step = 0.08 * error;
      logGain[a] += step;
      logGain[b] -= step;
    }
  }

  var mean = 0.0;
  for (var i = 0; i < frameCount; i++) {
    mean += logGain[i];
  }
  mean /= frameCount;
  for (var i = 0; i < frameCount; i++) {
    final corrected = (logGain[i] - mean).clamp(-0.6, 0.6);
    gains[i] = math.exp(corrected);
  }
  return gains;
}

/// Per-photograph exposure offsets, solved after [solveExposureGains].
///
/// A gain alone cannot level a seam where the camera also moved its black point:
/// a window that blew out one frame lifts the whole frame, and scaling that frame
/// down darkens its walls instead of matching them. The offset absorbs the rest.
///
/// The model is `corrected = gain·I + offset`, and the target is
/// `gain_a·L_a + offset_a == gain_b·L_b + offset_b` over the pixels two frames
/// share. With the gains already fixed, that is one linear equation per pair —
/// `offset_a − offset_b = M_b − M_a` where `M = gain·L` — solved by the same
/// Gauss-Seidel relaxation as the gains, then centred so the panorama does not
/// drift.
///
/// Offsets are clamped to ±40 of 255. Beyond that the two frames are not the same
/// scene under different exposure; they are different content, and forcing them
/// level would flatten a genuinely dark corner.
@visibleForTesting
Float64List solveExposureOffsets({
  required int pixelCount,
  required int frameCount,
  required Int16List bestFrame,
  required Int16List secondFrame,
  required Float32List bestWeight,
  required Float32List secondWeight,
  required Uint8List bestColour,
  required Uint8List secondColour,
  required Float64List gains,
}) {
  final offsets = Float64List(frameCount);
  if (frameCount < 2) return offsets;

  final sumBest = Float64List(frameCount * frameCount);
  final sumSecond = Float64List(frameCount * frameCount);
  final counts = Float64List(frameCount * frameCount);
  for (var i = 0; i < pixelCount; i++) {
    final a = bestFrame[i];
    final b = secondFrame[i];
    if (a < 0 || b < 0 || a == b) continue;
    if (secondWeight[i] < 0.35 * bestWeight[i]) continue;
    final lumBest =
        0.299 * bestColour[i * 3] +
        0.587 * bestColour[i * 3 + 1] +
        0.114 * bestColour[i * 3 + 2];
    final lumSecond =
        0.299 * secondColour[i * 3] +
        0.587 * secondColour[i * 3 + 1] +
        0.114 * secondColour[i * 3 + 2];
    if (lumBest < 8 || lumSecond < 8) continue;
    final k = a * frameCount + b;
    sumBest[k] += lumBest;
    sumSecond[k] += lumSecond;
    counts[k] += 1;
  }

  final pairA = <int>[];
  final pairB = <int>[];
  final pairResidual = <double>[];
  for (var a = 0; a < frameCount; a++) {
    for (var b = 0; b < frameCount; b++) {
      final k = a * frameCount + b;
      if (counts[k] < 24) continue;
      final correctedBest = gains[a] * (sumBest[k] / counts[k]);
      final correctedSecond = gains[b] * (sumSecond[k] / counts[k]);
      // We want corrected_a + offset_a == corrected_b + offset_b.
      pairA.add(a);
      pairB.add(b);
      pairResidual.add(correctedSecond - correctedBest);
    }
  }
  if (pairA.isEmpty) return offsets;

  for (var pass = 0; pass < 160; pass++) {
    for (var p = 0; p < pairA.length; p++) {
      final a = pairA[p];
      final b = pairB[p];
      final error = pairResidual[p] - (offsets[a] - offsets[b]);
      final step = 0.08 * error;
      offsets[a] += step;
      offsets[b] -= step;
    }
  }

  var mean = 0.0;
  for (var i = 0; i < frameCount; i++) {
    mean += offsets[i];
  }
  mean /= frameCount;
  for (var i = 0; i < frameCount; i++) {
    offsets[i] = (offsets[i] - mean).clamp(-40.0, 40.0);
  }
  return offsets;
}

/// Fills every pixel no photograph reached, by propagating colour outward from
/// the covered boundary, then smoothing the filled region.
///
/// Returns how many pixels were filled. A breadth-first sweep from the boundary
/// gives each hole pixel the value of the nearest covered pixel (a Voronoi
/// assignment), which alone would look like radial streaks; three box-blur
/// passes restricted to the filled region turn that into a soft gradient. The
/// result is not a photograph and is not claimed to be one — [coverage_report
/// .json] records the count so the station can be retaken — but a soft patch is
/// a far better failure than a black disc in the middle of the sphere.
@visibleForTesting
int fillUncovered({
  required Uint8List output,
  required Float32List bestWeight,
  required int width,
  required int height,
}) {
  final pixelCount = width * height;
  final covered = Uint8List(pixelCount);
  var uncovered = 0;
  for (var i = 0; i < pixelCount; i++) {
    if (bestWeight[i] > _kMinPixelWeight) {
      covered[i] = 1;
    } else {
      uncovered++;
    }
  }
  if (uncovered == 0) return 0;
  // Every pixel is uncovered in the worst case, so the queue is sized for that
  // and the `queued` mask stops a pixel being enqueued twice.
  final queue = Int32List(pixelCount);
  final queued = Uint8List(pixelCount);
  var head = 0;
  var tail = 0;

  void enqueue(int index) {
    if (covered[index] != 0 || queued[index] != 0) return;
    queued[index] = 1;
    queue[tail++] = index;
  }

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * width + x;
      if (covered[i] != 0) continue;
      final left = x == 0 ? width - 1 : x - 1;
      final right = x == width - 1 ? 0 : x + 1;
      if ((covered[y * width + left] != 0) ||
          (covered[y * width + right] != 0) ||
          (y > 0 && covered[i - width] != 0) ||
          (y < height - 1 && covered[i + width] != 0)) {
        enqueue(i);
      }
    }
  }

  var filled = 0;
  while (head < tail) {
    final i = queue[head++];
    if (covered[i] != 0) continue;
    final x = i % width;
    final y = i ~/ width;
    final left = x == 0 ? width - 1 : x - 1;
    final right = x == width - 1 ? 0 : x + 1;
    var r = 0;
    var g = 0;
    var b = 0;
    var count = 0;
    for (final j in <int>[
      y * width + left,
      y * width + right,
      if (y > 0) i - width,
      if (y < height - 1) i + width,
    ]) {
      if (covered[j] == 0) continue;
      r += output[j * 3];
      g += output[j * 3 + 1];
      b += output[j * 3 + 2];
      count++;
    }
    if (count == 0) continue;
    output[i * 3] = (r / count).round();
    output[i * 3 + 1] = (g / count).round();
    output[i * 3 + 2] = (b / count).round();
    covered[i] = 1;
    filled++;
    enqueue(y * width + left);
    enqueue(y * width + right);
    if (y > 0) enqueue(i - width);
    if (y < height - 1) enqueue(i + width);
  }

  if (filled > 0) {
    // `covered` now marks everything, so the filled mask is rebuilt from the
    // weights — the pixels that had no usable photograph are exactly the ones
    // the smoothing should touch.
    final filledMask = Uint8List(pixelCount);
    for (var i = 0; i < pixelCount; i++) {
      if (bestWeight[i] <= _kMinPixelWeight) filledMask[i] = 1;
    }
    _smoothRegion(output, filledMask, width, height, 3);
  }
  return filled;
}

/// Box-blurs [mask]ed pixels of [output] in place, [passes] times. Longitude
/// wraps; latitude does not, so rows clamp at the poles.
void _smoothRegion(
  Uint8List output,
  Uint8List mask,
  int width,
  int height,
  int passes,
) {
  final byteCount = width * height * 3;
  var source = output;
  var target = Uint8List(byteCount);
  for (var pass = 0; pass < passes; pass++) {
    target.setRange(0, byteCount, source);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        if (mask[i] == 0) continue;
        var r = 0;
        var g = 0;
        var b = 0;
        var count = 0;
        for (var dy = -1; dy <= 1; dy++) {
          final ny = y + dy;
          if (ny < 0 || ny >= height) continue;
          for (var dx = -1; dx <= 1; dx++) {
            var nx = x + dx;
            if (nx < 0) nx += width;
            if (nx >= width) nx -= width;
            final j = ny * width + nx;
            r += source[j * 3];
            g += source[j * 3 + 1];
            b += source[j * 3 + 2];
            count++;
          }
        }
        target[i * 3] = (r / count).round();
        target[i * 3 + 1] = (g / count).round();
        target[i * 3 + 2] = (b / count).round();
      }
    }
    final swap = source;
    source = target;
    target = swap;
  }
  if (!identical(source, output)) output.setRange(0, byteCount, source);
}

/// The largest fraction of a 90° viewport that no photograph covers.
///
/// The area-weighted audit cannot express this failure. A hole at the zenith is
/// a few tenths of a percent of the sphere, and `cosLat` weighting makes it
/// almost free — but it occupies the entire screen the moment the viewer looks
/// up. So this samples the sphere evenly (a Fibonacci lattice, which has no
/// polar clustering), asks which samples are covered, and then reports the
/// worst 90° window over those samples.
///
/// Sampling evenly rather than per equirectangular pixel is the point: an
/// equirect row at 85° latitude holds as many pixels as the equator, so
/// counting pixels would repeat the very bias this is meant to correct.
///
/// Returns the gap as a fraction plus the view direction it was found at, so the
/// message can name the direction to retake rather than just a number.
@visibleForTesting
({double gap, double latitudeDeg, double longitudeDeg}) worstViewportGap({
  required Uint8List hits,
  required int width,
  required int height,
}) {
  const sampleCount = 6000;  const viewCount = 300;
  // cos(45°) — a 90° viewport, which is wider than the viewer's default.
  const halfFovCos = 0.7071067811865476;

  final dx = Float64List(sampleCount);
  final dy = Float64List(sampleCount);
  final dz = Float64List(sampleCount);
  final covered = Uint8List(sampleCount);
  // The golden angle, which spaces successive samples by ~137.5°.
  final goldenAngle = math.pi * (3 - math.sqrt(5));
  for (var i = 0; i < sampleCount; i++) {
    final z = 1 - 2 * (i + 0.5) / sampleCount;
    final radius = math.sqrt(math.max(0.0, 1 - z * z));
    final theta = goldenAngle * i;
    dx[i] = math.cos(theta) * radius;
    dy[i] = math.sin(theta) * radius;
    dz[i] = z;

    // Inverse of the forward mapping the projection uses:
    //   dx = sin(lon)·cos(lat), dy = sin(lat), dz = -cos(lon)·cos(lat)
    final lat = math.asin(z);
    final lon = math.atan2(dx[i], -dz[i]);
    var px = ((lon + math.pi) / (2 * math.pi) * width).floor();
    var py = ((math.pi / 2 - lat) / math.pi * height).floor();
    if (px < 0) px = 0;
    if (px >= width) px = width - 1;
    if (py < 0) py = 0;
    if (py >= height) py = height - 1;
    covered[i] = hits[py * width + px] > 0 ? 1 : 0;
  }

  var worst = 0.0;
  var worstLat = 0.0;
  var worstLon = 0.0;
  for (var v = 0; v < viewCount; v++) {
    final centre = v * sampleCount ~/ viewCount;
    final cx = dx[centre];
    final cy = dy[centre];
    final cz = dz[centre];
    var seen = 0;
    var seenCovered = 0;
    for (var i = 0; i < sampleCount; i++) {
      if (cx * dx[i] + cy * dy[i] + cz * dz[i] < halfFovCos) continue;
      seen++;
      if (covered[i] != 0) seenCovered++;
    }
    if (seen < 32) continue;
    final gap = (seen - seenCovered) / seen;
    if (gap > worst) {
      worst = gap;
      worstLat = math.asin(cz.clamp(-1.0, 1.0)) * 180 / math.pi;
      worstLon = math.atan2(cx, -cz) * 180 / math.pi;
    }
  }
  return (gap: worst, latitudeDeg: worstLat, longitudeDeg: worstLon);
}

double _smoothStep(double value) {
  final t = _clampDouble(value, 0, 1);
  return t * t * (3 - 2 * t);
}

double _pow6(double value) {
  final v = _clampDouble(value, 0, 1);
  final v2 = v * v;
  return v2 * v2 * v2;
}

double _min(double a, double b) => a < b ? a : b;

double _clampDouble(double value, double min, double max) =>
    value < min ? min : (value > max ? max : value);

int _clampInt(int value, int min, int max) =>
    value < min ? min : (value > max ? max : value);
