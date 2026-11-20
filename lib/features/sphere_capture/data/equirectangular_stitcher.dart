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
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/seam_blend.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_intrinsics.dart';
import 'package:adaptive_360_capture_app/features/sphere_capture/domain/sphere_target.dart';
import 'package:adaptive_360_capture_app/features/virtual_tour/domain/math/quaternions.dart';

/// A guaranteed full-sphere equirectangular panorama from the 3DoF captures.
///
/// ## The pose projection, with an optional OpenCV band
///
/// A pure `cv::Stitcher` run was tried and abandoned: on device it returned a
/// partial fan of the room, dropping frames it could not confidently register
/// — and a hole cannot be retried without recapturing. It is also a single
/// synchronous native call over 36 images with no progress events: on the
/// phone it holds the completion dialog on one message for minutes, so it is
/// **off by default** ([kSphereEnableCvStitcher]).
///
/// The production path is therefore the pose projection: every frame has a
/// measured device quaternion in `records.json`, refined against ORB/RANSAC
/// feature matches, and coverage is complete by construction. Each frame is
/// projected onto the equirectangular canvas through that rotation, rendered
/// at full opacity on one side of a graph-cut seam, gain-matched across it,
/// and gap-filled. It finishes in seconds and no frame can be "rejected".
///
/// For experiments, `--dart-define=sphere_cv_stitch=true` adds a first tier:
/// the 36 ring frames (zenith/nadir excluded) are decoded at 720×960 and
/// stitched with `cv.Stitcher` (PANORAMA, confidence 0.35), and when it returns
/// OK its gain-compensated, multi-band-blended output is embedded over the
/// equatorial band with a 40-pixel vertical gradient, the pole caps remaining
/// pose-projected. Any non-OK status is logged verbatim
/// (`STITCHER_FAILED_STATUS:`) and the pose projection stands — the same
/// behaviour as the default path.
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
/// by a few degrees — and indoors they disagree by 20–45 px of parallax on
/// anything close: the wardrobe went translucent (the white wall showed
/// through it), the chair grew a second seat, because both positions were
/// drawn at roughly half opacity across the whole overlap.
///
/// It is now **seam compositing** — `compositeSeams` in `seam_blend.dart`.
/// Every canvas pixel is owned by exactly one photograph: a graph cut
/// (`graph_cut_seams.dart`) routes the ownership boundary through content the
/// frames agree on and around the objects they do not, and each pixel is
/// rendered at 100% opacity from its owner alone. The only cross-fade is a
/// narrow [kSeamFeatherPx]-pixel feather strictly across the seam line, so no
/// object is ever drawn at partial opacity from two positions.
///
/// Two corrections sit on top of that choice:
///
/// * **Colour.** Every photograph is exposed and white-balanced by its own
///   auto loop, so neighbouring frames of the same wall differ in brightness
///   and hue, and every seam would also be a step — a bright curtain meeting
///   a dark one reads as jagged stair-cases. [solveChannelMedianGains]
///   recovers one bounded gain per frame **per channel** from the medians of
///   the pixels frames genuinely share, so the curtain and wall brightness
///   match across the seam without luminance jumps.
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
    // The OpenCV feature-based Stitcher now runs *inside* the background
    // isolate (`_stitchRingWithOpenCv`) as the primary source for the
    // equatorial band. The old main-isolate diagnostic is gone: it duplicated
    // the ring decode and blocked the UI thread for the whole stitch.
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
    if (!result.ok) {
      debugPrint(
        'FLUTTER_STITCH: CUSTOM_FALLBACK (pose projection) FAILED — '
        '${result.message}',
      );
      return StitchResult.failure(result.message);
    }
    debugPrint(
      'FLUTTER_STITCH: CUSTOM_FALLBACK (pose projection) ok — '
      'frames=${imagePaths.length} canvas=${width}x${width ~/ 2} '
      'assumedVFov=${kSphereAssumedVerticalFovDeg.toStringAsFixed(1)}deg',
    );
    return StitchResult(
      success: true,
      panoramaPath: outPath,
      message: 'Panorama generated successfully.',
    );
  }
}

/// Whether the optional OpenCV feature-stitched band is attempted at all.
///
/// Off by default. `cv.Stitcher.stitch()` is one synchronous native call over
/// 36 images — pairwise matching, bundle adjustment, gain compensation and
/// multi-band blending — with no progress events or cancellation. On a phone
/// that can hold the completion dialog on a single message for minutes with
/// no result, and the rotation-refined pose projection already produces a
/// complete, aligned sphere. Enable explicitly with
/// `--dart-define=sphere_cv_stitch=true` for A/B comparison runs only.
const bool kSphereEnableCvStitcher = bool.fromEnvironment('sphere_cv_stitch');

/// Whether the stitcher's verbose diagnostics are compiled in. Off unless the
/// run asks for it: `--dart-define=sphere_stitch_log=true`.
const bool kSphereStitchLog = bool.fromEnvironment('sphere_stitch_log');

/// Optional conservative acceptance gate for misregistered or ghosted seams.
/// Evaluate seam metrics with real-device fixtures before enabling by default.
const bool kSphereStrictSeamIntegrity =
    bool.fromEnvironment('sphere_strict_seam_integrity');
const double kSphereMaxSeamDiscontinuity =
    double.fromEnvironment('sphere_max_seam_discontinuity', defaultValue: 16);
const double kSphereMaxGhostFraction =
    double.fromEnvironment('sphere_max_ghost_fraction', defaultValue: 0.04);

/// Opt-in strict acceptance: refuse to advertise a 100% photographed panorama
/// if even one projected pixel required synthetic gap fill. Does not remove
/// fillUncovered; it keeps diagnostics available for an incomplete attempt.
const bool kSphereRequire100PhotoCoverage =
    bool.fromEnvironment('sphere_require_100_photo_coverage');

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

  // The pose projection below is the production path: it finishes in seconds
  // and is complete by construction. The OpenCV band is an opt-in experiment
  // (see [kSphereEnableCvStitcher]) because its single native `stitch()` call
  // can hold the UI on one message for minutes with no progress or result.
  // Skipping it here avoids the stall entirely; the status is written to the
  // coverage report so a run that used the fast path says so.
  final stitcherStartedMs = stopwatch.elapsedMilliseconds;
  final ({cv.Mat? pano, String status}) stitchAttempt;
  if (kSphereEnableCvStitcher) {
    progress.send('Matching 36 ring frames with OpenCV (optional experiment)…');
    stitchAttempt = _stitchRingWithOpenCv(
      records: records,
      progress: progress.send,
    );
  } else {
    debugPrint(
      'FLUTTER_STITCH: OPENCV_STITCHER skipped — disabled by default; '
      'rotation-refined pose projection is the production path '
      '(enable with --dart-define=sphere_cv_stitch=true)',
    );
    stitchAttempt = (pano: null, status: 'disabled-by-default');
  }
  final stitcherMs = stopwatch.elapsedMilliseconds - stitcherStartedMs;

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
  final bestFrame = Int16List(width * height)..fillRange(0, width * height, -1);
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
  final decodeFlag = width <= 2048
      ? cv.IMREAD_REDUCED_COLOR_2
      : cv.IMREAD_COLOR;
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
      final cameraToSphere =
          (anchor.conjugate * rotations[frameIndex]).normalized;
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
      // SITEWISE_OBJECT_INTEGRITY_V1: bounded affine residual found by
      // 2500-feature ORB / RANSAC registration. Preserve the original image
      // and quaternion projection when there are no trustworthy matches.
      final residualAffine = frameIndex < registration.residualAffines.length
          ? registration.residualAffines[frameIndex]
          : SphereResidualAffine.identity;
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
      // Pole frames get a wider margin: their footprint on the sphere is a
      // small cap, so a few aim degrees of error leave a black crescent
      // between the Upper Ring and the Zenith. Keeping edge pixels that the
      // ring frames would reject closes that crescent without moving any
      // pixel's geometry — the gain solve and feather handle the falloff.
      final targetId = (record['targetId'] as num?)?.toInt() ?? -1;
      final isPole = targetId == 13 || targetId == 38;
      final isNadir = targetId == 38;
      final marginX = (isPole ? 0.16 : 0.05) * imageWidth;
      final marginY = (isPole ? 0.16 : 0.05) * imageHeight;

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
          final predictedU = cx + focal * camX / depth;
          final predictedV = cy - focal * camY / depth;
          // Correct small remaining 2D affine residuals only near overlaps,
          // clamped to +/-35 decoded-image pixels per axis. This is deliberately
          // not an unrestricted homography on 3D-parallax foregrounds.
          final offset = residualAffine.shiftAt(
            u: predictedU,
            v: predictedV,
            width: imageWidth,
            height: imageHeight,
          );
          final u = predictedU + offset.du;
          final v = predictedV + offset.dv;
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

          // The Nadir frame meets the Lower Ring along a circle. Its binary
          // footprint is polygonal at 2048×1024, which reads as a stair-step
          // floor seam. Erode the outer mask by 6 px, then apply a radial
          // cosine fade over the outer 30% of the frame: at r=0.7 the factor
          // is 1, at r=1 it is 0, with zero derivative at both ends. The ring
          // frames take over smoothly where the Nadir lets go.
          var weight = _pow6(depth);
          if (isNadir) {
            if (u < 6 || u > imageWidth - 7 || v < 6 || v > imageHeight - 7) {
              continue;
            }
            final r = math.sqrt(
              ((u - cx) / (imageWidth / 2)) * ((u - cx) / (imageWidth / 2)) +
                  ((v - cy) / (imageHeight / 2)) *
                      ((v - cy) / (imageHeight / 2)),
            );
            if (r > 0.7) {
              if (r >= 1.0) continue;
              weight *= 0.5 * (1 + math.cos(math.pi * (r - 0.7) / 0.3));
            }
          }
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
  // Every photograph was exposed and white-balanced by its own auto loop, so
  // two frames of the same wall can differ by 10-20% in brightness and a few
  // percent per channel. Correct that before compositing, or every seam is
  // also a step — and a step across a bright-to-dark curtain reads as jagged
  // stair-cases.
  //
  // One multiplicative gain per frame **per channel**, propagated from the
  // Middle Ring anchor across the neighbour graph (GainBlocks logic): each
  // frame's median BGR in a genuine overlap is matched to an already-gained
  // neighbour. Median resists outliers, per-channel absorbs white-balance
  // drift, and [0.65, 1.45] bounds what "exposure difference" may explain.
  final channelGains = solveChannelMedianGains(
    imageWidth: width,
    pixelCount: width * height,
    frameCount: records.length,
    bestFrame: bestFrame,
    secondFrame: secondFrame,
    bestWeight: bestWeight,
    secondWeight: secondWeight,
    bestColour: bestColour,
    secondColour: secondColour,
    minWeight: _kMinPixelWeight,
  );

  final exposureMs = lapMs();

  // ── Seam compositing ────────────────────────────────────────────────
  //
  // This replaces the normalised weighted average of the top two contributors
  // over the whole overlap. Where two frames disagreed — and indoors they do,
  // by 20-45 px of parallax on close objects — averaging drew the
  // disagreement twice at ~50% opacity: the white wall showed through the
  // wardrobe, the chair grew a second seat, the wall shelf doubled.
  //
  // `compositeSeams` gives every pixel exactly one owner — a graph-cut seam
  // routes the ownership boundary through content the frames agree on
  // (plain wall) and around the objects they do not (chair, wardrobe,
  // shelf, curtain) — and renders it at 100% opacity from that frame alone.
  // The only cross-fade is a kSeamFeatherPx-pixel band strictly across the
  // seam line; nothing averages over the wide overlap any more.
  final output = Uint8List(width * height * 3);
  final seamStats = compositeSeams(
    output: output,
    width: width,
    height: height,
    bestColour: bestColour,
    secondColour: secondColour,
    bestWeight: bestWeight,
    secondWeight: secondWeight,
    bestFrame: bestFrame,
    secondFrame: secondFrame,
    channelGains: channelGains,
    minWeight: _kMinPixelWeight,
    featherPx: kSeamFeatherPx,
  );
  if (kSphereStitchLog) {
    debugPrint('SPHERE_SEAM: ${seamStats.toJson()}');
  }

  final blendMs = lapMs();

  // ── Gap fill ────────────────────────────────────────────────────────
  //
  // Uncovered pixels were previously left at zero, which is why a missed
  // direction showed as a black disc rather than as a slightly soft patch. A
  // gap cannot be retried without recapturing, so the honest failure mode is a
  // smeared extrapolation plus a diagnostic that says "retake this direction" —
  // not a hole in the product. The pole frames now use a 16% margin and the
  // Nadir fades radially, so the small Zenith crescent is closed at source.
  final filledPixels = fillUncovered(
    output: output,
    bestWeight: bestWeight,
    width: width,
    height: height,
  );
  final fillMs = lapMs();

  // ── Embed the feature-stitched band ─────────────────────────────────
  //
  // The pose projection above is complete but rotation-only: where the sensor
  // prior drifted, close objects are duplicated across ownership seams no
  // mask can hide. The feature-based Stitcher's output — attempted before the
  // accumulator was allocated, so the two memory footprints never overlap —
  // is blended over the equatorial band through a 40-px smoothstep gradient;
  // the pole caps stay pose-projected. On any Stitcher failure this is a
  // no-op and the pose projection remains the whole panorama.
  var stitcherEmbedded = false;
  final bandPano = stitchAttempt.pano;
  if (bandPano != null) {
    stitcherEmbedded = _embedStitcherBand(
      output: output,
      width: width,
      height: height,
      pano: bandPano,
    );
    debugPrint(
      'FLUTTER_STITCH: stitcher band embedded='
      '${stitcherEmbedded ? 'yes' : 'no'} pano=${bandPano.cols}x'
      '${bandPano.rows} canvas=${width}x$height featherPx=40',
    );
  }
  bandPano?.dispose();

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
  final viewport = worstViewportGap(hits: hits, width: width, height: height);
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
      'latitudeDeg': 90 - ((cell ~/ gapCols) + 0.5) / gapRows * 180,
      'uncoveredAreaPercent': gapCells[cell] / totalArea * 100,
    });
  }
  rankedGaps.sort(
    (a, b) => (b['uncoveredAreaPercent']! as double).compareTo(
      a['uncoveredAreaPercent']! as double,
    ),
  );
  final reportPath = p.join(File(outPath).parent.path, 'coverage_report.json');
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
      'stitcherBand': stitcherMs,
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
    // One bounded gain per frame per channel, indexed [frame][r,g,b] — the
    // median-ratio colour match applied before seam compositing.
    'colourGains': <List<double>>[
      for (var f = 0; f < records.length; f++)
        <double>[
          double.parse(channelGains[f * 3].toStringAsFixed(3)),
          double.parse(channelGains[f * 3 + 1].toStringAsFixed(3)),
          double.parse(channelGains[f * 3 + 2].toStringAsFixed(3)),
        ],
    ],
    // What the seam pass did and how much disagreement it could not
    // remove — the direct measure of whether ghosting survives.
    'seamBlend': seamStats.toJson(),
    'integrityGate': {
      'enabled': kSphereStrictSeamIntegrity,
      'maxSeamDiscontinuity': kSphereMaxSeamDiscontinuity,
      'maxGhostFraction': kSphereMaxGhostFraction,
      'passed': seamStats.seamDiscontinuity <= kSphereMaxSeamDiscontinuity &&
          seamStats.ghostFraction <= kSphereMaxGhostFraction,
    },
    // The feature-stitched equatorial band. When `embedded` is true the
    // equatorial band comes from cv.Stitcher's bundle-adjusted, gain-
    // compensated composite; the coverage numbers below describe the pose
    // projection that filled the canvas before the band was applied and that
    // still owns the pole caps.
    'stitcher': {
      'ok': stitcherEmbedded,
      'status': stitchAttempt.status,
      'panoSize': stitchAttempt.pano == null
          ? ''
          : '${stitchAttempt.pano!.cols}x${stitchAttempt.pano!.rows}',
      'embedded': stitcherEmbedded,
      'bandFeatherPx': 40,
      'elapsedMs': stitcherMs,
    },
    if (single < 1)
      'largestGap': {'longitudeDeg': worstLon, 'latitudeDeg': worstLat},
    'uncoveredRegions': rankedGaps
        .take(6)
        .map(
          (Map<String, Object?> region) => <String, Object?>{
            'longitudeDeg': (region['longitudeDeg']! as double).toStringAsFixed(
              1,
            ),
            'latitudeDeg': (region['latitudeDeg']! as double).toStringAsFixed(
              1,
            ),
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

  if (kSphereStrictSeamIntegrity &&
      (seamStats.seamDiscontinuity > kSphereMaxSeamDiscontinuity ||
       seamStats.ghostFraction > kSphereMaxGhostFraction)) {
    return (
      ok: false,
      message: 'The panorama has visible seam mismatch '
          '(seam step ${seamStats.seamDiscontinuity.toStringAsFixed(1)}, '
          'ghost share ${(seamStats.ghostFraction * 100).toStringAsFixed(1)}%). '
          'Original photographs were kept. Inspect coverage_report.json and '
          'retake or realign the affected region before accepting.',
    );
  }

  // PANORAMA_SEAM_QUALITY_20261119: the existing 99.5% area-based
  // acceptance threshold is intentionally preserved for legacy builds.
  // When strict quality mode is on, not one output pixel can come from
  // synthetic gap fill. Report the missing source pixels instead of silently
  // claiming a visually complete, 100%-photo-backed sphere.
  if (kSphereRequire100PhotoCoverage && filledPixels > 0) {
    return (
      ok: false,
      message: 'Panorama needs retakes: $filledPixels pixels had no original '
          'photograph and were filled synthetically. Open coverage_map.jpg and '
          'coverage_report.json for missing directions. Original photos are '
          'safe; no incomplete panorama was accepted.',
    );
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

/// Per-photograph, per-channel colour gains, propagated from the anchor frame.
///
/// Each frame is exposed and white-balanced by its own auto loop, so two
/// photographs of the same wall can differ by 10-20% in brightness and a few
/// percent per channel. Uncorrected, every seam is also a step — a bright
/// curtain against a dark one reads as jagged stair-cases.
///
/// This is OpenCV's `detail::GainCompensator` idea with a median statistic:
/// for every genuinely shared pixel the two frames' BGR values are
/// histogrammed **per neighbour pair**. A breadth-first walk then starts at
/// the anchor (frame 0, the first Middle Ring frame, gain 1) and propagates
/// outward through the overlap graph, setting each neighbour's gain from the
/// already-calibrated frame's median:
///
/// ```
/// gain[v][c] = clamp(gain[u][c] · median_u[c] / median_v[c], 0.65, 1.45)
/// ```
///
/// Propagating rather than solving against one station-wide median is what
/// lets a dark Zenith ceiling be matched to the ceiling tiles of the ring
/// that actually touches it, and then the ring to the Middle Ring anchor,
/// instead of dragging every frame toward a global average that no frame
/// represents.
///
/// Medians resist blown windows and dark wardrobes; per-channel corrections
/// absorb auto-white-balance drift; the clamp stops a disagreement about the
/// scene from being "fixed" as exposure. A pair with too few shared samples
/// contributes no edge — its frame keeps gain 1 rather than a guess.
/// Estimates stable per-frame RGB gains from corresponding overlap pixels.
///
/// The previous implementation compared the independent median colour of each
/// frame. Indoors, those medians can describe different objects (e.g. a dark
/// wardrobe and a white wall), causing a large false colour correction. It also
/// propagated corrections through a single BFS tree, accumulating drift.
///
/// This implementation instead:
/// - samples the *same projected pixel* from both frames;
/// - skips invalid, clipped, high-gradient and chromatically inconsistent pairs;
/// - robustly estimates ratios using histograms of per-pixel log ratios;
/// - solves all reliable pairwise relations together, with identity regularisation;
/// - limits per-frame brightness and chromatic corrections to avoid wild tints.
///
/// The returned gains are indexed as [frame * 3 + channel], in the existing
/// RGB order used by bestColour/secondColour and by compositeSeams.
@visibleForTesting
Float64List solveChannelMedianGains({
  required int pixelCount,
  required int frameCount,
  required Int16List bestFrame,
  required Int16List secondFrame,
  required Float32List bestWeight,
  required Float32List secondWeight,
  required Uint8List bestColour,
  required Uint8List secondColour,
  double minWeight = 0,
  int? imageWidth,
}) {
  const int bins = 141;
  const double minLogRatio = -0.70;
  const double maxLogRatio = 0.70;
  const int minSamples = 48;
  const double maxIqr = 0.17;
  const double chromaTolerance = 0.42;
  const double maxLocalGradient = 12.0;
  const double ridgeWeight = 0.075;
  const double minFrameGain = 0.72;
  const double maxFrameGain = 1.38;
  const double maxChromaLog = 0.13;

  final gains = Float64List(frameCount * 3)
    ..fillRange(0, frameCount * 3, 1.0);
  if (frameCount < 2 || pixelCount < 1) return gains;

  // Each pair has three histograms of log(A/B), where A is the lower frame ID.
  // Using a *per-pixel ratio* removes the scene-composition bias of comparing
  // independent medians. Histogram bins make the estimate robust to parallax.
  final histograms = <int, Int32List>{};
  final counts = <int, int>{};
  for (var i = 0; i < pixelCount; i += 3) {
    final best = bestFrame[i];
    final second = secondFrame[i];
    if (best < 0 || second < 0 || best == second ||
        best >= frameCount || second >= frameCount) {
      continue;
    }
    final wb = bestWeight[i];
    final ws = secondWeight[i];
    if (wb <= minWeight || ws <= minWeight ||
        ws < wb * 0.35) {
      continue;
    }

    final off = i * 3;
    if (imageWidth != null && imageWidth > 1) {
      // Only use locally smooth, stable overlapping areas. Object edges and
      // inconsistent label changes are where parallax corrupts comparisons.
      if (i % imageWidth == imageWidth - 1 || i + 1 >= pixelCount ||
          bestFrame[i + 1] != best || secondFrame[i + 1] != second) {
        continue;
      }
      final next = off + 3;
      var flat = true;
      for (var c = 0; c < 3; c++) {
        if ((bestColour[off + c] - bestColour[next + c]).abs() >
                maxLocalGradient ||
            (secondColour[off + c] - secondColour[next + c]).abs() >
                maxLocalGradient) {
          flat = false;
          break;
        }
      }
      if (!flat) continue;
    }

    final r1 = bestColour[off].toDouble();
    final g1 = bestColour[off + 1].toDouble();
    final b1 = bestColour[off + 2].toDouble();
    final r2 = secondColour[off].toDouble();
    final g2 = secondColour[off + 1].toDouble();
    final b2 = secondColour[off + 2].toDouble();
    // Very dark and clipped measurements do not reveal a trustworthy exposure
    // ratio; nor do pixels whose colours differ because they are different
    // surfaces, not differently exposed views of the same surface.
    if (r1 < 15 || g1 < 15 || b1 < 15 ||
        r2 < 15 || g2 < 15 || b2 < 15 ||
        r1 > 245 || g1 > 245 || b1 > 245 ||
        r2 > 245 || g2 > 245 || b2 > 245) {
      continue;
    }
    final y1 = 0.2126 * r1 + 0.7152 * g1 + 0.0722 * b1;
    final y2 = 0.2126 * r2 + 0.7152 * g2 + 0.0722 * b2;
    if (y1 < 22 || y2 < 22 || y1 > 240 || y2 > 240) continue;
    final luminanceRatio = y1 / y2;
    if (luminanceRatio < 0.50 || luminanceRatio > 2.0) continue;
    if ((r1 / y1 - r2 / y2).abs() > chromaTolerance ||
        (g1 / y1 - g2 / y2).abs() > chromaTolerance ||
        (b1 / y1 - b2 / y2).abs() > chromaTolerance) {
      continue;
    }

    final lowerIsBest = best < second;
    final logR = math.log((lowerIsBest ? r1 : r2) /
        (lowerIsBest ? r2 : r1));
    final logG = math.log((lowerIsBest ? g1 : g2) /
        (lowerIsBest ? g2 : g1));
    final logB = math.log((lowerIsBest ? b1 : b2) /
        (lowerIsBest ? b2 : b1));
    if (logR < minLogRatio || logR > maxLogRatio ||
        logG < minLogRatio || logG > maxLogRatio ||
        logB < minLogRatio || logB > maxLogRatio) {
      continue;
    }
    final rBin = (((logR - minLogRatio) /
            (maxLogRatio - minLogRatio)) * (bins - 1)).round();
    final gBin = (((logG - minLogRatio) /
            (maxLogRatio - minLogRatio)) * (bins - 1)).round();
    final bBin = (((logB - minLogRatio) /
            (maxLogRatio - minLogRatio)) * (bins - 1)).round();
    final a = lowerIsBest ? best : second;
    final b = lowerIsBest ? second : best;
    final key = a * frameCount + b;
    final hist = histograms.putIfAbsent(key, () => Int32List(3 * bins));
    hist[rBin]++;
    hist[bins + gBin]++;
    hist[2 * bins + bBin]++;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  if (histograms.isEmpty) return gains;

  int quantileBin(Int32List hist, int start, int count, double fraction) {
    final target = math.max(1, (count * fraction).ceil());
    var cumulative = 0;
    for (var j = 0; j < bins; j++) {
      cumulative += hist[start + j];
      if (cumulative >= target) return j;
    }
    return bins - 1;
  }

  // Encode each reliable overlap as an edge: log(gain_b)-log(gain_a) =
  // log(pixel_a/pixel_b). Trim broad, inconsistent histograms rather than
  // forcing a correction from overlapping but different objects.
  final edges =
      <({int a, int b, double weight, List<double> ratios})>[];
  for (final entry in histograms.entries) {
    final count = counts[entry.key] ?? 0;
    if (count < minSamples) continue;
    final ratios = <double>[];
    var valid = true;
    for (var c = 0; c < 3; c++) {
      final start = c * bins;
      final q1 = quantileBin(entry.value, start, count, 0.25);
      final median = quantileBin(entry.value, start, count, 0.50);
      final q3 = quantileBin(entry.value, start, count, 0.75);
      final spread = (q3 - q1) *
          (maxLogRatio - minLogRatio) / (bins - 1);
      if (spread > maxIqr) {
        valid = false;
        break;
      }
      ratios.add(minLogRatio + median *
          (maxLogRatio - minLogRatio) / (bins - 1));
    }
    if (!valid) continue;
    edges.add((
      a: entry.key ~/ frameCount,
      b: entry.key % frameCount,
      weight: math.min(1.0, count / 300.0),
      ratios: ratios,
    ));
  }
  if (edges.isEmpty) return gains;

  // A small regularizer to identity fixes the otherwise arbitrary exposure
  // baseline and keeps disconnected frames at exactly 1.0. All pair edges are
  // optimized jointly: this avoids BFS propagation drift around a 360° loop.
  final solved = List<Float64List>.generate(
      3, (_) => Float64List(frameCount));
  for (var channel = 0; channel < 3; channel++) {
    final x = solved[channel];
    for (var pass = 0; pass < 90; pass++) {
      var largestChange = 0.0;
      for (var f = 0; f < frameCount; f++) {
        var numerator = 0.0;
        var denominator = ridgeWeight;
        for (final e in edges) {
          if (e.a == f) {
            numerator += e.weight * (x[e.b] - e.ratios[channel]);
            denominator += e.weight;
          } else if (e.b == f) {
            numerator += e.weight * (x[e.a] + e.ratios[channel]);
            denominator += e.weight;
          }
        }
        final next = numerator / denominator;
        largestChange = math.max(largestChange, (next - x[f]).abs());
        x[f] = next;
      }
      if (largestChange < 0.00005) break;
    }
  }

  final minLogGain = math.log(minFrameGain);
  final maxLogGain = math.log(maxFrameGain);
  for (var f = 0; f < frameCount; f++) {
    final mean = (solved[0][f] + solved[1][f] + solved[2][f]) / 3;
    for (var c = 0; c < 3; c++) {
      // Exposure can shift more than white balance. Limit relative RGB shifts
      // so a dark wall does not get corrected toward purple/yellow.
      final chroma = (solved[c][f] - mean)
          .clamp(-maxChromaLog, maxChromaLog).toDouble();
      final corrected = (mean + chroma)
          .clamp(minLogGain, maxLogGain).toDouble();
      gains[f * 3 + c] = math.exp(corrected);
    }
  }
  return gains;
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
  const sampleCount = 6000;
  const viewCount = 300;
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

/// The decode target for the ring frames passed to the Stitcher.
///
/// 36 frames at 720×960 cost about 75 MB of decoded pixels — roughly a quarter
/// of what full-resolution decodes would need — which is what keeps the
/// Stitcher's internal copies inside a phone's budget. The shorter side is
/// fixed at 720 and the longer side follows the source aspect, so a landscape
/// source is handled by the same rule.
const int _kStitcherShortSidePx = 720;

/// Runs OpenCV's feature-based Stitcher over the 36 ring frames.
///
/// This is the **production** equatorial-band source, not a diagnostic: when it
/// returns a panorama, that panorama is embedded over the pose-projected band
/// by [_embedStitcherBand]. The zenith (target 13 → record index 12) and nadir
/// (target 38 → index 37) shots are excluded — a featureless white ceiling
/// gives the matcher nothing, and one bad frame aborts the whole stitch with
/// `ERR_NEED_MORE_IMGS`. Every failure is logged and non-fatal: the pose
/// projection remains the complete fallback.
({cv.Mat? pano, String status}) _stitchRingWithOpenCv({
  required List<Map<String, dynamic>> records,
  required void Function(String) progress,
}) {
  final ringPaths = <String>[];
  for (var i = 0; i < records.length; i++) {
    // Exclude the poles by record order (sorted by targetId): index 12 is the
    // zenith, index 37 the nadir — the same 36 the old diagnostic selected.
    if (i == 12 || i == 37) continue;
    final path = records[i]['imagePath'] as String?;
    if (path == null || !File(path).existsSync()) continue;
    ringPaths.add(path);
  }
  if (ringPaths.length != 36) {
    debugPrint(
      'FLUTTER_STITCH: OPENCV_STITCHER ring-first skipped — '
      'expected 36 ring frames, got ${ringPaths.length}',
    );
    return (pano: null, status: 'skipped');
  }

  final mats = <cv.Mat>[];
  cv.Stitcher? stitcher;
  cv.Mat? pano;
  final watch = Stopwatch()..start();
  try {
    for (final path in ringPaths) {
      final source = cv.imread(path, flags: cv.IMREAD_COLOR);
      if (source.isEmpty) {
        debugPrint('FLUTTER_STITCH: OPENCV_STITCHER ring decode failed: $path');
        return (pano: null, status: 'decode-failed');
      }
      // Short side 720, longer side follows the source aspect (3:4 portrait
      // sources decode to exactly 720×960).
      final scale = _kStitcherShortSidePx / math.min(source.cols, source.rows);
      final targetWidth = (source.cols * scale).round();
      final targetHeight = (source.rows * scale).round();
      final resized = cv.resize(source, (
        targetWidth,
        targetHeight,
      ), interpolation: cv.INTER_AREA);
      source.dispose();
      mats.add(resized);
    }
    progress(
      'Matching ${mats.length} ring frames with OpenCV (720-class '
      'decode, confidence 0.35)…',
    );
    stitcher = cv.Stitcher.create(mode: cv.StitcherMode.PANORAMA)
      ..panoConfidenceThresh = 0.35;
    final input = cv.VecMat.fromList(mats);
    final result = stitcher.stitch(input);
    final status = result.$1;
    pano = result.$2;
    if (status != cv.StitcherStatus.OK || pano.isEmpty) {
      // The exact status code the caller asked for, verbatim, plus the same
      // context line the old diagnostic printed.
      debugPrint('STITCHER_FAILED_STATUS: $status');
      debugPrint(
        'FLUTTER_STITCH: OPENCV_STITCHER ring-first frames=${mats.length} '
        'input=720-class confidence=0.35 status=${status.name}'
        '(${status.index}) elapsedMs=${watch.elapsedMilliseconds} '
        'pano=${pano.isEmpty ? 'empty' : '${pano.cols}x${pano.rows}'} — '
        'pose projection remains the panorama.',
      );
      pano.dispose();
      pano = null; // disposed; the finally block must not double-free
      return (pano: null, status: status.name);
    }
    debugPrint(
      'FLUTTER_STITCH: OPENCV_STITCHER ring-first frames=${mats.length} '
      'input=720-class confidence=0.35 status=${status.name}'
      '(${status.index}) elapsedMs=${watch.elapsedMilliseconds} '
      'pano=${pano.cols}x${pano.rows}',
    );
    final stitched = pano;
    pano = null; // ownership moves to the caller
    return (pano: stitched, status: status.name);
  } catch (error) {
    debugPrint('FLUTTER_STITCH: OPENCV_STITCHER ring-first exception: $error');
    return (pano: null, status: 'exception');
  } finally {
    pano?.dispose();
    stitcher?.dispose();
    for (final mat in mats) {
      mat.dispose();
    }
  }
}

/// The vertical feather, in pixels, at each edge of the embedded band.
const double _kStitcherBandFeatherPx = 40;

/// Embeds the Stitcher's panorama over the pose-projected equatorial band.
///
/// The Stitcher output is a spherical-warper patch: x is linear in longitude
/// and y is linear in polar angle, so the patch is itself an equirectangular
/// rectangle. A complete ring spans 360° of longitude, which fixes the patch's
/// focal at `W / 2π`, and the vertical span follows from its own height:
/// `latSpan = 2π · H / W`. The band is placed symmetric about the horizon —
/// the ring layout (0°, ±35°) is symmetric, so the Stitcher's vertical union
/// is too — and the two sources are cross-faded through a
/// [_kStitcherBandFeatherPx] smoothstep gradient at each edge. The pole caps
/// above and below the band remain the pose projection's.
///
/// The horizontal origin of the Stitcher output (its bounding box starts near
/// the first frame's left edge, not at the pose projection's longitude −180°)
/// is recovered by a one-dimensional circular cross-correlation of the two
/// sources' column luminance over the band — without it, the band and the
/// pole caps would disagree by tens of pixels exactly at the feather.
///
/// Returns whether the band was applied. A guard rejects patches whose aspect
/// contradicts the full-ring assumption (the band would be misplaced or
/// stretched); the pose projection then stands unchanged.
bool _embedStitcherBand({
  required Uint8List output,
  required int width,
  required int height,
  required cv.Mat pano,
}) {
  final aspect = pano.cols / pano.rows;
  // A full ring of 65°-FOV cameras across 0°/±35° rings covers roughly
  // 105–150° of latitude, i.e. aspect 2.4–3.4. Anything outside 2.0–4.6 means
  // the "full ring" premise is wrong (frames were dropped or the output is
  // something else entirely) and embedding would misplace the band.
  if (aspect < 2.0 || aspect > 4.6) {
    debugPrint(
      'FLUTTER_STITCH: stitcher band rejected — aspect='
      '${aspect.toStringAsFixed(2)} is outside the full-ring range 2.0..4.6; '
      'pose projection stands.',
    );
    return false;
  }
  final latSpan = 2 * math.pi / aspect; // radians, ≤ π by the guard
  final scaledHeight = math.max(1, (width / aspect).round());
  final scaled = cv.resize(pano, (
    width,
    scaledHeight,
  ), interpolation: cv.INTER_LINEAR);
  try {
    // `clamp` returns `num`, which would poison every row index below with
    // `num` — clamp manually to keep the types int.
    final topRaw = ((0.5 - latSpan / 2 / math.pi) * height).round();
    final topLimit = math.max(0, height - scaledHeight);
    final topRow = topRaw < 0 ? 0 : math.min(topRaw, topLimit);
    final bottomRow = math.min(height, topRow + scaledHeight);
    if (bottomRow - topRow < _kStitcherBandFeatherPx * 3) {
      debugPrint(
        'FLUTTER_STITCH: stitcher band rejected — band '
        '${bottomRow - topRow}px is too small to feather; pose projection '
        'stands.',
      );
      return false;
    }

    // ── Horizontal auto-alignment ────────────────────────────────────────
    // Column-mean luminance of both sources over the band's middle half, then
    // the circular shift that maximises their normalised correlation. This
    // absorbs the Stitcher's unknown longitude origin in one O(W²) pass
    // (~4M multiply-adds, tens of milliseconds).
    final halfBand = (bottomRow - topRow) ~/ 2;
    final sampleTop = topRow + halfBand ~/ 2;
    final sampleBottom = sampleTop + halfBand;
    final poseSignal = Float64List(width);
    final panoSignal = Float64List(width);
    final panoPixels = scaled.data;
    final panoStride = width * 3;
    var sampleCount = 0;
    for (var y = sampleTop; y < sampleBottom; y += 4) {
      final poseRow = y * width * 3;
      final panoRow = (y - topRow) * panoStride;
      for (var x = 0; x < width; x++) {
        poseSignal[x] +=
            0.299 * output[poseRow + x * 3] +
            0.587 * output[poseRow + x * 3 + 1] +
            0.114 * output[poseRow + x * 3 + 2];
        panoSignal[x] +=
            0.299 * panoPixels[panoRow + x * 3] +
            0.587 * panoPixels[panoRow + x * 3 + 1] +
            0.114 * panoPixels[panoRow + x * 3 + 2];
      }
      sampleCount++;
    }
    if (sampleCount == 0) return false;
    final shift = _estimateBandShift(poseSignal, panoSignal, width);
    debugPrint(
      'FLUTTER_STITCH: stitcher band shift=${shift}px '
      '($sampleCount sample rows, band rows $topRow..$bottomRow)',
    );

    // ── Blend ────────────────────────────────────────────────────────────
    for (var y = topRow; y < bottomRow; y++) {
      final fromTop = (y - topRow).toDouble();
      final fromBottom = (bottomRow - 1 - y).toDouble();
      var w = 1.0;
      if (fromTop < _kStitcherBandFeatherPx) {
        w = math.min(w, fromTop / _kStitcherBandFeatherPx);
      }
      if (fromBottom < _kStitcherBandFeatherPx) {
        w = math.min(w, fromBottom / _kStitcherBandFeatherPx);
      }
      // Smoothstep: the linear ramp's derivative step is itself visible on a
      // flat wall.
      final t = w * w * (3 - 2 * w);
      final poseRow = y * width * 3;
      final panoRow = (y - topRow) * panoStride;
      for (var x = 0; x < width; x++) {
        // Circular shift: pano column (x - shift) mod width feeds canvas x.
        var sx = x - shift;
        if (sx < 0) sx += width;
        final poseBase = poseRow + x * 3;
        final panoBase = panoRow + sx * 3;
        for (var c = 0; c < 3; c++) {
          final poseValue = output[poseBase + c];
          final panoValue = panoPixels[panoBase + c];
          output[poseBase + c] = (poseValue + (panoValue - poseValue) * t)
              .round();
        }
      }
    }
    return true;
  } finally {
    scaled.dispose();
  }
}

/// The circular shift, in pixels, that best aligns [panoSignal] to
/// [poseSignal]: the `d` maximising `Σ poseSignal[(x + d) mod width] ·
/// panoSignal[x]` over zero-mean, unit-variance signals.
///
/// Both signals are column-mean luminances over the same latitude rows, so a
/// well-aligned pair correlates strongly and noise floors near zero mean.
int _estimateBandShift(
  Float64List poseSignal,
  Float64List panoSignal,
  int width,
) {
  void normalise(Float64List signal) {
    var mean = 0.0;
    for (final v in signal) {
      mean += v;
    }
    mean /= width;
    var variance = 0.0;
    for (var i = 0; i < width; i++) {
      final d = signal[i] - mean;
      signal[i] = d;
      variance += d * d;
    }
    final std = math.sqrt(variance / width);
    if (std > 1e-9) {
      for (var i = 0; i < width; i++) {
        signal[i] /= std;
      }
    }
  }

  normalise(poseSignal);
  normalise(panoSignal);
  var bestShift = 0;
  var bestScore = -double.infinity;
  for (var d = 0; d < width; d++) {
    var score = 0.0;
    for (var x = 0; x < width; x++) {
      var px = x + d;
      if (px >= width) px -= width;
      score += poseSignal[px] * panoSignal[x];
    }
    if (score > bestScore) {
      bestScore = score;
      bestShift = d;
    }
  }
  return bestShift;
}
