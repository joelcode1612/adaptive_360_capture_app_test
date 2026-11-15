import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;

import 'package:adaptive_360_capture_app/features/capture/data/stitch/stitch_job_models.dart';

/// Registration thresholds mirrored from the service.
const int _minGoodMatches = 20;
const int _minInliers = 12;
const double _maxMeanReprojPx = 8.0;
const double _minLaplacianVariance = 30.0;
const double _minBrightness = 30.0;
const double _maxBrightness = 235.0;

/// Runs one incremental-stitching job on a background isolate.
///
/// The service awaits this; the isolate keeps the UI thread free while OpenCV
/// detects, matches and stitches. Only the [StitchJobPacket] crosses the
/// boundary, and only the [StitchWorkerOutcome] comes back — native `Mat`
/// handles are created and disposed entirely inside.
Future<StitchWorkerOutcome> runIncrementalStitchJob(
  StitchJobPacket packet,
) => Isolate.run(() => _runJob(packet));

StitchWorkerOutcome _runJob(StitchJobPacket packet) {
  if (!File(packet.imagePath).existsSync()) {
    return const StitchWorkerOutcome(
      decodeOk: false,
      decodeError: 'The saved photograph is missing on disk.',
    );
  }

  cv.Mat? src;
  cv.Mat? work;
  cv.Mat? gray;
  cv.Mat? lap;
  cv.Mat? lapSq;
  cv.ORB? orb;
  cv.BFMatcher? matcher;
  final attempts = <StitchAttemptResult>[];
  try {
    src = cv.imread(packet.imagePath, flags: cv.IMREAD_COLOR);
    if (src.isEmpty) {
      return const StitchWorkerOutcome(
        decodeOk: false,
        decodeError: 'The saved JPEG could not be decoded.',
      );
    }
    work = _downscale(src, 1024);
    gray = cv.cvtColor(work, cv.COLOR_BGR2GRAY);
    final brightness = cv.mean(gray).val1;
    lap = cv.laplacian(gray, cv.MatType.CV_32F);
    lapSq = cv.multiply(lap, lap);
    final laplacianVariance = cv.mean(lapSq).val1;

    if (laplacianVariance < _minLaplacianVariance) {
      return StitchWorkerOutcome(
        decodeOk: true,
        laplacianVariance: laplacianVariance,
        brightness: brightness,
        qualityReason:
            'The photograph is too blurry to register reliably '
            '(detail level ${laplacianVariance.toStringAsFixed(1)}, '
            'needs ≥ ${_minLaplacianVariance.toStringAsFixed(0)}). Retake it '
            'holding the phone steadier.',
      );
    }
    if (brightness < _minBrightness) {
      return StitchWorkerOutcome(
        decodeOk: true,
        laplacianVariance: laplacianVariance,
        brightness: brightness,
        qualityReason:
            'The photograph is too dark to register '
            '(brightness ${brightness.toStringAsFixed(0)}/255). Retake it in '
            'better light.',
      );
    }
    if (brightness > _maxBrightness) {
      return StitchWorkerOutcome(
        decodeOk: true,
        laplacianVariance: laplacianVariance,
        brightness: brightness,
        qualityReason:
            'The photograph is washed out by glare '
            '(brightness ${brightness.toStringAsFixed(0)}/255). Retake it '
            'away from the light source.',
      );
    }

    orb = cv.ORB.create(nFeatures: 3000);
    matcher = cv.BFMatcher.create(type: cv.NORM_HAMMING);
    final (newKeypoints, newDescriptors) = orb.detectAndCompute(
      gray,
      cv.Mat.empty(),
    );
    if (newKeypoints.length < _minGoodMatches) {
      return StitchWorkerOutcome(
        decodeOk: true,
        laplacianVariance: laplacianVariance,
        brightness: brightness,
        qualityReason:
            'Only ${newKeypoints.size} features were found in the photograph '
            '— not enough detail to register against a neighbour.',
      );
    }

    StitchAttemptResult? best;
    for (final StitchCandidatePacket candidate in packet.candidates) {
      final result = _matchCandidate(
        candidate: candidate,
        orb: orb,
        matcher: matcher,
        newKeypoints: newKeypoints,
        newDescriptors: newDescriptors,
        workWidth: work.cols,
        workHeight: work.rows,
      );
      attempts.add(result);
      if (result.registered) {
        best = result;
        break;
      }
    }
    final registered = best != null;

    StitchMergeResult? groupMerge;
    StitchMergeResult? pairMerge;
    if (registered) {
      final newEntry = StitchCandidatePacket(
        targetId: packet.targetId,
        imagePath: packet.imagePath,
      );
      if (packet.groupImages.isNotEmpty) {
        groupMerge = _merge(
          inputs: <StitchCandidatePacket>[...packet.groupImages, newEntry],
          outputPath: _outputPathFor(packet, packet.nextOutputIndex),
          sourceTargetIds: <int>[
            for (final StitchCandidatePacket g in packet.groupImages)
              g.targetId,
            packet.targetId,
          ],
        );
      }
      if (groupMerge == null || !groupMerge.ok) {
        final bestCandidate = packet.candidates.firstWhere(
          (StitchCandidatePacket c) => c.targetId == best!.candidateTargetId,
        );
        final fallbackIndex = groupMerge == null
            ? packet.nextOutputIndex
            : packet.nextOutputIndex + 1;
        pairMerge = _merge(
          inputs: <StitchCandidatePacket>[bestCandidate, newEntry],
          outputPath: _outputPathFor(packet, fallbackIndex),
          sourceTargetIds: <int>[bestCandidate.targetId, packet.targetId],
        );
      }
    }

    return StitchWorkerOutcome(
      decodeOk: true,
      laplacianVariance: laplacianVariance,
      brightness: brightness,
      attempts: attempts,
      groupMerge: groupMerge,
      pairMerge: pairMerge,
    );
  } catch (error) {
    return StitchWorkerOutcome(
      decodeOk: false,
      decodeError: 'Stitching worker error: $error',
      attempts: attempts,
    );
  } finally {
    lapSq?.dispose();
    lap?.dispose();
    gray?.dispose();
    work?.dispose();
    src?.dispose();
    orb?.dispose();
    matcher?.dispose();
  }
}

/// ORB match + RANSAC verification of the new image against one candidate.
StitchAttemptResult _matchCandidate({
  required StitchCandidatePacket candidate,
  required cv.ORB orb,
  required cv.BFMatcher matcher,
  required cv.VecKeyPoint newKeypoints,
  required cv.Mat newDescriptors,
  required int workWidth,
  required int workHeight,
}) {
  cv.Mat? candidateSrc;
  cv.Mat? candidateWork;
  cv.Mat? candidateGray;
  cv.Mat? homography;
  cv.Mat? mask;
  cv.VecPoint2f? srcPoints;
  cv.VecPoint2f? dstPoints;
  try {
    if (!File(candidate.imagePath).existsSync()) {
      return StitchAttemptResult(
        candidateTargetId: candidate.targetId,
        featureMatches: 0,
        inliers: 0,
        inlierRatio: 0,
        meanReprojPx: 0,
        overlapFraction: 0,
        registered: false,
      );
    }
    candidateSrc = cv.imread(candidate.imagePath, flags: cv.IMREAD_COLOR);
    if (candidateSrc.isEmpty) {
      return StitchAttemptResult(
        candidateTargetId: candidate.targetId,
        featureMatches: 0,
        inliers: 0,
        inlierRatio: 0,
        meanReprojPx: 0,
        overlapFraction: 0,
        registered: false,
      );
    }
    candidateWork = _downscale(candidateSrc, 1024);
    candidateGray = cv.cvtColor(candidateWork, cv.COLOR_BGR2GRAY);
    final (keypoints, descriptors) = orb.detectAndCompute(
      candidateGray,
      cv.Mat.empty(),
    );

    final knn = matcher.knnMatch(newDescriptors, descriptors, 2);
    final good = <dynamic>[];
    for (final row in knn) {
      if (row.length < 2) continue;
      final first = row[0];
      final second = row[1];
      if (first.distance < 0.75 * second.distance) {
        good.add(first);
      }
    }
    if (good.length < _minGoodMatches) {
      return StitchAttemptResult(
        candidateTargetId: candidate.targetId,
        featureMatches: good.length,
        inliers: 0,
        inlierRatio: good.isEmpty ? 0 : 0,
        meanReprojPx: 0,
        overlapFraction: 0,
        registered: false,
      );
    }

    final srcList = <cv.Point2f>[];
    final dstList = <cv.Point2f>[];
    for (final match in good) {
      final kpNew = newKeypoints[match.queryIdx];
      final kpOld = keypoints[match.trainIdx];
      srcList.add(cv.Point2f(kpNew.x, kpNew.y));
      dstList.add(cv.Point2f(kpOld.x, kpOld.y));
    }
    srcPoints = cv.VecPoint2f.fromList(srcList);
    dstPoints = cv.VecPoint2f.fromList(dstList);
    mask = cv.Mat.empty();
    // findHomography takes InputArray (Mat): the Nx1 CV_32FC2 view of the
    // point vectors, the same construction the dartcv4 test suite uses.
    final srcMat = cv.Mat.fromVec(srcPoints);
    final dstMat = cv.Mat.fromVec(dstPoints);
    try {
      homography = cv.findHomography(
        srcMat,
        dstMat,
        method: cv.RANSAC,
        ransacReprojThreshold: 4.0,
        mask: mask,
      );
    } finally {
      srcMat.dispose();
      dstMat.dispose();
    }
    if (homography.isEmpty) {
      return StitchAttemptResult(
        candidateTargetId: candidate.targetId,
        featureMatches: good.length,
        inliers: 0,
        inlierRatio: 0,
        meanReprojPx: 0,
        overlapFraction: 0,
        registered: false,
      );
    }

    final h = <List<double>>[
      for (var r = 0; r < 3; r++)
        <double>[
          homography.at<double>(r, 0),
          homography.at<double>(r, 1),
          homography.at<double>(r, 2),
        ],
    ];
    var inliers = 0;
    var reprojSum = 0.0;
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (var i = 0; i < good.length; i++) {
      if (mask.atU8(i) == 0) continue;
      inliers++;
      final px = srcList[i].x;
      final py = srcList[i].y;
      final w = h[2][0] * px + h[2][1] * py + h[2][2];
      final qx = (h[0][0] * px + h[0][1] * py + h[0][2]) / w;
      final qy = (h[1][0] * px + h[1][1] * py + h[1][2]) / w;
      reprojSum += math.sqrt(
        (qx - dstList[i].x) * (qx - dstList[i].x) +
            (qy - dstList[i].y) * (qy - dstList[i].y),
      );
      if (px < minX) minX = px;
      if (px > maxX) maxX = px;
      if (py < minY) minY = py;
      if (py > maxY) maxY = py;
    }
    if (inliers == 0) {
      return StitchAttemptResult(
        candidateTargetId: candidate.targetId,
        featureMatches: good.length,
        inliers: 0,
        inlierRatio: 0,
        meanReprojPx: 0,
        overlapFraction: 0,
        registered: false,
      );
    }
    final meanReproj = reprojSum / inliers;
    final bboxArea = (maxX - minX) * (maxY - minY);
    final imageArea = (workWidth * workHeight).toDouble();
    final overlap = imageArea <= 0 ? 0.0 : (bboxArea / imageArea).clamp(0.0, 1.0);
    return StitchAttemptResult(
      candidateTargetId: candidate.targetId,
      featureMatches: good.length,
      inliers: inliers,
      inlierRatio: inliers / good.length,
      meanReprojPx: meanReproj,
      overlapFraction: overlap,
      registered: inliers >= _minInliers && meanReproj <= _maxMeanReprojPx,
    );
  } finally {
    homography?.dispose();
    mask?.dispose();
    srcPoints?.dispose();
    dstPoints?.dispose();
    candidateGray?.dispose();
    candidateWork?.dispose();
    candidateSrc?.dispose();
  }
}

/// One [cv.Stitcher] run over [inputs], written to [outputPath] atomically.
StitchMergeResult _merge({
  required List<StitchCandidatePacket> inputs,
  required String outputPath,
  required List<int> sourceTargetIds,
}) {
  final mats = <cv.Mat>[];
  cv.Stitcher? stitcher;
  cv.VecMat? vec;
  final tempPath = '$outputPath.tmp.jpg';
  try {
    for (final StitchCandidatePacket input in inputs) {
      if (!File(input.imagePath).existsSync()) {
        return StitchMergeResult(
          ok: false,
          error: 'Input file missing: ${input.imagePath}',
          sourceTargetIds: sourceTargetIds,
        );
      }
      final m = cv.imread(input.imagePath, flags: cv.IMREAD_COLOR);
      if (m.isEmpty) {
        m.dispose();
        return StitchMergeResult(
          ok: false,
          error: 'Input could not be decoded: ${input.imagePath}',
          sourceTargetIds: sourceTargetIds,
        );
      }
      mats.add(_downscale(m, 1280));
    }
    stitcher = cv.Stitcher.create(mode: cv.StitcherMode.PANORAMA);
    vec = cv.VecMat.fromList(mats);
    final (status, pano) = stitcher.stitch(vec);
    if (status != cv.StitcherStatus.OK || pano.isEmpty) {
      pano.dispose();
      return StitchMergeResult(
        ok: false,
        stitcherStatus: status.name,
        error: 'The stitcher rejected this set (${status.name}).',
        sourceTargetIds: sourceTargetIds,
      );
    }
    final written = cv.imwrite(tempPath, pano);
    pano.dispose();
    if (!written || !File(tempPath).existsSync() || File(tempPath).lengthSync() == 0) {
      final temp = File(tempPath);
      if (temp.existsSync()) temp.deleteSync();
      return StitchMergeResult(
        ok: false,
        stitcherStatus: 'OK',
        error: 'The stitched image could not be saved.',
        sourceTargetIds: sourceTargetIds,
      );
    }
    File(tempPath).renameSync(outputPath);
    return StitchMergeResult(
      ok: true,
      outputPath: outputPath,
      stitcherStatus: 'OK',
      sourceTargetIds: sourceTargetIds,
    );
  } catch (error) {
    final temp = File(tempPath);
    if (temp.existsSync()) temp.deleteSync();
    return StitchMergeResult(
      ok: false,
      error: 'Stitching error: $error',
      sourceTargetIds: sourceTargetIds,
    );
  } finally {
    vec?.dispose();
    stitcher?.dispose();
    for (final cv.Mat m in mats) {
      m.dispose();
    }
  }
}

cv.Mat _downscale(cv.Mat src, int maxSide) {
  final longest = math.max(src.cols, src.rows);
  if (longest <= maxSide) return src.clone();
  final scale = maxSide / longest;
  final width = (src.cols * scale).round();
  final height = (src.rows * scale).round();
  final resized = cv.resize(src, (width, height), interpolation: cv.INTER_AREA);
  return resized;
}

String _outputPathFor(StitchJobPacket packet, int index) =>
    p.join(packet.outputsDir, 'stitch_${index.toString().padLeft(3, '0')}.jpg');
